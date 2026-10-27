import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'config/api_config.dart';
import 'config/auth_session.dart';
import 'utils/job_statuses.dart';
import 'utils/status_colors.dart';
import 'widgets/app_dialog.dart';
import 'widgets/dashboard_kit.dart';
import 'widgets/flat_page.dart';

const _timeout = Duration(seconds: 20);

const _jobCategories = ['Open Jobs', 'Completed Jobs', 'Closed Jobs'];
const _estimateCategories = ['Open Estimates', 'Won Estimates', 'Lost Estimates'];

/// Swatches offered in the editor: the colours Service Fusion statuses already use, plus a hex field for anything else.
const _swatches = <int>[
  0xFFA80000,
  0xFFDB0000,
  0xFFFF0000,
  0xFFFFAE00,
  0xFF08EB00,
  0xFF009E18,
  0xFF00B3FF,
  0xFF0051FF,
  0xFF000AC4,
  0xFF7F83EB,
  0xFFEB36FF,
  0xFF5F0069,
  0xFF592D00,
  0xFF9C9C9C,
  0xFF000000,
];

/// What commission does in a status, from the server's rulebook: a one-liner, whether it pays, and the one number
/// (if any) the office can change here.
class CommissionInfo {
  final String kind; // closing | won | callback | advance | none
  final bool pays;
  final String line;
  final bool live; // false = payroll does not read the amount yet
  final double? amount;
  final String unit;
  final String label;
  const CommissionInfo({
    required this.kind,
    required this.pays,
    required this.line,
    this.live = false,
    this.amount,
    this.unit = r'$',
    this.label = '',
  });

  factory CommissionInfo.fromJson(Map<String, dynamic> j) => CommissionInfo(
    kind: '${j['kind'] ?? 'none'}',
    pays: j['pays'] == true,
    line: '${j['line'] ?? ''}',
    live: j['live'] == true,
    amount: j['amount'] is num ? (j['amount'] as num).toDouble() : null,
    unit: '${j['unit'] ?? r'$'}',
    label: '${j['label'] ?? ''}',
  );
}

class StatusDef {
  final int? id;
  final String kind; // 'job' | 'estimate'
  final String name;
  final Color color;
  final String category;
  final bool active;
  final bool fieldSee; // field workers can see jobs/estimates in this status
  final bool fieldAssign; // field workers can set this status
  final double? commissionAmount; // set from the editor only; the server keeps it in commission_settings
  const StatusDef({
    this.id,
    required this.kind,
    required this.name,
    required this.color,
    required this.category,
    this.active = true,
    this.fieldSee = true,
    this.fieldAssign = true,
    this.commissionAmount,
  });

  factory StatusDef.fromJson(Map<String, dynamic> j) => StatusDef(
    id: j['id'] is int ? j['id'] as int : int.tryParse('${j['id']}'),
    kind: '${j['kind']}',
    name: '${j['name'] ?? ''}',
    color: _parseHex('${j['color']}') ?? kStatusFallback,
    category: '${j['category'] ?? ''}',
    active: j['active'] != false,
    fieldSee: j['fieldSee'] != false,
    fieldAssign: j['fieldAssign'] != false,
  );

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'name': name,
    'color': _hex(color),
    'category': category,
    'active': active,
    'fieldSee': fieldSee,
    'fieldAssign': fieldAssign,
    if (commissionAmount != null) 'commissionAmount': commissionAmount,
  };
}

String _hex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

Color? _parseHex(String s) {
  final t = s.trim().replaceFirst('#', '');
  if (t.length != 6) return null;
  final v = int.tryParse(t, radix: 16);
  return v == null ? null : Color(0xFF000000 | v);
}

/// Job statuses in the order Service Fusion shows them (open work first), same as the server's starting list.
const _jobOrder = [
  'Need Deposit',
  'Need To Order',
  'Manage Project',
  'Need To Schedule',
  'Site Check',
  'Scheduled - Full Day',
  'Scheduled - Half Day',
  'Appointment',
  'Delayed',
  'Need To Sell',
  'Need To Warranty',
  'Warranty Work',
  'Callback',
  'Partially Complete',
  'Part Ordered',
  'Verify Delivery',
  'Complete',
  'Final Invoice Sent',
  '14 Day Notice',
  '30 Day Notice',
  '60 Day Notice',
  '90 Day Notice',
  'Check on Payment',
  'Close Job',
  'Google Review Sent',
  'Paid & Closed',
  'Write-Off',
  'Cancelled',
];

/// What the office uses today, shown (read-only) when the server has no status list yet.
List<StatusDef> builtInStatuses() => [
  for (final n in _jobOrder) StatusDef(kind: 'job', name: n, color: statusColor(n), category: _builtInCategory(n)),
  for (final n in kEstimateStatuses)
    StatusDef(kind: 'estimate', name: n, color: statusColor(n), category: _builtInEstimateCategory(n)),
];

String _builtInCategory(String n) {
  const done = {
    'final invoice sent',
    '14 day notice',
    '30 day notice',
    '60 day notice',
    '90 day notice',
    'check on payment',
    'close job',
    'google review sent',
    'paid & closed',
  };
  const closed = {'write-off', 'cancelled'};
  final t = n.toLowerCase();
  return done.contains(t)
      ? 'Completed Jobs'
      : closed.contains(t)
      ? 'Closed Jobs'
      : 'Open Jobs';
}

String _builtInEstimateCategory(String n) {
  final t = n.toLowerCase();
  if (t.startsWith('lost')) return 'Lost Estimates';
  if (t == 'estimate accepted' || t == 'estimate won') return 'Won Estimates';
  return 'Open Estimates';
}

class StatusesScreen extends StatefulWidget {
  const StatusesScreen({super.key});

  @override
  State<StatusesScreen> createState() => _StatusesScreenState();
}

class _StatusesScreenState extends State<StatusesScreen> {
  List<StatusDef> _all = [];
  Map<String, CommissionInfo> _commission = {}; // lower-cased status name -> what commission does in it
  bool _loading = true;
  bool _readOnly = false; // the server has no status list yet, so we show the built-in one
  String? _error;
  String _kind = 'job';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  List<StatusDef> get _shown => [
    for (final s in _all)
      if (s.kind == _kind) s,
  ];

  Future<http.Response> _send(String method, String path, {Object? body}) async {
    final uri = Uri.parse('$kApiBaseUrl/api$path');
    final h = AuthSession.instance.headers();
    final http.Response res;
    try {
      final req = switch (method) {
        'GET' => http.get(uri, headers: h),
        'POST' => http.post(uri, headers: h, body: jsonEncode(body)),
        'PUT' => http.put(uri, headers: h, body: jsonEncode(body)),
        _ => http.delete(uri, headers: h),
      };
      res = await req.timeout(_timeout);
    } on TimeoutException {
      throw 'The server took too long to answer. Check your connection and try again.';
    } catch (_) {
      throw "Couldn't reach the server. Check your connection and try again.";
    }
    if (res.statusCode == 401) {
      AuthSession.instance.logout();
      throw 'Your session expired. Please sign in again.';
    }
    return res;
  }

  Map<String, dynamic> _json(http.Response r) {
    try {
      final d = jsonDecode(r.body);
      if (d is Map) return Map<String, dynamic>.from(d);
    } catch (_) {}
    return const {};
  }

  String _problem(http.Response r, String fallback) {
    final e = '${_json(r)['error'] ?? ''}'.trim();
    return e.isNotEmpty ? e : '$fallback (${r.statusCode}).';
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await _send('GET', '/statuses');
      if (!mounted) return;
      if (r.statusCode == 404) {
        setState(() {
          _all = builtInStatuses();
          _readOnly = true;
          _loading = false;
        });
        return;
      }
      final d = _json(r);
      if (r.statusCode != 200 || d['success'] != true) throw _problem(r, 'The server had a problem');
      setState(() {
        _all = [
          for (final s in (d['statuses'] as List? ?? const [])) StatusDef.fromJson(Map<String, dynamic>.from(s as Map)),
        ];
        _commission = {
          for (final e in (d['commissionByName'] as Map? ?? const {}).entries)
            '${e.key}': CommissionInfo.fromJson(Map<String, dynamic>.from(e.value as Map)),
        };
        _readOnly = false;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _toast(String msg, {bool error = false}) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(msg), backgroundColor: error ? const Color(0xFFB91C1C) : DashUi.ink));
  }

  /// Runs a save/delete call; shows the server's message when it fails. Returns whether it worked.
  Future<bool> _run(Future<http.Response> Function() call, String failMsg) async {
    setState(() => _busy = true);
    try {
      final r = await call();
      final d = _json(r);
      if (r.statusCode >= 300 || d['success'] != true) {
        if (mounted) _toast(_problem(r, failMsg), error: true);
        return false;
      }
      return true;
    } catch (e) {
      if (mounted) _toast('$e', error: true);
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit([StatusDef? existing]) async {
    final result = await showDialog<StatusDef>(
      context: context,
      builder: (_) => _StatusEditor(
        kind: _kind,
        existing: existing,
        commission: _commission,
        taken: [
          for (final s in _shown)
            if (s.id != existing?.id) s.name.toLowerCase(),
        ],
      ),
    );
    if (result == null || !mounted) return;
    final ok = await _run(
      () => existing == null
          ? _send('POST', '/statuses', body: result.toJson())
          : _send('PUT', '/statuses/${existing.id}', body: result.toJson()),
      'Could not save the status',
    );
    if (ok) {
      await _load();
      if (mounted) _toast(existing == null ? 'Added "${result.name}".' : 'Saved "${result.name}".');
    }
  }

  Future<void> _delete(StatusDef s) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppDialog(
        title: 'Delete "${s.name}"?',
        icon: Icons.delete_outline_rounded,
        iconColor: const Color(0xFFB91C1C),
        body: const Text(
          'It leaves this list only. Jobs and estimates already using this status keep it, and nothing changes in Service Fusion.',
          style: TextStyle(fontSize: 14, color: DashUi.slate, height: 1.4),
        ),
        actions: [
          AppButton.ghost('Cancel', () => Navigator.pop(ctx, false)),
          AppButton.ink('Delete', () => Navigator.pop(ctx, true), danger: true),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    final ok = await _run(() => _send('DELETE', '/statuses/${s.id}'), 'Could not delete the status');
    if (ok) {
      await _load();
      if (mounted) _toast('Deleted "${s.name}".');
    }
  }

  Future<void> _reorder(int oldIndex, int newIndex) async {
    final list = _shown;
    final moved = list.removeAt(oldIndex);
    list.insert(newIndex, moved);
    final before = _all;
    setState(
      () => _all = [
        for (final s in _all)
          if (s.kind != _kind) s,
        ...list,
      ],
    );
    final ok = await _run(
      () => _send(
        'PUT',
        '/statuses-order',
        body: {
          'kind': _kind,
          'ids': [for (final s in list) s.id],
        },
      ),
      'Could not save the order',
    );
    if (!ok && mounted) setState(() => _all = before);
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = !_readOnly && !_loading && _error == null;
    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageBanner(
            title: 'Estimate & Job Statuses',
            actions: [
              PageBanner.refresh(onPressed: _loading ? null : _load),
              PageBanner.button(
                icon: Icons.add_rounded,
                label: _kind == 'job' ? 'Add job status' : 'Add estimate status',
                onPressed: canEdit && !_busy ? () => _edit() : null,
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                width: 340,
                child: AppSegmented<String>(
                  value: _kind,
                  options: const [('job', 'Job Statuses'), ('estimate', 'Estimate Statuses')],
                  onChanged: (v) => setState(() => _kind = v),
                ),
              ),
            ),
          ),
          if (_readOnly)
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: AppNotice(
                'Showing the statuses we use today. Adding, editing and deleting turns on once the latest server update is live.',
                kind: AppNoticeKind.warning,
              ),
            ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return SkeletonPulse(
        child: Column(
          children: [
            for (var i = 0; i < 6; i++)
              Container(
                margin: const EdgeInsets.fromLTRB(24, 0, 24, 10),
                height: 52,
                decoration: BoxDecoration(color: DashUi.faint, borderRadius: BorderRadius.circular(8)),
              ),
          ],
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: SingleChildScrollView(
          child: DashErrorPanel(title: "Couldn't load statuses", message: _error!, onRetry: _load),
        ),
      );
    }
    final list = _shown;
    if (list.isEmpty) {
      return FlatEmpty(
        icon: Icons.timeline_rounded,
        title: _kind == 'job' ? 'No job statuses yet' : 'No estimate statuses yet',
        message: _readOnly ? 'Nothing to show.' : 'Use the add button above to create the first one.',
      );
    }
    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= 760;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(wide),
            Expanded(
              child: ReorderableListView.builder(
                buildDefaultDragHandles: false,
                padding: const EdgeInsets.only(bottom: 24),
                itemCount: list.length,
                onReorderItem: _readOnly || _busy ? (_, _) {} : _reorder,
                itemBuilder: (context, i) => _row(list[i], i, wide),
              ),
            ),
          ],
        );
      },
    );
  }

  static const _hdr = TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: DashUi.ink);

  Widget _header(bool wide) => Container(
    color: DashUi.faint,
    padding: const EdgeInsets.fromLTRB(24, 10, 24, 10),
    child: Row(
      children: [
        const SizedBox(width: 32),
        const Expanded(flex: 4, child: Text('Name', style: _hdr)),
        if (wide) const Expanded(flex: 3, child: Text('Color', style: _hdr)),
        if (wide) const Expanded(flex: 3, child: Text('Category', style: _hdr)),
        const SizedBox(width: 90, child: Text('Status', style: _hdr)),
        const SizedBox(width: 96),
      ],
    ),
  );

  Widget _row(StatusDef s, int i, bool wide) {
    final off = !s.active;
    final muted = off ? DashUi.muted : DashUi.ink;
    return Container(
      key: ValueKey('${s.kind}-${s.id ?? s.name}'),
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Container(
        constraints: const BoxConstraints(minHeight: 52),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: DashUi.line)),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 32,
              child: _readOnly
                  ? null
                  : ReorderableDragStartListener(
                      index: i,
                      child: const MouseRegion(
                        cursor: SystemMouseCursors.grab,
                        child: Icon(Icons.drag_indicator_rounded, size: 20, color: DashUi.muted),
                      ),
                    ),
            ),
            Expanded(
              flex: 4,
              child: Row(
                children: [
                  if (!wide) ...[
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(color: s.color, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Flexible(
                    child: Text(
                      s.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: muted),
                    ),
                  ),
                ],
              ),
            ),
            if (wide)
              Expanded(
                flex: 3,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Semantics(
                    label: 'Color ${_hex(s.color)}',
                    child: Container(
                      width: 140,
                      height: 12,
                      decoration: BoxDecoration(
                        color: s.color.withValues(alpha: off ? 0.4 : 1),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),
            if (wide)
              Expanded(
                flex: 3,
                child: Text(s.category, style: TextStyle(fontSize: 14.5, color: off ? DashUi.muted : DashUi.slate)),
              ),
            SizedBox(
              width: 90,
              child: Text(
                s.active ? 'Active' : 'Inactive',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: s.active ? DashUi.emeraldDeep : DashUi.muted,
                ),
              ),
            ),
            SizedBox(
              width: 96,
              child: _readOnly
                  ? null
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        IconButton(
                          tooltip: 'Edit ${s.name}',
                          iconSize: 18,
                          color: DashUi.slate,
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: _busy ? null : () => _edit(s),
                        ),
                        IconButton(
                          tooltip: 'Delete ${s.name}',
                          iconSize: 18,
                          color: DashUi.slate,
                          icon: const Icon(Icons.close_rounded),
                          onPressed: _busy ? null : () => _delete(s),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusEditor extends StatefulWidget {
  final String kind;
  final StatusDef? existing;
  final List<String> taken; // lower-cased names already in this list
  final Map<String, CommissionInfo> commission;
  const _StatusEditor({required this.kind, required this.existing, required this.taken, required this.commission});

  @override
  State<_StatusEditor> createState() => _StatusEditorState();
}

class _StatusEditorState extends State<_StatusEditor> {
  late final TextEditingController _name = TextEditingController(text: widget.existing?.name ?? '');
  late Color _color = widget.existing?.color ?? const Color(0xFF009E18);
  late final TextEditingController _hexCtl = TextEditingController(text: _hex(_color));
  late String _category = widget.existing?.category ?? _cats.first;
  late bool _active = widget.existing?.active ?? true;
  late bool _fieldSee = widget.existing?.fieldSee ?? true;
  late bool _fieldAssign = widget.existing?.fieldAssign ?? true;
  String? _nameError;
  String? _amountError;
  late final TextEditingController _amountCtl = TextEditingController(text: _fmtAmount(_info?.amount));
  late String _amountKind = _info?.amount == null ? '' : _info!.kind;

  static String _fmtAmount(double? v) => v == null ? '' : (v == v.roundToDouble() ? v.toStringAsFixed(0) : '$v');

  /// The commission rule for the name in the box (live as it is typed).
  CommissionInfo? get _info {
    if (widget.commission.isEmpty) return null; // server too old to say
    return widget.commission[_name.text.trim().toLowerCase()] ??
        const CommissionInfo(
          kind: 'none',
          pays: false,
          line: 'Not a commission status. It does not trigger or change any pay.',
        );
  }

  /// When the typed name switches to a status with a different number, show that number's current value.
  void _syncAmount() {
    final i = _info;
    final kind = i?.amount == null ? '' : i!.kind;
    if (kind != _amountKind) {
      _amountKind = kind;
      _amountCtl.text = _fmtAmount(i?.amount);
    }
  }

  List<String> get _cats => widget.kind == 'job' ? _jobCategories : _estimateCategories;
  String get _noun => widget.kind == 'job' ? 'job' : 'estimate';

  @override
  void dispose() {
    _name.dispose();
    _hexCtl.dispose();
    _amountCtl.dispose();
    super.dispose();
  }

  void _setColor(Color c) {
    setState(() => _color = c);
    _hexCtl.text = _hex(c);
  }

  void _save() {
    final name = _name.text.trim();
    if (_info?.amount != null && double.tryParse(_amountCtl.text.trim()) == null) {
      return setState(() => _amountError = 'Enter an amount, like 50.');
    }
    if (name.isEmpty) return setState(() => _nameError = 'Give the status a name.');
    if (widget.taken.contains(name.toLowerCase())) {
      return setState(() => _nameError = 'There is already a status with that name.');
    }
    Navigator.pop(
      context,
      StatusDef(
        id: widget.existing?.id,
        kind: widget.kind,
        name: name,
        color: _color,
        category: _category,
        active: _active,
        fieldSee: _fieldSee,
        fieldAssign: _fieldAssign,
        commissionAmount: _info?.amount == null ? null : double.tryParse(_amountCtl.text.trim()),
      ),
    );
  }

  Widget _label(String t) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(t, style: const TextStyle(fontSize: 14, color: DashUi.ink)),
  );

  Widget _toggle(String label, bool value, ValueChanged<bool> onChanged) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: Row(
      children: [
        Expanded(
          child: Text(label, style: const TextStyle(fontSize: 14, color: DashUi.ink)),
        ),
        Semantics(
          label: label,
          child: Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: Colors.white,
            activeTrackColor: DashUi.emeraldDeep,
          ),
        ),
      ],
    ),
  );

  Widget _left() {
    final preview = _name.text.trim().isEmpty ? 'Status name' : _name.text.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label('Status Category'),
        DropdownButtonFormField<String>(
          initialValue: _category,
          decoration: appFieldDecoration(),
          items: [for (final c in _cats) DropdownMenuItem(value: c, child: Text(c))],
          onChanged: (v) => setState(() => _category = v ?? _category),
        ),
        const SizedBox(height: 18),
        _label('Name'),
        TextField(
          controller: _name,
          autofocus: true,
          maxLength: 80,
          textInputAction: TextInputAction.done,
          onChanged: (_) => setState(() {
            _nameError = null;
            _syncAmount();
          }),
          onSubmitted: (_) => _save(),
          decoration: appFieldDecoration(hint: 'e.g. Need Deposit', error: _nameError).copyWith(counterText: ''),
        ),
        const SizedBox(height: 18),
        _label('Background Color'),
        Row(
          children: [
            SizedBox(
              width: 120,
              child: TextField(
                controller: _hexCtl,
                maxLength: 7,
                onChanged: (t) {
                  final c = _parseHex(t);
                  if (c != null) setState(() => _color = c);
                },
                decoration: appFieldDecoration(hint: '#a80000').copyWith(counterText: ''),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Container(
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: _color, borderRadius: BorderRadius.circular(12)),
                child: Text(
                  preview,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: _color.computeLuminance() > 0.55 ? DashUi.ink : Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final v in _swatches)
              Semantics(
                button: true,
                selected: _color.toARGB32() == v,
                label: 'Color ${_hex(Color(v))}',
                child: InkWell(
                  onTap: () => _setColor(Color(v)),
                  customBorder: const CircleBorder(),
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: Color(v),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _color.toARGB32() == v ? DashUi.ink : DashUi.line,
                        width: _color.toARGB32() == v ? 2.5 : 1,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  /// Badge, one line, and the one number commission uses in this status.
  Widget _commissionBox() {
    final i = _info;
    if (i == null) return const SizedBox.shrink();
    final green = DashUi.emeraldDeep;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 22),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: DashUi.faint,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: DashUi.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'Commission',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: DashUi.ink),
              ),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: i.pays ? green : Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: i.pays ? null : Border.all(color: DashUi.line),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      i.pays ? Icons.paid_rounded : Icons.block_rounded,
                      size: 14,
                      color: i.pays ? Colors.white : DashUi.slate,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      i.pays ? 'Commission paying status' : 'Not a commission status',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: i.pays ? Colors.white : DashUi.slate,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(i.line, style: const TextStyle(fontSize: 13.5, height: 1.4, color: DashUi.ink)),
          if (i.amount != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(i.label, style: const TextStyle(fontSize: 14, color: DashUi.ink)),
                ),
                SizedBox(
                  width: 130,
                  child: TextField(
                    controller: _amountCtl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                    textAlign: TextAlign.right,
                    onChanged: (_) => setState(() => _amountError = null),
                    decoration: appFieldDecoration(error: _amountError, prefixText: i.unit == r'$' ? r'$ ' : null),
                  ),
                ),
              ],
            ),
            if (!i.live) ...[
              const SizedBox(height: 10),
              const AppNotice(
                'Saved here, but payroll still pays the old amount until the payroll connection is switched on.',
                kind: AppNoticeKind.warning,
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _right() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _toggle('Is Active', _active, (v) => setState(() => _active = v)),
      _toggle('Field workers can see ${_noun}s in this status', _fieldSee, (v) => setState(() => _fieldSee = v)),
      _toggle('Field workers can assign this status', _fieldAssign, (v) => setState(() => _fieldAssign = v)),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final isNew = widget.existing == null;
    return Dialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: DashUi.line),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              color: DashUi.faint,
              padding: const EdgeInsets.fromLTRB(24, 6, 8, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        '${isNew ? 'Add' : 'Edit'} ${widget.kind == 'job' ? 'Job' : 'Estimate'} status',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: DashUi.ink),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close_rounded, size: 20),
                    color: DashUi.slate,
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(32, 24, 32, 8),
                child: LayoutBuilder(
                  builder: (context, c) {
                    if (c.maxWidth < 600) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [_left(), const SizedBox(height: 20), _right(), _commissionBox()],
                      );
                    }
                    return Column(
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(flex: 5, child: _left()),
                            Container(
                              width: 1,
                              height: 260,
                              margin: const EdgeInsets.symmetric(horizontal: 32),
                              color: DashUi.line,
                            ),
                            Expanded(
                              flex: 4,
                              child: Padding(padding: const EdgeInsets.only(top: 4), child: _right()),
                            ),
                          ],
                        ),
                        _commissionBox(),
                      ],
                    );
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  AppButton.ghost('Cancel', () => Navigator.pop(context)),
                  AppButton.ink(isNew ? 'Add status' : 'Save', _save),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
