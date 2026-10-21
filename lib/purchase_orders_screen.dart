import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'config/access.dart';
import 'config/api_config.dart';
import 'config/auth_session.dart';
import 'widgets/dashboard_kit.dart';
import 'widgets/flat_page.dart';

const _statuses = ['Open', 'Received', 'Canceled'];
const _monthNames = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _isoDate(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
String _niceDate(DateTime? d) => d == null ? '' : '${_monthNames[d.month - 1]} ${d.day}, ${d.year}';

class _PurchaseOrder {
  final int id;
  final String poNumber, vendor, status, notes;
  final DateTime? orderDate, expectedDate, receivedDate;
  final double total;

  _PurchaseOrder(Map<String, dynamic> j)
    : id = (j['id'] as num).toInt(),
      poNumber = '${j['poNumber'] ?? ''}',
      vendor = '${j['vendor'] ?? ''}',
      status = '${j['status'] ?? ''}',
      notes = '${j['notes'] ?? ''}',
      orderDate = DateTime.tryParse('${j['orderDate'] ?? ''}'),
      expectedDate = DateTime.tryParse('${j['expectedDate'] ?? ''}'),
      receivedDate = DateTime.tryParse('${j['receivedDate'] ?? ''}'),
      total = (j['total'] as num?)?.toDouble() ?? 0;

  bool get isOpen => status == 'Open';

  /// Still open and the expected date is before today.
  bool get isPastDue {
    final e = expectedDate;
    if (!isOpen || e == null) return false;
    final now = DateTime.now();
    return e.isBefore(DateTime(now.year, now.month, now.day));
  }
}

class PurchaseOrdersScreen extends StatefulWidget {
  const PurchaseOrdersScreen({super.key});

  @override
  State<PurchaseOrdersScreen> createState() => _PurchaseOrdersScreenState();
}

class _PurchaseOrdersScreenState extends State<PurchaseOrdersScreen> {
  List<_PurchaseOrder> _orders = [];
  bool _loading = true;
  String? _error;
  int _requestId = 0;

  String _query = '';
  String? _status; // null = all

  final _session = AuthSession.instance;
  bool get _canCreate => _session.can('purchase_orders', AccessAction.create);
  bool get _canUpdate => _session.can('purchase_orders', AccessAction.update);
  bool get _canDelete => _session.can('purchase_orders', AccessAction.delete);

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// One API call. Returns the decoded body; throws an Exception with a message fit to show the person.
  Future<Map<String, dynamic>> _send(String method, String path, [Map<String, dynamic>? body]) async {
    final req = http.Request(method, Uri.parse('$kApiBaseUrl/api$path'))..headers.addAll(_session.headers());
    if (body != null) req.body = json.encode(body);
    final res = await http.Response.fromStream(await req.send().timeout(const Duration(seconds: 30)));
    if (res.statusCode == 401) {
      _session.logout();
      throw Exception('Your session expired. Sign in again.');
    }
    Map<String, dynamic> data = {};
    try {
      data = json.decode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {}
    if (res.statusCode >= 400) throw Exception(data['error'] ?? 'Server error (${res.statusCode})');
    return data;
  }

  Future<void> _load() async {
    final id = ++_requestId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await _send('GET', '/purchase-orders');
      if (!mounted || id != _requestId) return;
      setState(() {
        _orders = [for (final j in (data['purchaseOrders'] as List? ?? const [])) _PurchaseOrder(j as Map<String, dynamic>)];
        _loading = false;
      });
    } catch (e) {
      if (!mounted || id != _requestId) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  List<_PurchaseOrder> get _shown {
    final q = _query.trim().toLowerCase();
    return [
      for (final po in _orders)
        if ((_status == null || po.status == _status) && (q.isEmpty || '${po.poNumber} ${po.vendor}'.toLowerCase().contains(q))) po,
    ];
  }

  List<String> get _vendors => ({for (final po in _orders) po.vendor}..remove('')).toList()..sort();

  Color _statusColor(String status) => switch (status) {
    'Open' => DashUi.amber,
    'Received' => DashUi.emeraldDeep,
    _ => DashUi.muted,
  };

  Future<void> _edit(_PurchaseOrder? existing) async {
    final message = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PoEditor(
        po: existing,
        vendors: _vendors,
        canSave: existing == null ? _canCreate : _canUpdate,
        canDelete: existing != null && _canDelete,
        onSave: (body) async {
          try {
            if (existing == null) {
              await _send('POST', '/purchase-orders', body);
            } else {
              await _send('PUT', '/purchase-orders/${existing.id}', body);
            }
            return null;
          } catch (e) {
            return e.toString().replaceFirst('Exception: ', '');
          }
        },
        onDelete: () async {
          try {
            await _send('DELETE', '/purchase-orders/${existing!.id}');
            return null;
          } catch (e) {
            return e.toString().replaceFirst('Exception: ', '');
          }
        },
      ),
    );
    if (message == null || !mounted) return;
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageBanner(
            title: 'Purchase Orders',
            actions: [
              if (_canCreate) PageBanner.button(icon: Icons.add_rounded, label: 'Create PO', onPressed: _loading ? null : () => _edit(null)),
              PageBanner.refresh(onPressed: _loading ? null : _load),
            ],
          ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading && _orders.isEmpty) return const Center(child: CircularProgressIndicator());
    if (_error != null && _orders.isEmpty) {
      return Center(child: DashErrorPanel(title: "Couldn't load purchase orders", message: _error!, onRetry: _load));
    }
    if (_orders.isEmpty) {
      return const Center(
        child: FlatEmpty(
          icon: Icons.shopping_cart_checkout_rounded,
          title: 'No purchase orders yet',
          message: 'Create the first PO to start tracking what is on order from vendors.',
        ),
      );
    }

    final open = [for (final po in _orders) if (po.isOpen) po];
    final openValue = open.fold<double>(0, (a, po) => a + po.total);
    final pastDue = open.where((po) => po.isPastDue).length;
    final cutoff = DateTime.now().subtract(const Duration(days: 30));
    final receivedValue = _orders
        .where((po) => po.status == 'Received' && (po.receivedDate ?? po.orderDate ?? DateTime(2000)).isAfter(cutoff))
        .fold<double>(0, (a, po) => a + po.total);
    final shown = _shown;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FlatStats(
            stats: [
              FlatStat('Open Orders', '${open.length}', tone: DashUi.amber),
              FlatStat('Open Value', dashMoney(openValue)),
              FlatStat('Past Due', '$pastDue', tone: pastDue == 0 ? DashUi.emeraldDeep : DashUi.red),
              FlatStat('Received (30d)', dashMoney(receivedValue)),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
            child: Wrap(
              spacing: 12,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 340,
                  child: TextField(
                    style: const TextStyle(fontSize: 14),
                    decoration: flatSearchDecoration('Search PO number or vendor...'),
                    onChanged: (v) => setState(() => _query = v),
                  ),
                ),
                for (final s in [null, ..._statuses])
                  ChoiceChip(label: Text(s ?? 'All'), selected: _status == s, onSelected: (_) => setState(() => _status = s)),
              ],
            ),
          ),
          if (shown.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: FlatEmpty(icon: Icons.search_off_rounded, title: 'No purchase orders found', message: 'Try a different search or status filter.'),
            )
          else
            FlatTable(
              columns: const [
                FlatCol('PO Number', flex: 3),
                FlatCol('Vendor', flex: 4),
                FlatCol('Ordered', flex: 3),
                FlatCol('Expected', flex: 3),
                FlatCol('Total', flex: 3, right: true),
                FlatCol('Status', flex: 3),
              ],
              onRowTap: (i) => _edit(shown[i]),
              rows: [
                for (final po in shown)
                  [
                    Text(po.poNumber, style: flatCellBold),
                    Text(po.vendor, style: flatCellStyle),
                    Text(_niceDate(po.orderDate), style: flatCellMuted),
                    Text(
                      po.expectedDate == null ? '—' : _niceDate(po.expectedDate),
                      style: po.isPastDue ? flatCellStyle.copyWith(color: DashUi.red, fontWeight: FontWeight.w700) : flatCellMuted,
                    ),
                    Text(dashMoney(po.total), style: flatCellStyle.copyWith(fontFeatures: flatFigures)),
                    FlatStatus(po.isPastDue ? 'Past due' : po.status, po.isPastDue ? DashUi.red : _statusColor(po.status)),
                  ],
              ],
            ),
        ],
      ),
    );
  }
}

// ─── editor dialog ──────────────────────────────────────────────────────────

class _PoEditor extends StatefulWidget {
  final _PurchaseOrder? po; // null = new
  final List<String> vendors;
  final bool canSave;
  final bool canDelete;

  /// Each returns an error message, or null when it worked.
  final Future<String?> Function(Map<String, dynamic> body) onSave;
  final Future<String?> Function() onDelete;

  const _PoEditor({required this.po, required this.vendors, required this.canSave, required this.canDelete, required this.onSave, required this.onDelete});

  @override
  State<_PoEditor> createState() => _PoEditorState();
}

class _PoEditorState extends State<_PoEditor> {
  late final _number = TextEditingController(text: widget.po?.poNumber ?? '');
  late final _vendor = TextEditingController(text: widget.po?.vendor ?? '');
  late final _total = TextEditingController(text: widget.po == null ? '' : widget.po!.total.toStringAsFixed(2));
  late final _notes = TextEditingController(text: widget.po?.notes ?? '');
  late String _status = widget.po?.status.isNotEmpty == true ? widget.po!.status : 'Open';
  late DateTime _ordered = widget.po?.orderDate ?? DateTime.now();
  late DateTime? _expected = widget.po?.expectedDate;
  late DateTime? _received = widget.po?.receivedDate;

  bool _busy = false;
  String? _error;

  bool get _readOnly => !widget.canSave;

  @override
  void dispose() {
    for (final c in [_number, _vendor, _total, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final total = double.tryParse(_total.text.replaceAll(RegExp(r'[\$,\s]'), ''));
    if (_vendor.text.trim().isEmpty) {
      setState(() => _error = 'Enter the vendor.');
      return;
    }
    if (total == null || total < 0) {
      setState(() => _error = 'Enter the PO total as a number, like 1250.00.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await widget.onSave({
      'poNumber': _number.text,
      'vendor': _vendor.text,
      'total': total,
      'status': _status,
      'orderDate': _isoDate(_ordered),
      'expectedDate': _expected == null ? '' : _isoDate(_expected!),
      'receivedDate': _status == 'Received' ? _isoDate(_received ?? DateTime.now()) : '',
      'notes': _notes.text,
    });
    if (!mounted) return;
    if (err == null) {
      Navigator.of(context).pop(widget.po == null ? 'PO created.' : 'PO saved.');
    } else {
      setState(() {
        _busy = false;
        _error = err;
      });
    }
  }

  Future<void> _delete() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete this PO?'),
        content: Text('${widget.po!.poNumber} will be removed. This can\'t be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: DashUi.red),
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await widget.onDelete();
    if (!mounted) return;
    if (err == null) {
      Navigator.of(context).pop('PO deleted.');
    } else {
      setState(() {
        _busy = false;
        _error = err;
      });
    }
  }

  Future<DateTime?> _pick(DateTime initial) {
    final now = DateTime.now();
    return showDatePicker(context: context, initialDate: initial, firstDate: DateTime(now.year - 5), lastDate: DateTime(now.year + 5));
  }

  Widget _dateField(String label, DateTime? value, ValueChanged<DateTime?> onPicked, {bool clearable = false}) {
    return InkWell(
      onTap: _readOnly
          ? null
          : () async {
              final d = await _pick(value ?? DateTime.now());
              if (d != null) onPicked(d);
            },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
          suffixIcon: clearable && value != null && !_readOnly
              ? IconButton(tooltip: 'Clear', icon: const Icon(Icons.close_rounded, size: 18), onPressed: () => onPicked(null))
              : const Icon(Icons.calendar_today_rounded, size: 18),
        ),
        child: Text(value == null ? 'Not set' : _niceDate(value)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const gap = SizedBox(height: 14);
    return AlertDialog(
      title: Text(widget.po == null ? 'New purchase order' : (_readOnly ? 'Purchase order' : 'Edit purchase order')),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _number,
                readOnly: _readOnly,
                decoration: InputDecoration(
                  labelText: 'PO number',
                  helperText: widget.po == null ? 'Leave blank to number it automatically' : null,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              gap,
              TextField(
                controller: _vendor,
                readOnly: _readOnly,
                decoration: InputDecoration(
                  labelText: 'Vendor',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixIcon: _readOnly || widget.vendors.isEmpty
                      ? null
                      : PopupMenuButton<String>(
                          tooltip: 'Pick a past vendor',
                          icon: const Icon(Icons.arrow_drop_down_rounded),
                          onSelected: (v) => setState(() => _vendor.text = v),
                          itemBuilder: (_) => [for (final v in widget.vendors) PopupMenuItem(value: v, child: Text(v))],
                        ),
                ),
              ),
              gap,
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _total,
                      readOnly: _readOnly,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Total', prefixText: '\$ ', border: OutlineInputBorder(), isDense: true),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _status,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Status', border: OutlineInputBorder(), isDense: true),
                      items: [for (final s in _statuses) DropdownMenuItem(value: s, child: Text(s))],
                      onChanged: _readOnly ? null : (v) => setState(() => _status = v ?? 'Open'),
                    ),
                  ),
                ],
              ),
              gap,
              Row(
                children: [
                  Expanded(child: _dateField('Ordered', _ordered, (d) => setState(() => _ordered = d ?? _ordered))),
                  const SizedBox(width: 12),
                  Expanded(child: _dateField('Expected', _expected, (d) => setState(() => _expected = d), clearable: true)),
                ],
              ),
              if (_status == 'Received') ...[
                gap,
                _dateField('Received', _received ?? DateTime.now(), (d) => setState(() => _received = d)),
              ],
              gap,
              TextField(
                controller: _notes,
                readOnly: _readOnly,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(labelText: 'Notes', border: OutlineInputBorder(), isDense: true),
              ),
              if (_error != null) ...[
                gap,
                Text(_error!, style: const TextStyle(color: DashUi.red, fontSize: 13.5)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (widget.canDelete) TextButton(onPressed: _busy ? null : _delete, child: const Text('Delete', style: TextStyle(color: DashUi.red))),
        const Spacer(),
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(), child: Text(_readOnly ? 'Close' : 'Cancel')),
        if (!_readOnly)
          FilledButton(
            onPressed: _busy ? null : _save,
            child: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Save'),
          ),
      ],
    );
  }
}
