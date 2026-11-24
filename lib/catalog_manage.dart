import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'config/access.dart';
import 'services/line_items_api.dart';
import 'utils/catalog_quality.dart';
import 'widgets/app_dialog.dart';
import 'widgets/catalog_kit.dart';
import 'widgets/dashboard_kit.dart';
import 'theme/app_theme.dart';

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
  Future<CatalogReview?> markReviewed(
    String issueKey,
    String signature, {
    String? note,
    String? label,
    String status = 'reviewed',
    String? basis,
    bool checkExpected = false,
    String? expectedStamp,
  }) => LineItemsApi.markReviewed(
    issueKey,
    signature,
    note: note,
    label: label,
    status: status,
    basis: basis,
    checkExpected: checkExpected,
    expectedStamp: expectedStamp,
  );
  Future<void> clearReview(String issueKey, {String? expectedStamp}) => LineItemsApi.clearReview(issueKey, expectedStamp: expectedStamp);
  Future<List<CatalogAuditEntry>> reviewHistory(String issueKey) => LineItemsApi.reviewHistory(issueKey);
  Future<({List<CatalogAuditEntry> entries, bool more})> listAudit({int limit = 100, int? before, CatalogAuditFilter filter = const CatalogAuditFilter()}) =>
      LineItemsApi.listCatalogAudit(limit: limit, before: before, filter: filter);
  Future<List<({String name, int changes})>> auditPeople() => LineItemsApi.catalogAuditPeople();
  Future<({DateTime? since, Map<int, CatalogSale> sales})> productSales(List<int> ids) => LineItemsApi.productSales(ids);
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
          mouseCursor: WidgetStateMouseCursor.clickable,
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
    final alike = _newTarget && _target != null ? categoryLookalikes(_target!, widget.categories!.keys) : const <String>[];
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
          height: math.min(alike.isEmpty ? 340 : 250, math.max(1, items.length) * 38.0 + 4),
          child: items.isEmpty
              ? const Center(child: Text('No category matches', style: CatalogUi.meta))
              : ListView(padding: EdgeInsets.zero, children: items),
        ),
        if (alike.isNotEmpty) ...[
          const SizedBox(height: 8),
          CategoryLookalikeNotice(
            typed: _target!,
            alike: alike,
            counts: widget.categories!,
            onPick: (name) => setState(() {
              _target = name;
              _newTarget = false;
            }),
          ),
        ],
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
            mouseCursor: WidgetStateMouseCursor.clickable,
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
              minLines: 3,
              maxLines: null,
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

// ---- "did you mean...?" before a new category is made ------------------------------------------------------------

/// Warns that a new category looks like ones the catalog already has, with a button to use each instead.
class CategoryLookalikeNotice extends StatelessWidget {
  final String typed;
  final List<String> alike;
  final Map<String, int?> counts;
  final ValueChanged<String> onPick;
  const CategoryLookalikeNotice({super.key, required this.typed, required this.alike, required this.counts, required this.onPick});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('category-lookalike'),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
      decoration: BoxDecoration(
        color: DashUi.amber.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: DashUi.amber.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 1),
                child: Icon(Icons.help_outline_rounded, size: 17, color: DashUi.amberText),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '"$typed" looks like ${alike.length == 1 ? 'a category' : 'categories'} the catalog already has. Did you mean:',
                  style: const TextStyle(fontSize: 13.5, height: 1.35, color: DashUi.ink, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 2,
            children: [
              for (final a in alike)
                TextButton(
                  key: ValueKey('use-category:$a'),
                  onPressed: () => onPick(a),
                  style: TextButton.styleFrom(
                    foregroundColor: DashUi.ink,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    textStyle: const TextStyle(fontFamily: AppTheme.fontFamily, fontFamilyFallback: AppTheme.fontFamilyFallback, fontSize: 13, fontWeight: FontWeight.w700),
                  ),
                  child: Text('Use "$a"${counts[a] == null ? '' : ' (${catalogPlural(counts[a]!, 'product')})'}'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---- the product page's category picker ----------------------------------------------------------------------------

/// What the category picker chose: an existing category (spelled as the catalog spells it), no category (''), or a
/// new one the person chose to create on purpose ([isNew]).
typedef CategoryPick = ({String name, bool isNew});

/// Picks a product's category from the catalog's existing categories, searchable. A new category is only made when the
/// person picks "Create ..." for the name typed in the search, and a name that looks like an existing one asks "did
/// you mean" first: a typo never quietly starts a new category. [load] returns the categories and their product
/// counts (null count: not known). [canCreate] (Product Catalog > Create) offers "Create ..." at all. Returns null when
/// cancelled.
Future<CategoryPick?> showCategoryPickerDialog(
  BuildContext context, {
  required String current,
  required Future<Map<String, int?>> Function() load,
  String? pendingNew,
  bool canCreate = true,
}) {
  return showDialog<CategoryPick>(
    context: context,
    builder: (_) => _CategoryPickerDialog(current: current, load: load, pendingNew: pendingNew, canCreate: canCreate),
  );
}

class _CategoryPickerDialog extends StatefulWidget {
  final String current;
  final Future<Map<String, int?>> Function() load;

  /// A new category picked earlier on this page and not saved yet: offered again.
  final String? pendingNew;
  final bool canCreate;
  const _CategoryPickerDialog({required this.current, required this.load, this.pendingNew, this.canCreate = true});

  @override
  State<_CategoryPickerDialog> createState() => _CategoryPickerDialogState();
}

class _CategoryPickerDialogState extends State<_CategoryPickerDialog> {
  final _search = TextEditingController();
  Map<String, int?>? _cats;
  String? _error;
  String _query = '';
  late String _picked = widget.current;
  bool _isNew = false;

  @override
  void initState() {
    super.initState();
    _isNew = widget.pendingNew != null && widget.pendingNew == widget.current;
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final c = await widget.load();
      if (!mounted) return;
      setState(() => _cats = c);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = catalogErrorText(e));
    }
  }

  String get _typed => _query.trim().replaceAll(RegExp(r'\s+'), ' ');

  void _pick(String name, {bool isNew = false}) => setState(() {
    _picked = name;
    _isNew = isNew;
  });

  Widget _row(String name, String? count, {bool isNew = false, bool none = false}) {
    final on = _picked == name && _isNew == isNew;
    final label = none ? 'No category' : (isNew ? 'Create "$name" as a new category' : name);
    return Semantics(
      button: true,
      selected: on,
      label: isNew ? 'Create the category $name' : (count == null ? label : '$label, $count'),
      excludeSemantics: true,
      child: InkWell(
        mouseCursor: WidgetStateMouseCursor.clickable,
        key: ValueKey(isNew ? 'pick-new-category' : (none ? 'pick-no-category' : 'pick-category:$name')),
        borderRadius: BorderRadius.circular(8),
        onTap: () => _pick(name, isNew: isNew),
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
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                    color: none ? DashUi.slate : DashUi.ink,
                    fontStyle: none ? FontStyle.italic : FontStyle.normal,
                  ),
                ),
              ),
              if (name == widget.current && !isNew && !none) ...[
                const CatalogTag('Now'),
                const SizedBox(width: 8),
              ],
              if (count != null) Text(count, style: const TextStyle(fontSize: 12.5, color: DashUi.subtle, fontFeatures: CatalogUi.figures)),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cats = _cats;
    Widget body;
    if (cats == null && _error == null) {
      body = const SizedBox(
        height: 160,
        child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.2, color: DashUi.slate))),
      );
    } else if (cats == null) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppNotice('The categories could not be loaded: $_error', kind: AppNoticeKind.error),
          const SizedBox(height: 10),
          Align(alignment: Alignment.centerLeft, child: AppButton.ghost('Try again', _load)),
        ],
      );
    } else {
      final all = cats.keys.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      final q = _query.trim().toLowerCase();
      final rows = q.isEmpty ? all : all.where((c) => c.toLowerCase().contains(q)).toList();
      final typed = _typed;
      final exists = cats.keys.any((c) => catalogNorm(c) == catalogNorm(typed));
      final pending = widget.pendingNew;
      final offerNew = widget.canCreate && typed.isNotEmpty && !exists && typed.length <= 120;
      final items = [
        if (offerNew) _row(typed, null, isNew: true),
        if (!offerNew && pending != null && !cats.containsKey(pending) && (q.isEmpty || pending.toLowerCase().contains(q))) _row(pending, null, isNew: true),
        if (q.isEmpty && widget.current.isNotEmpty) _row('', null, none: true),
        for (final c in rows) _row(c, cats[c] == null ? null : _count.format(cats[c])),
      ];
      final alike = _isNew ? categoryLookalikes(_picked, cats.keys) : const <String>[];
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CatalogSearchField(
            controller: _search,
            hint: 'Find a category, or type a new one',
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
            height: math.min(alike.isEmpty ? 340 : 240, math.max(1, items.length) * 38.0 + 4),
            child: items.isEmpty
                ? const Center(child: Text('No category matches', style: CatalogUi.meta))
                : ListView(padding: EdgeInsets.zero, children: items),
          ),
          if (alike.isNotEmpty) ...[
            const SizedBox(height: 8),
            CategoryLookalikeNotice(typed: _picked, alike: alike, counts: cats, onPick: (name) => _pick(name)),
          ] else if (_isNew) ...[
            const SizedBox(height: 8),
            AppNotice('"$_picked" becomes a new category when you save the product.'),
          ],
        ],
      );
    }
    final changed = _picked != widget.current || (_isNew && widget.pendingNew != _picked);
    return AppDialog(
      title: 'Pick a category',
      subtitle: widget.current.isEmpty ? 'Not in a category yet' : 'Now in ${widget.current}',
      icon: Icons.folder_outlined,
      width: 520,
      body: body,
      actions: [
        AppButton.ghost('Cancel', () => Navigator.pop(context)),
        AppButton.ink(
          _isNew ? 'Create and use it' : 'Use this category',
          cats == null || !changed ? null : () => Navigator.pop(context, (name: _picked, isNew: _isNew)),
          icon: Icons.check_rounded,
        ),
      ],
    );
  }
}

// ---- marks on a Cleanup finding ----------------------------------------------------------------------------------

/// What marking a finding did: the saved mark, or [reload] when someone changed the mark in the meantime.
typedef CatalogMarkOutcome = ({CatalogReview? review, bool reload});

/// Marks a Cleanup finding (a group of possible duplicates, or one product under one check) as reviewed or to follow
/// up, with an optional note, after showing its earlier marks. The save is checked against the mark this page showed
/// ([current]): if someone changed it since, nothing is saved and the page reloads.
Future<CatalogMarkOutcome?> showFindingMarkDialog(
  BuildContext context, {
  required CatalogManager manager,
  required String issueKey,
  required String signature,
  String? basis,
  required String title,
  required String label,
  required String status,
  CatalogReview? current,
  required String lapses,
}) {
  return showDialog<CatalogMarkOutcome>(
    context: context,
    builder: (_) => _MarkDialog(
      manager: manager,
      issueKey: issueKey,
      signature: signature,
      basis: basis,
      title: title,
      label: label,
      status: status,
      current: current,
      lapses: lapses,
    ),
  );
}

class _MarkDialog extends StatefulWidget {
  final CatalogManager manager;
  final String issueKey;
  final String signature;
  final String? basis;
  final String title;
  final String label;
  final String status;
  final CatalogReview? current;
  final String lapses;
  const _MarkDialog({
    required this.manager,
    required this.issueKey,
    required this.signature,
    required this.basis,
    required this.title,
    required this.label,
    required this.status,
    required this.current,
    required this.lapses,
  });

  @override
  State<_MarkDialog> createState() => _MarkDialogState();
}

class _MarkDialogState extends State<_MarkDialog> {
  late String _status = widget.status;
  // Starts empty: the mark it replaces (and its note) stays in the history below.
  final _note = TextEditingController();
  bool _busy = false;
  String? _error;
  bool _stale = false;
  List<CatalogAuditEntry>? _history;
  bool _historyFailed = false;

  @override
  void initState() {
    super.initState();
    widget.manager
        .reviewHistory(widget.issueKey)
        .then((h) {
          if (mounted) setState(() => _history = h);
        })
        .catchError((Object _) {
          if (mounted) setState(() => _historyFailed = true);
        });
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final note = _note.text.trim();
      final saved = await widget.manager.markReviewed(
        widget.issueKey,
        widget.signature,
        note: note.isEmpty ? null : note,
        label: widget.label,
        status: _status,
        basis: widget.basis,
        checkExpected: true,
        expectedStamp: widget.current?.stamp,
      );
      if (mounted) Navigator.pop(context, (review: saved, reload: false));
    } on LineItemsException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _stale = e.status == 409;
        _error = e.status == 409 && e.code == 'CHANGED' ? 'Someone else changed this mark after you opened the list. Nothing was saved.' : catalogErrorText(e);
      });
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
    final follow = _status == 'follow_up';
    final history = _history ?? const <CatalogAuditEntry>[];
    return AppDialog(
      title: follow ? 'Mark to follow up' : 'Mark as reviewed',
      subtitle: widget.title,
      icon: follow ? Icons.flag_outlined : Icons.task_alt_rounded,
      width: 540,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppSegmented<String>(
            value: _status,
            options: const [('reviewed', 'Reviewed: fine as it is'), ('follow_up', 'Follow up: still to sort out')],
            onChanged: (v) => setState(() => _status = v),
            dense: true,
          ),
          const SizedBox(height: 14),
          AppFieldLabel(
            'Why (optional)',
            help: follow ? 'What still needs doing, and who is on it.' : 'Why it is right as it is, for whoever looks next.',
          ),
          TextField(
            key: const ValueKey('mark-note'),
            controller: _note,
            autofocus: true,
            maxLines: 3,
            maxLength: 600,
            style: const TextStyle(fontSize: 14.5, color: DashUi.ink),
            decoration: appFieldDecoration().copyWith(counterText: ''),
          ),
          const SizedBox(height: 8),
          Text(
            follow
                ? 'It moves to Follow up and off the open count. Nothing about the product changes. ${widget.lapses}'
                : 'It moves to Reviewed and off the open count. Nothing about the product changes. ${widget.lapses}',
            style: CatalogUi.meta.copyWith(fontSize: 13),
          ),
          if (history.isNotEmpty) ...[
            const SizedBox(height: 14),
            CatalogMarkHistory(entries: history, max: 4),
          ] else if (_historyFailed) ...[
            const SizedBox(height: 10),
            const Text('Earlier marks could not be loaded.', style: CatalogUi.meta),
          ],
          if (_error != null) ...[const SizedBox(height: 12), AppNotice(_error!, kind: _stale ? AppNoticeKind.warning : AppNoticeKind.error)],
        ],
      ),
      actions: [
        if (_stale)
          AppButton.ink('Reload the list', () => Navigator.pop(context, (review: null, reload: true)), icon: Icons.refresh_rounded)
        else ...[
          AppButton.ghost('Cancel', _busy ? null : () => Navigator.pop(context)),
          AppButton.ink(_busy ? 'Saving…' : (follow ? 'Mark to follow up' : 'Mark reviewed'), _busy ? null : _save, icon: _busy ? null : Icons.check_rounded),
        ],
      ],
    );
  }
}

/// A finding's earlier marks, newest first: who, when, what, and the note.
class CatalogMarkHistory extends StatelessWidget {
  final List<CatalogAuditEntry> entries;
  final int? max;
  const CatalogMarkHistory({super.key, required this.entries, this.max});

  static final _when = DateFormat('MMM d, y · h:mm a');

  static String verb(String action) => switch (action) {
    'review.mark' => 'Marked reviewed',
    'review.follow_up' => 'Marked to follow up',
    'review.clear' => 'Took the mark off',
    _ => action,
  };

  @override
  Widget build(BuildContext context) {
    final shown = max == null ? entries : entries.take(max!).toList();
    return Column(
      key: const ValueKey('mark-history'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'HISTORY${entries.length > shown.length ? ' (latest ${shown.length} of ${entries.length})' : ''}',
          style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, letterSpacing: 0.6, color: DashUi.subtle),
        ),
        const SizedBox(height: 4),
        for (final e in shown)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                    e.action == 'review.follow_up'
                        ? Icons.flag_outlined
                        : e.action == 'review.clear'
                        ? Icons.undo_rounded
                        : Icons.task_alt_rounded,
                    size: 15,
                    color: DashUi.slate,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '${verb(e.action)}${e.by.isEmpty ? '' : ' by ${e.by}'}',
                          style: const TextStyle(fontWeight: FontWeight.w700, color: DashUi.ink),
                        ),
                        if (e.at != null) TextSpan(text: '  ·  ${_when.format(e.at!)}'),
                        if ((e.details['note'] ?? '').toString().isNotEmpty) TextSpan(text: '\n"${e.details['note']}"', style: const TextStyle(fontStyle: FontStyle.italic)),
                        if (e.details['pricing'] == true) const TextSpan(text: '\nA pricing check (details need the cost switch)'),
                      ],
                    ),
                    style: CatalogUi.meta.copyWith(fontSize: 13, height: 1.35),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// A finding's whole history in a dialog (the Cleanup view's History button on a marked finding).
Future<void> showFindingHistoryDialog(BuildContext context, {required CatalogManager manager, required String issueKey, required String title}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AppDialog(
      title: 'Review history',
      subtitle: title,
      icon: Icons.history_rounded,
      width: 540,
      body: FutureBuilder<List<CatalogAuditEntry>>(
        future: manager.reviewHistory(issueKey),
        builder: (context, snap) {
          if (snap.hasError) return AppNotice('The history could not be loaded: ${catalogErrorText(snap.error!)}', kind: AppNoticeKind.error);
          if (!snap.hasData) {
            return const SizedBox(
              height: 80,
              child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.2, color: DashUi.slate))),
            );
          }
          if (snap.data!.isEmpty) return const Text('No marks yet.', style: CatalogUi.meta);
          return ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 420),
            child: SingleChildScrollView(child: CatalogMarkHistory(entries: snap.data!)),
          );
        },
      ),
      actions: [AppButton.ink('Close', () => Navigator.pop(ctx))],
    ),
  );
}
