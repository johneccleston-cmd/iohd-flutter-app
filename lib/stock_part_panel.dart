import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'config/access.dart';
import 'config/auth_session.dart';
import 'stock_levels_api.dart';
import 'widgets/app_dialog.dart';
import 'widgets/catalog_kit.dart';
import 'widgets/dashboard_kit.dart';

/// Stock Levels' dialogs (UI audit 2026-11-25): one part's page (G1: its numbers, copy buttons, history, last count,
/// catalog link, and the office correction for admins, G2), the correction itself, and the checkout names that took
/// nothing off stock (G6).

final NumberFormat _count = NumberFormat.decimalPattern();
final NumberFormat _money = NumberFormat.simpleCurrency(decimalDigits: 2);

String stockQty(num n) => _count.format(n);

Color stockStatusColor(StockStatus s) => switch (s) {
  StockStatus.negative || StockStatus.out => DashUi.redText,
  StockStatus.low => DashUi.amberText,
  StockStatus.ok => DashUi.emeraldText,
  StockStatus.none => DashUi.slate,
};

void _snack(BuildContext context, String text) =>
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(behavior: SnackBarBehavior.floating, content: Text(text)));

/// Copies [text] and says so.
Future<void> copyStockText(BuildContext context, String text, String what) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) _snack(context, '$what copied');
}

/// The part's page, as a dialog over the list. Returns true when the part's quantity was changed here (the list then
/// reloads). [history] is for tests.
Future<bool> showStockPart(BuildContext context, StockItem item, {bool canAdjust = false, Future<StockHistory> Function(String name)? history}) async {
  final changed = await showDialog<bool>(
    context: context,
    builder: (_) => _StockPartDialog(item: item, canAdjust: canAdjust, history: history ?? fetchStockHistory),
  );
  return changed == true;
}

class _StockPartDialog extends StatefulWidget {
  final StockItem item;
  final bool canAdjust;
  final Future<StockHistory> Function(String name) history;
  const _StockPartDialog({required this.item, required this.canAdjust, required this.history});

  @override
  State<_StockPartDialog> createState() => _StockPartDialogState();
}

class _StockPartDialogState extends State<_StockPartDialog> {
  late StockItem _item = widget.item;
  late Future<StockHistory> _hist = widget.history(widget.item.name);
  bool _changed = false;

  Future<void> _adjust() async {
    final after = await showStockAdjust(context, _item);
    if (after == null || !mounted) return;
    setState(() {
      _changed = true;
      _item = StockItem(
        name: _item.name,
        category: _item.category,
        partNumber: _item.partNumber,
        sheetPartNumber: _item.sheetPartNumber,
        location: _item.location,
        qty: after,
        reorderPoint: _item.reorderPoint,
        cost: _item.cost,
        discontinued: _item.discontinued,
      );
      _hist = widget.history(_item.name);
    });
  }

  Widget _fact(String label, String value, {Color? color, bool strong = false}) {
    return SizedBox(
      width: 150,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(), style: CatalogUi.head),
          const SizedBox(height: 4),
          Text(value, style: (strong ? CatalogUi.cellStrong : CatalogUi.cell).copyWith(color: color)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final i = _item;
    final rp = i.reorderPoint ?? 0;
    final color = stockStatusColor(i.status);
    final router = GoRouter.maybeOf(context);
    return AppDialog(
      title: i.name,
      subtitle: i.category,
      icon: accessIcon('stock'),
      width: 620,
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                CatalogTag(i.status.filterLabel, tone: switch (i.status) {
                  StockStatus.negative || StockStatus.out => CatalogTone.danger,
                  StockStatus.low => CatalogTone.warn,
                  StockStatus.ok => CatalogTone.good,
                  StockStatus.none => CatalogTone.neutral,
                }),
                if (i.discontinued) const CatalogTag('Discontinued', tone: CatalogTone.neutral, icon: Icons.block_rounded),
              ],
            ),
            const SizedBox(height: 6),
            Text(i.status.meaning, style: CatalogUi.meta),
            const SizedBox(height: 16),
            Wrap(
              spacing: 16,
              runSpacing: 14,
              children: [
                _fact('Part #', i.discontinued ? 'Discontinued' : (i.partNumber.isEmpty ? '—' : i.partNumber)),
                _fact('Shelf', i.location.isEmpty ? '—' : i.location),
                _fact('On hand', stockQty(i.qty), color: i.status.needsAttention ? color : null, strong: true),
                _fact('Reorder point', rp > 0 ? stockQty(rp) : 'None set'),
                _fact('To order', i.toOrder > 0 ? stockQty(i.toOrder) : '—', strong: i.toOrder > 0),
                if (i.cost != null) _fact('Unit cost', _money.format(i.cost)),
                if (i.value != null) _fact('Value on hand', _money.format(i.value)),
              ],
            ),
            if (i.toOrder > 0) ...[
              const SizedBox(height: 10),
              Text('To order brings it back to its reorder point (at least 1).', style: CatalogUi.meta),
            ],
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (i.partNumber.isNotEmpty)
                  CatalogOutlineButton(icon: Icons.copy_rounded, label: 'Copy part #', onPressed: () => copyStockText(context, i.partNumber, 'Part number')),
                CatalogOutlineButton(icon: Icons.copy_all_rounded, label: 'Copy name', onPressed: () => copyStockText(context, i.name, 'Name')),
                FutureBuilder<StockHistory>(
                  future: _hist,
                  builder: (context, s) {
                    final id = s.data?.catalogProductId;
                    if (id == null || router == null) return const SizedBox.shrink();
                    return CatalogOutlineButton(
                      icon: Icons.open_in_new_rounded,
                      label: 'Open in Product Catalog',
                      onPressed: () {
                        Navigator.pop(context, _changed);
                        router.go('/inventory/catalog/$id');
                      },
                    );
                  },
                ),
                if (widget.canAdjust) CatalogOutlineButton(icon: Icons.edit_note_rounded, label: 'Change stock', onPressed: _adjust),
              ],
            ),
            const SizedBox(height: 20),
            const CatalogLabel('HISTORY'),
            const SizedBox(height: 8),
            FutureBuilder<StockHistory>(
              future: _hist,
              builder: (context, s) {
                if (s.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Row(children: [
                      SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: DashUi.slate)),
                      SizedBox(width: 10),
                      Text('Loading history', style: CatalogUi.meta),
                    ]),
                  );
                }
                if (s.hasError) {
                  return Row(
                    children: [
                      Expanded(child: AppNotice('${s.error}', kind: AppNoticeKind.error)),
                      const SizedBox(width: 8),
                      AppButton.ghost('Try again', () => setState(() => _hist = widget.history(i.name))),
                    ],
                  );
                }
                final h = s.data!;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (h.lastCount != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Text(
                          'Last cycle count: ${stockQty(h.lastCount!.counted)} counted'
                          '${h.lastCount!.counted == h.lastCount!.expected ? ', as expected' : ' (the system said ${stockQty(h.lastCount!.expected)})'}'
                          '${h.lastCount!.at == null ? '' : ' on ${DateFormat('MMM d, y').format(h.lastCount!.at!)}'}'
                          '${h.lastCount!.by.isEmpty ? '' : ' by ${h.lastCount!.by}'}.',
                          style: CatalogUi.meta.copyWith(color: DashUi.ink),
                        ),
                      ),
                    if (h.movements.isEmpty)
                      const Text('No checkouts, scans or counts of this part are in the stock log.', style: CatalogUi.meta)
                    else
                      for (var n = 0; n < h.movements.length; n++) _MovementRow(m: h.movements[n], index: n),
                  ],
                );
              },
            ),
          ],
        ),
      ),
      actions: [AppButton.ink('Close', () => Navigator.pop(context, _changed))],
    );
  }
}

class _MovementRow extends StatelessWidget {
  final StockMovement m;
  final int index;
  const _MovementRow({required this.m, required this.index});

  @override
  Widget build(BuildContext context) {
    final ch = m.change;
    final change = ch == null ? '' : (ch > 0 ? '+${stockQty(ch)}' : (ch < 0 ? '−${stockQty(-ch)}' : '±0'));
    final what = m.kind.contains('count') ? '${m.label} · ${m.qty == null ? '' : 'set to ${stockQty(m.qty!)}'}' : m.label;
    return Container(
      color: index.isOdd ? CatalogUi.stripe : null,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 86, child: Text(m.date, style: CatalogUi.meta)),
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: what, style: const TextStyle(fontWeight: FontWeight.w600)),
                if (m.person.isNotEmpty) TextSpan(text: '  ·  ${m.person}', style: const TextStyle(color: DashUi.slate)),
                if (m.note.isNotEmpty) TextSpan(text: '  ·  ${m.note}', style: const TextStyle(color: DashUi.slate)),
              ]),
              style: const TextStyle(fontSize: 13.5, color: DashUi.ink, height: 1.35),
            ),
          ),
          SizedBox(
            width: 64,
            child: Text(
              change,
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, fontFeatures: CatalogUi.figures, color: ch != null && ch < 0 ? DashUi.ink : DashUi.emeraldText),
            ),
          ),
        ],
      ),
    );
  }
}

/// The office correction (G2): receive, remove or set the count, with a reason. Returns the new quantity, or null when
/// cancelled. [send] is for tests.
Future<int?> showStockAdjust(
  BuildContext context,
  StockItem item, {
  Future<({int after, String? warning})> Function({required StockItem item, required StockAdjustAction action, required int qty, required String reason})? send,
}) {
  return showDialog<int>(context: context, builder: (_) => _AdjustDialog(item: item, send: send ?? adjustStock));
}

class _AdjustDialog extends StatefulWidget {
  final StockItem item;
  final Future<({int after, String? warning})> Function({required StockItem item, required StockAdjustAction action, required int qty, required String reason}) send;
  const _AdjustDialog({required this.item, required this.send});

  @override
  State<_AdjustDialog> createState() => _AdjustDialogState();
}

class _AdjustDialogState extends State<_AdjustDialog> {
  StockAdjustAction _action = StockAdjustAction.receive;
  final _qty = TextEditingController();
  final _reason = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _qty.dispose();
    _reason.dispose();
    super.dispose();
  }

  int? get _n {
    final t = _qty.text.trim().replaceAll(',', '');
    if (!RegExp(r'^\d{1,6}$').hasMatch(t)) return null;
    final n = int.parse(t);
    if (n > 100000) return null;
    if (_action != StockAdjustAction.set && n == 0) return null;
    return n;
  }

  int? get _after {
    final n = _n;
    if (n == null) return null;
    final q = widget.item.qty;
    return switch (_action) {
      StockAdjustAction.receive => q + n,
      StockAdjustAction.remove => q - n,
      StockAdjustAction.set => n,
    };
  }

  bool get _ready => !_busy && _after != null && _after! >= 0 && _reason.text.trim().isNotEmpty;

  Future<void> _save() async {
    if (!_ready) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await widget.send(item: widget.item, action: _action, qty: _n!, reason: _reason.text.trim());
      if (!mounted) return;
      if (r.warning != null) _snack(context, r.warning!);
      Navigator.pop(context, r.after);
    } on StockApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final i = widget.item;
    final after = _after;
    final qtyLabel = switch (_action) {
      StockAdjustAction.receive => 'How many came in',
      StockAdjustAction.remove => 'How many to take off',
      StockAdjustAction.set => 'Counted on the shelf',
    };
    final hint = switch (_action) {
      StockAdjustAction.receive => 'e.g. the PO number or the delivery',
      StockAdjustAction.remove => 'e.g. damaged, returned to vendor',
      StockAdjustAction.set => 'e.g. shelf count',
    };
    return AppDialog(
      title: 'Change stock',
      subtitle: i.name,
      icon: Icons.edit_note_rounded,
      width: 480,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppSegmented<StockAdjustAction>(
            value: _action,
            options: const [(StockAdjustAction.receive, 'Receive'), (StockAdjustAction.remove, 'Remove'), (StockAdjustAction.set, 'Set count')],
            onChanged: (v) => setState(() {
              _action = v;
              _error = null;
            }),
          ),
          const SizedBox(height: 16),
          Text(qtyLabel, style: CatalogUi.groupTitle),
          const SizedBox(height: 6),
          TextField(
            controller: _qty,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
            decoration: catalogFieldDecoration(hint: _action == StockAdjustAction.set ? '0 or more' : '1 or more', filled: true),
            style: CatalogUi.fieldText,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 14),
          Text('Why', style: CatalogUi.groupTitle),
          const SizedBox(height: 6),
          TextField(
            controller: _reason,
            maxLength: 200,
            decoration: catalogFieldDecoration(hint: hint, filled: true).copyWith(counterText: ''),
            style: CatalogUi.fieldText,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 14),
          Text.rich(
            TextSpan(children: [
              const TextSpan(text: 'On hand  ', style: TextStyle(color: DashUi.slate)),
              TextSpan(text: stockQty(i.qty), style: const TextStyle(fontWeight: FontWeight.w700)),
              const TextSpan(text: '  →  ', style: TextStyle(color: DashUi.slate)),
              TextSpan(
                text: after == null ? '…' : stockQty(after),
                style: TextStyle(fontWeight: FontWeight.w800, color: after != null && after < 0 ? DashUi.redText : DashUi.ink),
              ),
            ]),
            style: const TextStyle(fontSize: 14.5, color: DashUi.ink, fontFeatures: CatalogUi.figures),
          ),
          if (after != null && after < 0) ...[
            const SizedBox(height: 8),
            AppNotice('Only ${stockQty(i.qty)} on hand, so ${stockQty(_n!)} can\'t be taken off.', kind: AppNoticeKind.warning),
          ],
          const SizedBox(height: 10),
          const Text(
            'Saved to the inventory sheet and its stock log with your name and the reason. If the sheet changed since this page '
            'loaded, nothing is saved and you\'ll see the new number.',
            style: CatalogUi.meta,
          ),
          if (_error != null) ...[const SizedBox(height: 10), AppNotice(_error!, kind: AppNoticeKind.error)],
        ],
      ),
      actions: [
        AppButton.ghost('Cancel', _busy ? null : () => Navigator.pop(context)),
        AppButton.ink(_busy ? 'Saving…' : 'Save', _ready ? _save : null),
      ],
    );
  }
}

/// The checkout names that took nothing off stock (G6). [onShowPart] searches the list for the part a name probably
/// means. [load] is for tests.
Future<void> showUnmatchedCheckouts(BuildContext context, {required void Function(String part) onShowPart, Future<List<UnmatchedCheckout>> Function()? load}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => _UnmatchedDialog(load: load ?? fetchUnmatchedCheckouts, onShowPart: (p) {
      Navigator.pop(ctx);
      onShowPart(p);
    }),
  );
}

class _UnmatchedDialog extends StatefulWidget {
  final Future<List<UnmatchedCheckout>> Function() load;
  final void Function(String part) onShowPart;
  const _UnmatchedDialog({required this.load, required this.onShowPart});

  @override
  State<_UnmatchedDialog> createState() => _UnmatchedDialogState();
}

class _UnmatchedDialogState extends State<_UnmatchedDialog> {
  late Future<List<UnmatchedCheckout>> _f = widget.load();

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.sizeOf(context).height;
    return AppDialog(
      title: 'Checkouts that missed the shelf',
      subtitle: 'Job lines whose name has no row on the inventory sheet but probably means one. Nothing came off stock for them.',
      icon: Icons.link_off_rounded,
      width: 680,
      body: SizedBox(
        height: (h * 0.6).clamp(240.0, 560.0),
        child: FutureBuilder<List<UnmatchedCheckout>>(
          future: _f,
          builder: (context, s) {
            if (s.connectionState != ConnectionState.done) {
              return const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: DashUi.slate)));
            }
            if (s.hasError) {
              return Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  AppNotice('${s.error}', kind: AppNoticeKind.error),
                  const SizedBox(height: 10),
                  AppButton.ghost('Try again', () => setState(() => _f = widget.load())),
                ]),
              );
            }
            final list = s.data!;
            if (list.isEmpty) {
              return const Center(child: Text('Every stocked checkout matched a shelf part.', style: CatalogUi.body));
            }
            return ListView.builder(
              itemCount: list.length,
              itemBuilder: (_, n) {
                final u = list[n];
                return Container(
                  color: n.isOdd ? CatalogUi.stripe : null,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(u.name, style: CatalogUi.name),
                            const SizedBox(height: 2),
                            Text(
                              '${u.lines == 1 ? '1 checkout' : '${u.lines} checkouts'}, ${stockQty(u.units)} ${u.units == 1 ? 'unit' : 'units'} not taken off'
                              '${u.lastDate.isEmpty ? '' : ' · latest ${u.lastDate}'}${u.jobs.isEmpty ? '' : ' · jobs ${u.jobs.join(', ')}'}',
                              style: CatalogUi.meta,
                            ),
                            if (u.probablePart != null) ...[
                              const SizedBox(height: 2),
                              Text.rich(
                                TextSpan(children: [
                                  const TextSpan(text: 'Probably  ', style: TextStyle(color: DashUi.slate)),
                                  TextSpan(text: u.probablePart, style: const TextStyle(fontWeight: FontWeight.w600)),
                                  if (u.probablePartNumber.isNotEmpty || u.probableShelf.isNotEmpty)
                                    TextSpan(
                                      text: '  (${[if (u.probablePartNumber.isNotEmpty) 'part ${u.probablePartNumber}', if (u.probableShelf.isNotEmpty) 'shelf ${u.probableShelf}'].join(', ')})',
                                      style: const TextStyle(color: DashUi.slate),
                                    ),
                                ]),
                                style: const TextStyle(fontSize: 13, color: DashUi.ink),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (u.probablePart != null) ...[
                        const SizedBox(width: 10),
                        CatalogOutlineButton(icon: Icons.search_rounded, label: 'Show part', onPressed: () => widget.onShowPart(u.probablePart!)),
                      ],
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
      footer: const Padding(
        padding: EdgeInsets.only(top: 8),
        child: Text(
          'To fix one: correct the stock with Change stock on the part, then ask an admin to match the Service Fusion name to the sheet.',
          style: CatalogUi.meta,
        ),
      ),
      actions: [AppButton.ink('Close', () => Navigator.pop(context))],
    );
  }
}

/// Whether the signed-in person may correct stock: admins and owners (the server checks it too).
bool get canAdjustStock => AuthSession.instance.isAdmin;
