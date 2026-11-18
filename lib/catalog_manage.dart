import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'config/access.dart';
import 'services/line_items_api.dart';
import 'utils/catalog_quality.dart';
import 'widgets/app_dialog.dart';
import 'widgets/catalog_kit.dart';
import 'widgets/dashboard_kit.dart';

/// Managing the Product Catalog (Phase 3, 2026-11-16): the server calls the Categories, Cleanup and History views and
/// the list's bulk actions make, and the dialogs that change several products at once.
///
/// Every change to several products goes the same way: pick what to do, see every product it touches and what changes
/// (and which are already as asked), then confirm with a button that says the count. A big change (50 or more products)
/// also needs a tick. The server checks each product against what this page showed and refuses the whole change if
/// any was changed by someone else in the meantime, so nothing is half done. Only the category and Active / Inactive
/// change; prices, costs, stock and inventory links never do (see the backend's src/catalogManage.js).

/// The Product Catalog's views (ribbon tabs).
enum CatalogView { products, categories, cleanup, history }

/// The server calls behind the management views. Tests pass a fake; the app uses the real server.
class CatalogManager {
  const CatalogManager();

  Future<({List<CatalogCategory> categories, int uncategorized, bool canEdit})> listCategories() => LineItemsApi.listCategories();
  Future<CatalogCategory> createCategory(String name, {String? description}) => LineItemsApi.createCategory(name, description: description);
  Future<({CatalogCategory category, int moved})> renameCategory(String name, String newName, {required List<int> expectedProductIds}) =>
      LineItemsApi.updateCategory(name, newName: newName, expectedProductIds: expectedProductIds);
  Future<({CatalogCategory category, int moved})> describeCategory(String name, String? description, {String? expectedUpdatedAt}) =>
      LineItemsApi.updateCategory(name, setDescription: true, description: description, expectedUpdatedAt: expectedUpdatedAt);
  Future<({CatalogCategory category, int moved})> mergeCategories(List<String> sources, String target, {required List<int> expectedProductIds}) =>
      LineItemsApi.mergeCategories(sources, target, expectedProductIds: expectedProductIds);
  Future<void> deleteCategory(String name) => LineItemsApi.deleteCategory(name);
  Future<CatalogBulkResult> bulkUpdate(Map<int, String> expected, {String? category, bool? active}) =>
      LineItemsApi.bulkUpdateProducts(expected, category: category, active: active);
  Future<({List<CatalogReview> reviews, bool canEdit})> listReviews() => LineItemsApi.listReviews();
  Future<void> markReviewed(String issueKey, String signature, {String? note, String? label}) =>
      LineItemsApi.markReviewed(issueKey, signature, note: note, label: label);
  Future<void> clearReview(String issueKey) => LineItemsApi.clearReview(issueKey);
  Future<({List<CatalogAuditEntry> entries, bool more})> listAudit({int limit = 100, int? before}) => LineItemsApi.listCatalogAudit(limit: limit, before: before);
}

/// A server older than Phase 3 does not have the management calls (404).
bool catalogNeedsServerUpdate(Object e) => e is LineItemsException && e.status == 404 && e.code == null;

/// What a change to several products did, for the page's snack and reload.
class CatalogBulkOutcome {
  final int changed;
  final int skipped;
  final String message;

  /// The change was refused because the list is out of date: reload, keep the selection.
  final bool reload;
  const CatalogBulkOutcome({this.changed = 0, this.skipped = 0, this.message = '', this.reload = false});
}

/// The most products a change to several at once may touch (the server's limit too).
const kCatalogBulkMax = 1000;

/// From this many products a change also needs the "I've checked" tick.
const kCatalogBulkConfirmAt = 50;

final _count = NumberFormat.decimalPattern();
String catalogPlural(int n, String one, [String? many]) => '${_count.format(n)} ${n == 1 ? one : (many ?? '${one}s')}';

/// Plain words for a refused change. A 409 from a stale list says what to do.
String catalogErrorText(Object e) {
  if (e is LineItemsException) {
    if (catalogNeedsServerUpdate(e)) return 'This needs the server update that adds category and bulk changes.';
    return e.message;
  }
  return 'Something went wrong. Try again.';
}

/// Moves [entries] into one category, after a preview. [categories] are the names to pick from with their product
/// counts; [canCreate] offers a new category typed into the search. [exclude] is left out of the list (the category
/// they are being moved out of). Returns null when cancelled.
Future<CatalogBulkOutcome?> showBulkCategoryDialog(
  BuildContext context, {
  required List<CatalogEntry> entries,
  required Map<String, int> categories,
  required CatalogManager manager,
  bool canCreate = false,
  String? exclude,
}) {
  return showDialog<CatalogBulkOutcome>(
    context: context,
    builder: (_) => _BulkDialog(entries: entries, categories: categories, manager: manager, canCreate: canCreate, exclude: exclude),
  );
}

/// Makes [entries] active or inactive, after a preview. Returns null when cancelled.
Future<CatalogBulkOutcome?> showBulkStatusDialog(
  BuildContext context, {
  required List<CatalogEntry> entries,
  required bool active,
  required CatalogManager manager,
}) {
  return showDialog<CatalogBulkOutcome>(
    context: context,
    builder: (_) => _BulkDialog(entries: entries, manager: manager, active: active),
  );
}

class _BulkDialog extends StatefulWidget {
  final List<CatalogEntry> entries;
  final CatalogManager manager;

  /// A category move: the categories to pick from. Null for a status change.
  final Map<String, int>? categories;
  final bool canCreate;
  final String? exclude;

  /// A status change: the status to set. Null for a category move.
  final bool? active;
  const _BulkDialog({required this.entries, required this.manager, this.categories, this.canCreate = false, this.exclude, this.active});

  @override
  State<_BulkDialog> createState() => _BulkDialogState();
}

class _BulkDialogState extends State<_BulkDialog> {
  final _search = TextEditingController();
  String _query = '';
  String? _target;
  bool _newTarget = false;
  bool _preview = false;
  bool _ticked = false;
  bool _busy = false;
  String? _error;
  List<String> _stale = const [];

  bool get _isMove => widget.categories != null;

  @override
  void initState() {
    super.initState();
    _preview = !_isMove; // a status change has nothing to pick
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// The products the change really touches, and the ones already as asked.
  (List<CatalogEntry>, List<CatalogEntry>) get _split {
    final todo = <CatalogEntry>[];
    final same = <CatalogEntry>[];
    for (final e in widget.entries) {
      final already = _isMove ? e.category.trim() == _target : e.active == widget.active;
      (already ? same : todo).add(e);
    }
    return (todo, same);
  }

  Future<void> _apply() async {
    final (todo, _) = _split;
    if (todo.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
      _stale = const [];
    });
    try {
      if (_isMove && _newTarget) await widget.manager.createCategory(_target!);
      final expected = {
        for (final e in widget.entries)
          if (e.productId != null && e.updatedAt != null) e.productId!: e.updatedAt!,
      };
      final r = await widget.manager.bulkUpdate(expected, category: _isMove ? _target : null, active: _isMove ? null : widget.active);
      if (!mounted) return;
      final what = _isMove ? 'Moved ${catalogPlural(r.changed, 'product')} to $_target' : '${catalogPlural(r.changed, 'product')} made ${widget.active! ? 'active' : 'inactive'}';
      Navigator.pop(context, CatalogBulkOutcome(changed: r.changed, skipped: r.skipped, message: what));
    } on LineItemsException catch (e) {
      if (!mounted) return;
      final ids = e.code == 'CHANGED' || e.code == 'MISSING' ? e.message : null;
      setState(() {
        _busy = false;
        _error = catalogErrorText(e);
        if (ids != null) _stale = [e.code!];
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = catalogErrorText(e);
      });
    }
  }

  // ---- picking the category -----------------------------------------------------------------------------------------

  Widget _pickBody() {
    final all = widget.categories!.entries.where((c) => c.key != widget.exclude).toList()
      ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
    final q = _query.trim().toLowerCase();
    final rows = q.isEmpty ? all : all.where((c) => c.key.toLowerCase().contains(q)).toList();
    final typed = _query.trim().replaceAll(RegExp(r'\s+'), ' ');
    final exists = widget.categories!.keys.any((c) => catalogNorm(c) == catalogNorm(typed));
    final offerNew = widget.canCreate && typed.isNotEmpty && !exists && typed.length <= 120;
    Widget row(String name, String? count, {bool isNew = false}) {
      final on = _target == name && _newTarget == isNew;
      return Semantics(
        button: true,
        selected: on,
        label: isNew ? 'Create the category $name' : '$name, $count',
        excludeSemantics: true,
        child: InkWell(
          key: ValueKey(isNew ? 'bulk-new-category' : 'bulk-category:$name'),
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() {
            _target = name;
            _newTarget = isNew;
          }),
          child: AnimatedContainer(
            duration: CatalogUi.motion(context, 120),
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(color: on ? CatalogUi.picked : Colors.transparent, borderRadius: BorderRadius.circular(8)),
            child: Row(
              children: [
                _Radio(on: on),
                const SizedBox(width: 10),
                if (isNew) ...[const Icon(Icons.add_rounded, size: 17, color: DashUi.ink), const SizedBox(width: 4)],
                Expanded(
                  child: Text(
                    isNew ? 'Create "$name"' : name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, fontWeight: on ? FontWeight.w700 : FontWeight.w500, color: DashUi.ink),
                  ),
                ),
                if (count != null) Text(count, style: const TextStyle(fontSize: 12.5, color: DashUi.subtle, fontFeatures: CatalogUi.figures)),
              ],
            ),
          ),
        ),
      );
    }

    final items = [
      if (offerNew) row(typed, null, isNew: true),
      for (final c in rows) row(c.key, _count.format(c.value)),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CatalogSearchField(
          controller: _search,
          hint: widget.canCreate ? 'Find a category, or type a new one' : 'Find a category',
          height: 38,
          autofocus: true,
          onChanged: (v) => setState(() => _query = v),
          onClear: () {
            _search.clear();
            setState(() => _query = '');
          },
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: math.min(340, math.max(1, items.length) * 38.0 + 4),
          child: items.isEmpty
              ? const Center(child: Text('No category matches', style: CatalogUi.meta))
              : ListView(padding: EdgeInsets.zero, children: items),
        ),
      ],
    );
  }

  // ---- the preview --------------------------------------------------------------------------------------------------

  Widget _previewBody() {
    final (todo, same) = _split;
    final big = todo.length >= kCatalogBulkConfirmAt;
    final rows = [...todo, ...same];
    final to = _isMove ? _target! : (widget.active! ? 'Active' : 'Inactive');
    Widget line(CatalogEntry e) {
      final already = !todo.contains(e);
      final from = _isMove ? (e.category.isEmpty ? 'No category' : e.category) : (e.active ? 'Active' : 'Inactive');
      return Container(
        key: ValueKey('bulk-preview:${e.key}'),
        constraints: const BoxConstraints(minHeight: 40),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: DashUi.faint)),
        ),
        child: Row(
          children: [
            Expanded(
              flex: 5,
              child: Text.rich(
                catalogNameSpan(e.name, TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: already ? DashUi.subtle : DashUi.ink)),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 4,
              child: already
                  ? Text('Already ${_isMove ? 'in $to' : to.toLowerCase()}', maxLines: 1, overflow: TextOverflow.ellipsis, style: CatalogUi.meta)
                  : Row(
                      children: [
                        Flexible(
                          child: Text(from, maxLines: 1, overflow: TextOverflow.ellipsis, style: CatalogUi.meta.copyWith(color: DashUi.slate)),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 6),
                          child: Icon(Icons.arrow_forward_rounded, size: 14, color: DashUi.slate),
                        ),
                        Flexible(
                          child: Text(
                            to,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: DashUi.ink),
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      );
    }

    final note = _isMove
        ? 'Only the category changes. Prices, costs, stock, inventory links and everything else stay exactly as they are.'
        : widget.active!
        ? 'Active products are offered again on new estimates and jobs. Nothing else about them changes.'
        : 'Inactive products stop being offered on new estimates and jobs. Lines already on estimates and jobs keep what '
              'they have, and you can make them active again at any time. Nothing else about them changes.';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: catalogPlural(todo.length, 'product'),
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              const TextSpan(text: ' will '),
              TextSpan(text: _isMove ? 'move to ' : 'become '),
              TextSpan(
                text: _isMove ? to : to.toLowerCase(),
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              if (_isMove && _newTarget) const TextSpan(text: ' (a new category)'),
              TextSpan(text: same.isEmpty ? '.' : '. ${catalogPlural(same.length, 'is', 'are')} already ${_isMove ? 'there' : 'so'} and stay as they are.'),
            ],
          ),
          style: const TextStyle(fontSize: 14, color: DashUi.ink, height: 1.4),
        ),
        const SizedBox(height: 10),
        Container(
          // A short list shows every row whole (a long name takes two lines); a long one scrolls inside 300 px.
          height: rows.length <= 6 ? null : 300,
          decoration: BoxDecoration(
            border: Border.all(color: DashUi.line),
            borderRadius: BorderRadius.circular(10),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: rows.length <= 6
                ? Column(mainAxisSize: MainAxisSize.min, children: [for (final e in rows) line(e)])
                : ListView.builder(padding: EdgeInsets.zero, itemCount: rows.length, itemBuilder: (_, i) => line(rows[i])),
          ),
        ),
        const SizedBox(height: 10),
        AppNotice(note),
        if (big) ...[
          const SizedBox(height: 10),
          InkWell(
            key: const ValueKey('bulk-tick'),
            borderRadius: BorderRadius.circular(8),
            onTap: _busy ? null : () => setState(() => _ticked = !_ticked),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
              child: Row(
                children: [
                  CatalogCheckBox(_ticked),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'I have checked this list of ${catalogPlural(todo.length, 'product')}',
                      style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: DashUi.ink),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 10),
          AppNotice(_error!, kind: _stale.isNotEmpty ? AppNoticeKind.warning : AppNoticeKind.error),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.entries.length;
    final (todo, _) = _preview ? _split : (const <CatalogEntry>[], const <CatalogEntry>[]);
    final big = todo.length >= kCatalogBulkConfirmAt;
    final title = _isMove
        ? (_preview ? 'Check the move' : 'Move ${catalogPlural(n, 'product')} to…')
        : 'Make ${catalogPlural(n, 'product')} ${widget.active! ? 'active' : 'inactive'}?';
    final applyLabel = _isMove
        ? 'Move ${catalogPlural(todo.length, 'product')}'
        : 'Make ${catalogPlural(todo.length, 'product')} ${widget.active! ? 'active' : 'inactive'}';
    return AppDialog(
      title: title,
      subtitle: _isMove && _preview ? 'Into $_target' : null,
      icon: _isMove ? Icons.drive_file_move_outline : (widget.active! ? Icons.check_circle_outline_rounded : Icons.do_not_disturb_on_outlined),
      width: 600,
      body: _preview ? _previewBody() : _pickBody(),
      actions: [
        if (_stale.isNotEmpty)
          AppButton.ink('Reload the list', () => Navigator.pop(context, const CatalogBulkOutcome(reload: true)), icon: Icons.refresh_rounded)
        else ...[
          if (_isMove && _preview)
            AppButton.ghost('Back', _busy ? null : () => setState(() => _preview = false))
          else
            AppButton.ghost('Cancel', _busy ? null : () => Navigator.pop(context)),
          if (_preview)
            AppButton.ink(
              _busy ? 'Saving…' : (todo.isEmpty ? 'Nothing to change' : applyLabel),
              _busy || todo.isEmpty || (big && !_ticked) ? null : _apply,
              icon: _busy ? null : Icons.check_rounded,
            )
          else
            AppButton.ink('Review the move', _target == null ? null : () => setState(() => _preview = true), icon: Icons.arrow_forward_rounded),
        ],
      ],
    );
  }
}

class _Radio extends StatelessWidget {
  final bool on;
  const _Radio({required this.on});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: CatalogUi.motion(context, 120),
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: on ? DashUi.ink : DashUi.fieldEdge, width: on ? 5 : 1.5),
        color: Colors.white,
      ),
    );
  }
}

/// A short form dialog: one text field (and an optional description), checked before it closes. Returns the values,
/// or null when cancelled. [validate] returns a problem to show under the field, or null. [action] runs the save; its
/// error is shown in the dialog and it stays open.
Future<bool> showCatalogFormDialog(
  BuildContext context, {
  required String title,
  String? subtitle,
  required IconData icon,
  required String fieldLabel,
  String initial = '',
  String? help,
  bool multiline = false,
  bool withDescription = false,
  String initialDescription = '',
  required String saveLabel,
  String? Function(String value)? validate,
  Widget Function(String value)? note,
  required Future<void> Function(String value, String description) action,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => _FormDialog(
      title: title,
      subtitle: subtitle,
      icon: icon,
      fieldLabel: fieldLabel,
      initial: initial,
      help: help,
      multiline: multiline,
      withDescription: withDescription,
      initialDescription: initialDescription,
      saveLabel: saveLabel,
      validate: validate,
      note: note,
      action: action,
    ),
  );
  return ok == true;
}

class _FormDialog extends StatefulWidget {
  final String title;
  final String? subtitle;
  final IconData icon;
  final String fieldLabel;
  final String initial;
  final String? help;
  final bool multiline;
  final bool withDescription;
  final String initialDescription;
  final String saveLabel;
  final String? Function(String value)? validate;
  final Widget Function(String value)? note;
  final Future<void> Function(String value, String description) action;
  const _FormDialog({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.fieldLabel,
    required this.initial,
    required this.help,
    required this.multiline,
    required this.withDescription,
    required this.initialDescription,
    required this.saveLabel,
    required this.validate,
    required this.note,
    required this.action,
  });

  @override
  State<_FormDialog> createState() => _FormDialogState();
}

class _FormDialogState extends State<_FormDialog> {
  late final _field = TextEditingController(text: widget.initial);
  late final _desc = TextEditingController(text: widget.initialDescription);
  bool _busy = false;
  String? _error;
  bool _tried = false;

  @override
  void dispose() {
    _field.dispose();
    _desc.dispose();
    super.dispose();
  }

  String get _value => widget.multiline ? _field.text.trim() : _field.text.trim().replaceAll(RegExp(r'\s+'), ' ');

  Future<void> _save() async {
    setState(() => _tried = true);
    final problem = widget.validate?.call(_value);
    if (problem != null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.action(_value, _desc.text.trim());
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = catalogErrorText(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final problem = _tried || _field.text != widget.initial ? widget.validate?.call(_value) : null;
    return AppDialog(
      title: widget.title,
      subtitle: widget.subtitle,
      icon: widget.icon,
      width: 520,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppFieldLabel(widget.fieldLabel, help: widget.help),
          TextField(
            key: const ValueKey('catalog-form-field'),
            controller: _field,
            autofocus: true,
            maxLines: widget.multiline ? 4 : 1,
            maxLength: widget.multiline ? 600 : 120,
            style: const TextStyle(fontSize: 14.5, color: DashUi.ink),
            decoration: appFieldDecoration(error: problem).copyWith(counterText: ''),
            onChanged: (_) => setState(() {}),
            onSubmitted: widget.multiline ? null : (_) => _busy ? null : _save(),
          ),
          if (widget.withDescription) ...[
            const SizedBox(height: 14),
            const AppFieldLabel('Description', help: 'Optional. What belongs in it, so products are filed the same way.'),
            TextField(
              key: const ValueKey('catalog-form-description'),
              controller: _desc,
              maxLines: 3,
              maxLength: 600,
              style: const TextStyle(fontSize: 14.5, color: DashUi.ink),
              decoration: appFieldDecoration().copyWith(counterText: ''),
            ),
          ],
          if (widget.note != null) ...[const SizedBox(height: 12), widget.note!(_value)],
          if (_error != null) ...[const SizedBox(height: 12), AppNotice(_error!, kind: AppNoticeKind.error)],
        ],
      ),
      actions: [
        AppButton.ghost('Cancel', _busy ? null : () => Navigator.pop(context, false)),
        AppButton.ink(_busy ? 'Saving…' : widget.saveLabel, _busy || problem != null ? null : _save, icon: _busy ? null : Icons.check_rounded),
      ],
    );
  }
}

/// Asks before something that cannot simply be undone (deleting an empty category). True when confirmed.
Future<bool> confirmCatalogAction(
  BuildContext context, {
  required String title,
  String? subtitle,
  required String message,
  required String confirmLabel,
  bool danger = false,
  IconData icon = Icons.help_outline_rounded,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AppDialog(
      title: title,
      subtitle: subtitle,
      icon: icon,
      iconColor: danger ? DashUi.redText : DashUi.ink,
      width: 480,
      body: Text(message, style: const TextStyle(fontSize: 14, height: 1.45, color: DashUi.slate)),
      actions: [
        AppButton.ghost('Cancel', () => Navigator.pop(ctx, false)),
        AppButton.ink(confirmLabel, () => Navigator.pop(ctx, true), danger: danger),
      ],
    ),
  );
  return ok == true;
}

/// The catalog's icon, for dialogs that belong to it.
IconData get catalogIcon => accessIcon('catalog');
