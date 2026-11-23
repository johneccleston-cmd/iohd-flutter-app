import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import '../config/access.dart';
import '../config/api_config.dart';
import '../config/auth_session.dart';
import 'app_dialog.dart';
import 'dashboard_data.dart';
import 'dashboard_kit.dart';

// The Financial dashboard's "Company pool" figure, opened: every entry that moved the pool (the 1% from each job,
// callback charges taken from it, and entries made by hand) with a form to add one by hand.
//
//   GET  /api/retainage/company-pool          { balance, pending, moneyIn, moneyOut, entries: [...] }
//   POST /api/retainage/company-pool/entries  { direction: 'in' | 'out', amount, note, jobId?, date? }
//
// Both need the Payroll switch (View to read, Create to add). Manual entries are saved to our own database only.

/// Opens the log. Resolves to true when an entry was added, so the dashboard can reload its figure.
Future<bool> showCompanyPoolDialog(BuildContext context) async {
  final changed = await showDialog<bool>(
    context: context,
    builder: (_) => const CompanyPoolDialog(),
  );
  return changed == true;
}

double _d(dynamic v) => v == null ? 0.0 : (v is num ? v.toDouble() : double.tryParse(v.toString()) ?? 0.0);

enum PoolEntryKind { deposit, callback, manual }

class PoolEntry {
  final int? id;
  final PoolEntryKind kind;
  final double amount;
  final String? jobId;
  final String? customer;
  final DateTime? date;
  final String note;
  final String createdBy;

  /// False while the job's pay week has no finalized payroll run: the row is in the log but not in the balance yet.
  final bool counted;

  /// A manual entry dated ahead (a later week of a spread payment): it counts from its date.
  final bool scheduled;

  /// Which week of a spread payment this is ("week 2 of 4"); null for a one-off.
  final int? planPart;
  final int? planParts;

  /// What a manual entry was for ("Damage to customer property"); null for job rows.
  final String? categoryLabel;

  const PoolEntry({
    this.categoryLabel,
    this.scheduled = false,
    this.planPart,
    this.planParts,
    required this.id,
    required this.kind,
    required this.amount,
    required this.jobId,
    required this.customer,
    required this.date,
    required this.note,
    required this.createdBy,
    required this.counted,
  });

  factory PoolEntry.fromJson(Map<String, dynamic> j) {
    final job = j['jobId']?.toString().trim();
    final plan = j['plan'] is Map ? j['plan'] as Map : null;
    int? n(dynamic v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');
    final category = (j['categoryLabel'] as String?)?.trim();
    return PoolEntry(
      categoryLabel: category == null || category.isEmpty ? null : category,
      scheduled: j['scheduled'] == true,
      planPart: n(plan?['part']),
      planParts: n(plan?['parts']),
      id: j['id'] is num ? (j['id'] as num).toInt() : int.tryParse('${j['id']}'),
      kind: switch (j['kind']) {
        'manual' => PoolEntryKind.manual,
        'callback' => PoolEntryKind.callback,
        _ => PoolEntryKind.deposit,
      },
      amount: _d(j['amount']),
      jobId: job == null || job.isEmpty ? null : job,
      customer: (j['customer'] as String?)?.trim(),
      date: DateTime.tryParse('${j['date'] ?? ''}'),
      note: (j['note'] ?? '').toString().trim(),
      createdBy: (j['createdBy'] ?? '').toString().trim(),
      counted: j['counted'] == true,
    );
  }

  String get kindLabel => switch (kind) {
        PoolEntryKind.deposit => 'From job',
        PoolEntryKind.callback => 'Callback charge',
        PoolEntryKind.manual => amount < 0 ? 'Paid out' : 'Added',
      };
}

class CompanyPoolLog {
  final double balance;
  final double pending;

  /// The weeks still ahead of spread payments (negative when they pay out).
  final double scheduled;
  final double moneyIn;
  final double moneyOut;
  final List<PoolEntry> entries;
  const CompanyPoolLog({
    required this.balance,
    required this.pending,
    this.scheduled = 0,
    required this.moneyIn,
    required this.moneyOut,
    required this.entries,
  });

  factory CompanyPoolLog.fromJson(Map<String, dynamic> j) => CompanyPoolLog(
        balance: _d(j['balance']),
        pending: _d(j['pending']),
        scheduled: _d(j['scheduled']),
        moneyIn: _d(j['moneyIn']),
        moneyOut: _d(j['moneyOut']),
        entries: [
          for (final e in (j['entries'] as List<dynamic>? ?? const [])) PoolEntry.fromJson(e as Map<String, dynamic>),
        ],
      );
}

enum _Filter { all, moneyIn, moneyOut, manual }

class CompanyPoolDialog extends StatefulWidget {
  const CompanyPoolDialog({super.key});

  @override
  State<CompanyPoolDialog> createState() => _CompanyPoolDialogState();
}

class _CompanyPoolDialogState extends State<CompanyPoolDialog> {
  static final _dateFmt = DateFormat('MMM d, yyyy');

  final _requests = DashRequests();
  bool _loading = true;
  DashLoadException? _error;
  CompanyPoolLog? _log;
  String _query = '';
  _Filter _filter = _Filter.all;
  bool _changed = false;

  bool get _canAdd => AuthSession.instance.can('company_pool', AccessAction.create);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _requests.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _log == null;
      _error = null;
    });
    try {
      final payload = await _requests.get('/api/retainage/company-pool');
      if (payload == null || !mounted) return;
      final CompanyPoolLog log;
      try {
        log = CompanyPoolLog.fromJson(payload.body);
      } catch (_) {
        throw const DashLoadException(DashFailure.badData);
      }
      setState(() {
        _log = log;
        _loading = false;
      });
    } on DashLoadException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  void _close() => Navigator.of(context).pop(_changed);

  Future<void> _add() async {
    final saved = await showDialog<PoolEntrySaved>(context: context, builder: (_) => const CompanyPoolEntryForm());
    if (saved == null || !mounted) return;
    _changed = true;
    final money = dashMoney(saved.amount.abs());
    final over = saved.weeks > 1 ? ', spread over ${saved.weeks} weeks' : '';
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(saved.amount < 0
            ? '$money paid out of the company pool$over.'
            : '$money added to the company pool$over.'),
      ),
    );
    await _load();
  }

  List<PoolEntry> get _visible {
    final all = _log?.entries ?? const <PoolEntry>[];
    final q = _query.trim().toLowerCase().replaceFirst('#', '');
    return all.where((e) {
      final keep = switch (_filter) {
        _Filter.all => true,
        _Filter.moneyIn => e.amount > 0,
        _Filter.moneyOut => e.amount < 0,
        _Filter.manual => e.kind == PoolEntryKind.manual,
      };
      if (!keep) return false;
      if (q.isEmpty) return true;
      return (e.jobId ?? '').contains(q) ||
          (e.customer ?? '').toLowerCase().contains(q) ||
          e.note.toLowerCase().contains(q) ||
          e.createdBy.toLowerCase().contains(q) ||
          (e.categoryLabel ?? '').toLowerCase().contains(q) ||
          e.kindLabel.toLowerCase().contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final height = math.min(MediaQuery.sizeOf(context).height * 0.86, 780.0);
    final log = _log;
    final narrow = MediaQuery.sizeOf(context).width < 720;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Dialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 12,
        shadowColor: Colors.black.withValues(alpha: 0.18),
        insetPadding: const EdgeInsets.all(24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: const BorderSide(color: DashUi.line)),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 860, maxHeight: height),
          child: SizedBox(
            width: 860,
            height: height,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _header(log),
                  const SizedBox(height: 16),
                  if (log != null) ...[
                    _summary(log, narrow),
                    const SizedBox(height: 14),
                    _filters(log, narrow),
                    const SizedBox(height: 12),
                  ],
                  Expanded(child: _body()),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(CompanyPoolLog? log) {
    return Row(
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(color: DashUi.indigo.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(11)),
          child: const Icon(Icons.savings_outlined, size: 20, color: DashUi.indigo),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Company pool',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: DashUi.ink, letterSpacing: -0.3),
              ),
              const SizedBox(height: 3),
              Text(
                log == null
                    ? 'Every entry in and out of the pool'
                    : 'All time · ${log.entries.length} ${log.entries.length == 1 ? 'entry' : 'entries'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, color: DashUi.slate),
              ),
            ],
          ),
        ),
        if (_canAdd && log != null) ...[
          const SizedBox(width: 12),
          AppButton.ink('New transaction', _add, icon: Icons.add_rounded),
        ],
        const SizedBox(width: 4),
        IconButton(
          tooltip: 'Close',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.close_rounded, size: 19, color: DashUi.muted),
          onPressed: _close,
        ),
      ],
    );
  }

  /// The four figures, each with a label and a caption.
  Widget _summary(CompanyPoolLog log, bool narrow) {
    final tiles = [
      PoolSummaryTile(
        label: 'Balance',
        value: log.balance,
        caption: 'Same as the dashboard',
        color: log.balance < 0 ? DashUi.redText : DashUi.indigo,
      ),
      PoolSummaryTile(label: 'Money in', value: log.moneyIn, caption: 'Jobs and additions', color: DashUi.emeraldText),
      PoolSummaryTile(label: 'Money out', value: log.moneyOut, caption: 'Charges and payouts', color: DashUi.redText),
      PoolSummaryTile(
        label: 'Waiting for payroll',
        value: log.pending,
        caption: 'Until payroll is run',
        color: DashUi.amberText,
      ),
      if (log.scheduled != 0)
        PoolSummaryTile(
          label: 'Scheduled',
          value: log.scheduled,
          caption: 'Weeks still to come',
          color: DashUi.slate,
        ),
    ];
    if (narrow) {
      return Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [for (final t in tiles) SizedBox(width: 180, child: t)],
      );
    }
    return Row(
      children: [
        for (var i = 0; i < tiles.length; i++) ...[
          if (i > 0) const SizedBox(width: 10),
          Expanded(child: tiles[i]),
        ],
      ],
    );
  }

  Widget _filters(CompanyPoolLog log, bool narrow) {
    int count(bool Function(PoolEntry) f) => log.entries.where(f).length;
    final pills = AppSegmented<_Filter>(
      value: _filter,
      options: [
        (_Filter.all, 'All (${log.entries.length})'),
        (_Filter.moneyIn, 'In (${count((e) => e.amount > 0)})'),
        (_Filter.moneyOut, 'Out (${count((e) => e.amount < 0)})'),
        (_Filter.manual, 'By hand (${count((e) => e.kind == PoolEntryKind.manual)})'),
      ],
      onChanged: (v) => setState(() => _filter = v),
    );
    final search = TextField(
      onChanged: (v) => setState(() => _query = v),
      decoration: appFieldDecoration(hint: 'Search job #, customer, category or note').copyWith(
        prefixIcon: const Icon(Icons.search_rounded, size: 18, color: DashUi.muted),
      ),
    );
    if (narrow) return Column(children: [search, const SizedBox(height: 10), pills]);
    return Row(
      children: [
        Expanded(child: search),
        const SizedBox(width: 12),
        SizedBox(width: 400, child: pills),
      ],
    );
  }

  Widget _body() {
    if (_loading) {
      return SkeletonPulse(
        child: Column(
          children: [
            const SkeletonBox(h: 64, r: 12),
            const SizedBox(height: 14),
            for (var i = 0; i < 6; i++) ...const [SkeletonBox(h: 54, r: 12), SizedBox(height: 8)],
          ],
        ),
      );
    }
    final error = _error;
    if (error != null && _log == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppNotice('${error.title('the company pool')}. ${error.message}', kind: AppNoticeKind.error),
            if (error.canRetry) ...[
              const SizedBox(height: 12),
              AppButton.ink('Try again', _load, icon: Icons.refresh_rounded),
            ],
          ],
        ),
      );
    }
    final visible = _visible;
    if (visible.isEmpty) {
      final none = (_log?.entries ?? const []).isEmpty;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              none ? 'Nothing has gone in or out of the company pool yet.' : 'Nothing matches that filter.',
              style: const TextStyle(fontSize: 14, color: DashUi.muted),
            ),
            if (none && _canAdd) ...[
              const SizedBox(height: 12),
              AppButton.ink('New transaction', _add, icon: Icons.add_rounded),
            ],
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (error != null) ...[
          AppNotice('Could not refresh the log. ${error.message}', kind: AppNoticeKind.warning),
          const SizedBox(height: 8),
        ],
        Expanded(
          child: ListView.separated(
            itemCount: visible.length,
            separatorBuilder: (_, _) => const SizedBox(height: 6),
            itemBuilder: (context, i) => _row(visible[i]),
          ),
        ),
      ],
    );
  }

  void _openJob(String jobId) {
    final router = GoRouter.of(context);
    Navigator.of(context).pop(_changed);
    router.go('/jobs/${Uri.encodeComponent(jobId)}');
  }

  Widget _row(PoolEntry e) {
    final out = e.amount < 0;
    final (IconData icon, Color tone) = switch (e.kind) {
      PoolEntryKind.deposit => (Icons.south_west_rounded, DashUi.emeraldDeep),
      PoolEntryKind.callback => (Icons.replay_rounded, DashUi.red),
      PoolEntryKind.manual => (Icons.edit_note_rounded, out ? DashUi.red : DashUi.emeraldDeep),
    };
    final title = e.kind == PoolEntryKind.manual
        ? (e.note.isEmpty ? e.kindLabel : e.note)
        : [if (e.jobId != null) 'Job #${e.jobId}', if ((e.customer ?? '').isNotEmpty) e.customer!].join(' · ');
    final meta = [
      e.kindLabel,
      if (e.categoryLabel != null) e.categoryLabel!,
      if (e.planPart != null && e.planParts != null) 'Week ${e.planPart} of ${e.planParts}',
      if (e.date != null) _dateFmt.format(e.date!),
      if (e.kind == PoolEntryKind.manual && e.jobId != null) 'Job #${e.jobId}',
      if (e.createdBy.isNotEmpty) 'by ${e.createdBy}',
    ].join(' · ');

    final row = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F8F8),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: DashUi.line),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(color: tone.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(9)),
            child: Icon(icon, size: 17, color: tone),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title.isEmpty ? e.kindLabel : title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: DashUi.ink),
                ),
                const SizedBox(height: 3),
                Text(
                  meta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: DashUi.subtle, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (e.scheduled) ...[
            Tooltip(
              message: 'Not in the balance yet: it counts from ${e.date == null ? 'its date' : _dateFmt.format(e.date!)}.',
              child: const AppTag('Scheduled', color: DashUi.slate),
            ),
            const SizedBox(width: 10),
          ] else if (!e.counted) ...[
            const Tooltip(
              message: "Not in the balance yet: it counts once payroll is run for the week this job closed in.",
              child: AppTag('Waiting for payroll', color: DashUi.amberText),
            ),
            const SizedBox(width: 10),
          ],
          SizedBox(
            width: 104,
            child: Text(
              '${out ? '' : '+'}${dashMoney(e.amount)}',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: out ? DashUi.redText : DashUi.emeraldText,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );

    final semantics = '$title, ${e.kindLabel}${e.categoryLabel == null ? '' : ', ${e.categoryLabel}'}, ${out ? 'out' : 'in'} ${dashMoney(e.amount.abs())}'
        '${e.planPart != null && e.planParts != null ? ', week ${e.planPart} of ${e.planParts}' : ''}'
        '${e.date == null ? '' : ', ${_dateFmt.format(e.date!)}'}'
        '${e.scheduled ? ', scheduled' : e.counted ? '' : ', waiting for payroll'}';
    final jobId = e.jobId;
    if (jobId == null) return Semantics(label: semantics, child: ExcludeSemantics(child: row));
    return Semantics(
      button: true,
      label: '$semantics. Opens the job.',
      child: ExcludeSemantics(
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            mouseCursor: SystemMouseCursors.click,
            onTap: () => _openJob(jobId),
            child: row,
          ),
        ),
      ),
    );
  }
}

/// One labelled figure with a caption, used at the top of the pool logs.
class PoolSummaryTile extends StatelessWidget {
  final String label;
  final double value;
  final String caption;
  final Color color;
  const PoolSummaryTile({super.key, required this.label, required this.value, required this.caption, required this.color});

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      container: true,
      label: '$label: ${dashMoney(value)}, $caption',
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: DashUi.line)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: DashUi.slate)),
              const SizedBox(height: 2),
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: value),
                duration: reduce ? Duration.zero : const Duration(milliseconds: 900),
                curve: Curves.easeOutCubic,
                builder: (context, v, _) => FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    dashMoney(v),
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: color,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
              Text(caption, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11.5, color: DashUi.subtle, fontWeight: FontWeight.w500)),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// NEW TRANSACTION
// =============================================================================

/// What the form saved: the whole signed amount (negative for money out) and how many weeks it was spread over.
class PoolEntrySaved {
  final double amount;
  final int weeks;
  const PoolEntrySaved(this.amount, this.weeks);
}

/// [total] dollars split by [percents] into cents, the way the server does it: each week rounded down to the cent and
/// the last week takes what is left, so the weeks always add up to the total.
List<double> poolSplitByPercent(double total, List<double> percents) {
  final cents = (total * 100).round();
  final parts = [for (final p in percents) (cents * p / 100 + 1e-9).floor()];
  parts[parts.length - 1] = cents - parts.take(parts.length - 1).fold<int>(0, (s, c) => s + c);
  return [for (final c in parts) c / 100];
}

/// [weeks] even percents to four decimals that add up to exactly 100 (the last week takes the rest): 3 -> 33.3333,
/// 33.3333, 33.3334. Four, not two: 33.33% of $1,000 is $333.30, so two decimals would not split evenly to the cent.
List<double> poolEvenPercents(int weeks) {
  final base = 1000000 ~/ weeks;
  return [for (var i = 0; i < weeks; i++) (i == weeks - 1 ? 1000000 - base * (weeks - 1) : base) / 10000];
}

String _pct(double v) {
  final s = v.toStringAsFixed(4);
  return s.contains('.') ? s.replaceFirst(RegExp(r'\.?0+$'), '') : s;
}

/// The categories a manual entry can have (the same keys as CATEGORIES in the backend's companyPool.js). Money out
/// offers the 'out' ones, money in the 'in' ones; 'both' fits either.
const kPoolCategories = <({String key, String label, String dir})>[
  (key: 'property_damage', label: 'Damage to customer property', dir: 'out'),
  (key: 'warranty', label: 'Warranty repair or part', dir: 'out'),
  (key: 'callback', label: 'Callback cost', dir: 'out'),
  (key: 'tools_equipment', label: 'Tools or equipment', dir: 'out'),
  (key: 'top_up', label: 'Company top-up', dir: 'in'),
  (key: 'recovered', label: 'Money recovered', dir: 'in'),
  (key: 'correction', label: 'Correction', dir: 'both'),
  (key: 'other', label: 'Other', dir: 'both'),
];

List<({String key, String label, String dir})> poolCategoriesFor({required bool moneyIn}) =>
    kPoolCategories.where((c) => c.dir == 'both' || c.dir == (moneyIn ? 'in' : 'out')).toList();

/// The add-an-entry form. Pops with a [PoolEntrySaved], or null when cancelled.
class CompanyPoolEntryForm extends StatefulWidget {
  /// Injected by tests; the real call otherwise.
  final Future<http.Response> Function(Uri uri, Map<String, String> headers, String body)? post;
  const CompanyPoolEntryForm({super.key, this.post});

  @override
  State<CompanyPoolEntryForm> createState() => _CompanyPoolEntryFormState();
}

class _CompanyPoolEntryFormState extends State<CompanyPoolEntryForm> {
  static final _dateFmt = DateFormat('EEE, MMM d, yyyy');
  static final _weekFmt = DateFormat('EEE, MMM d');
  static const _maxWeeks = 52;

  bool _moneyIn = false;
  String? _category;
  final _amount = TextEditingController();
  final _note = TextEditingController();
  final _job = TextEditingController();
  DateTime _date = _today();
  bool _saving = false;
  bool _tried = false;
  String? _serverError;

  /// Spread over weeks: one percent field per week, starting on [_date] and a week apart.
  bool _spread = false;
  List<TextEditingController> _percents = [];

  static DateTime _today() {
    final n = DashClock.now();
    return DateTime(n.year, n.month, n.day);
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    _job.dispose();
    for (final c in _percents) {
      c.dispose();
    }
    super.dispose();
  }

  /// Sets the number of weeks and splits the payment evenly across them.
  void _setWeeks(int weeks) {
    final old = _percents;
    _percents = [for (final p in poolEvenPercents(weeks)) TextEditingController(text: _pct(p))];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final c in old) {
        c.dispose();
      }
    });
  }

  void _toggleSpread(bool spread) {
    setState(() {
      _spread = spread;
      if (spread && _percents.isEmpty) _setWeeks(4);
    });
  }

  DateTime _weekDate(int i) => DateTime(_date.year, _date.month, _date.day + 7 * i);

  double? get _amountValue {
    final v = double.tryParse(_amount.text.replaceAll(RegExp(r'[,\s$]'), ''));
    return v == null || !v.isFinite ? null : v;
  }

  String? get _amountError {
    final v = _amountValue;
    if (v == null) return 'Enter an amount.';
    if (v <= 0) return 'Enter an amount above zero.';
    if (v > 1000000) return 'That amount is too large.';
    return null;
  }

  String? get _noteError => _note.text.trim().isEmpty ? 'Say what this is for.' : null;

  String? get _categoryError => _category == null ? 'Choose a category.' : null;

  /// Switching money in/out drops a category that only fits the other way.
  void _setMoneyIn(bool moneyIn) {
    setState(() {
      _moneyIn = moneyIn;
      if (!poolCategoriesFor(moneyIn: moneyIn).any((c) => c.key == _category)) _category = null;
    });
  }

  String? get _jobError {
    final j = _job.text.trim().replaceFirst('#', '');
    if (j.isEmpty) return null;
    return RegExp(r'^\d{1,20}$').hasMatch(j) ? null : 'A job number is digits only.';
  }

  /// Each week's percent, or null where the field isn't a number.
  List<double?> get _percentValues => [for (final c in _percents) double.tryParse(c.text.trim().replaceAll('%', ''))];

  double get _percentTotal => _percentValues.fold<double>(0, (s, p) => s + (p ?? 0));

  /// The weeks' amounts, when every percent is usable and the amount is set.
  List<double>? get _weekAmounts {
    final amount = _amountValue;
    final ps = _percentValues;
    if (amount == null || amount <= 0 || ps.any((p) => p == null || p <= 0)) return null;
    return poolSplitByPercent(amount, [for (final p in ps) p!]);
  }

  String? get _spreadError {
    if (!_spread) return null;
    final ps = _percentValues;
    if (ps.any((p) => p == null || p <= 0)) return 'Every week needs a percent above 0.';
    final total = _percentTotal;
    if ((total - 100).abs() > 0.001) return 'The weeks add up to ${_pct(total)}%. They need to add up to 100%.';
    final amounts = _weekAmounts;
    if (amounts != null && amounts.any((a) => a <= 0)) return 'Every week needs at least \$0.01. Use fewer weeks.';
    return null;
  }

  Future<void> _pickDate() async {
    final now = DashClock.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2026, 1, 1),
      lastDate: DateTime(now.year + 1, 12, 31),
      helpText: _spread ? 'First week' : 'Date',
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _save() async {
    setState(() {
      _tried = true;
      _serverError = null;
    });
    if (_amountError != null || _categoryError != null || _noteError != null || _jobError != null || _spreadError != null) {
      return;
    }
    final amount = (_amountValue! * 100).round() / 100;
    setState(() => _saving = true);
    final body = json.encode({
      'direction': _moneyIn ? 'in' : 'out',
      'amount': amount,
      'category': _category,
      'note': _note.text.trim(),
      if (_job.text.trim().isNotEmpty) 'jobId': _job.text.trim().replaceFirst('#', ''),
      'date': DateFormat('yyyy-MM-dd').format(_date),
      if (_spread) 'weeklyPercents': [for (final p in _percentValues) p!],
    });
    final uri = Uri.parse('$kApiBaseUrl/api/retainage/company-pool/entries');
    final headers = {...AuthSession.instance.headers(), 'Content-Type': 'application/json'};
    http.Response res;
    try {
      final send = widget.post ?? (u, h, b) => http.post(u, headers: h, body: b);
      res = await send(uri, headers, body).timeout(const Duration(seconds: 30));
    } on TimeoutException {
      return _fail('The server took too long. Check the log before trying again, in case it was saved.');
    } catch (_) {
      return _fail("Couldn't reach the server. Check your connection and try again.");
    }
    if (!mounted) return;
    if (res.statusCode == 401) {
      AuthSession.instance.logout();
      return _fail('Your session has ended. Sign in again.');
    }
    if (res.statusCode == 403) return _fail("You don't have permission to add company pool entries.");
    if (res.statusCode == 201 || res.statusCode == 200) {
      Navigator.of(context).pop(PoolEntrySaved(_moneyIn ? amount : -amount, _spread ? _percents.length : 1));
      return;
    }
    String? message;
    try {
      final decoded = json.decode(res.body);
      if (decoded is Map && decoded['error'] is String) message = decoded['error'] as String;
    } catch (_) {}
    _fail(res.statusCode == 400 && message != null ? message : 'The entry was not saved. Try again.');
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _saving = false;
      _serverError = message;
    });
  }

  /// What Save will do, in a sentence.
  String? get _preview {
    final amount = _amountValue;
    if (amount == null || amount <= 0) return null;
    final verb = _moneyIn ? 'Adds' : 'Takes';
    final dir = _moneyIn ? 'to' : 'from';
    if (_spread && _percents.length > 1) {
      final last = _weekDate(_percents.length - 1);
      return '$verb ${dashMoney(amount)} $dir the company pool over ${_percents.length} weeks, '
          '${_weekFmt.format(_date)} to ${_weekFmt.format(last)}. Each week counts in the balance on its own day.';
    }
    if (_date.isAfter(_today())) {
      return '$verb ${dashMoney(amount)} $dir the company pool on ${_weekFmt.format(_date)}. '
          'It counts in the balance from that day.';
    }
    return '$verb ${dashMoney(amount)} $dir the company pool. It counts in the balance as soon as it is saved.';
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    return AppDialog(
      title: 'New company pool transaction',
      subtitle: 'Saved to our records only; nothing is sent to Service Fusion.',
      icon: Icons.savings_outlined,
      iconColor: DashUi.indigo,
      width: 520,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppSegmented<bool>(
            value: _moneyIn,
            options: const [(false, 'Money out'), (true, 'Money in')],
            onChanged: _saving ? (_) {} : _setMoneyIn,
          ),
          const SizedBox(height: 16),
          const AppFieldLabel('Amount', help: 'The whole amount, even when it is spread over weeks.'),
          TextField(
            controller: _amount,
            autofocus: true,
            enabled: !_saving,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,$ ]'))],
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _save(),
            decoration: appFieldDecoration(hint: '0.00', prefixText: '\$ ', error: _tried ? _amountError : null),
          ),
          const SizedBox(height: 14),
          const AppFieldLabel('Category'),
          DropdownButtonFormField<String>(
            key: ValueKey('category-$_moneyIn'),
            initialValue: _category,
            isExpanded: true,
            hint: const Text('Choose a category', style: TextStyle(fontSize: 14, color: DashUi.muted)),
            borderRadius: BorderRadius.circular(10),
            dropdownColor: Colors.white,
            // From the theme, so the app font carries over (a bare TextStyle here would drop it).
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 14, color: DashUi.ink),
            icon: const Icon(Icons.expand_more_rounded, color: DashUi.slate),
            items: [
              for (final c in poolCategoriesFor(moneyIn: _moneyIn))
                DropdownMenuItem(value: c.key, child: Text(c.label)),
            ],
            onChanged: _saving ? null : (v) => setState(() => _category = v),
            decoration: appFieldDecoration(error: _tried ? _categoryError : null),
          ),
          const SizedBox(height: 14),
          AppFieldLabel(
            'Note',
            help: _moneyIn
                ? 'What happened, e.g. vendor refunded the cracked panel'
                : 'What happened, e.g. backed into the customer\'s fence on job #1101295120; paid to replace it',
          ),
          TextField(
            controller: _note,
            enabled: !_saving,
            maxLength: 500,
            minLines: 1,
            maxLines: 3,
            onChanged: (_) => setState(() {}),
            decoration: appFieldDecoration(hint: 'Required', error: _tried ? _noteError : null).copyWith(counterText: ''),
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const AppFieldLabel('Job # (optional)'),
                    TextField(
                      controller: _job,
                      enabled: !_saving,
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) => _save(),
                      decoration: appFieldDecoration(hint: 'e.g. 1101296053', error: _tried ? _jobError : null),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AppFieldLabel(_spread ? 'First week' : 'Date'),
                    Semantics(
                      button: true,
                      label: '${_spread ? 'First week' : 'Date'}: ${_dateFmt.format(_date)}. Change the date',
                      excludeSemantics: true,
                      child: InkWell(
                        onTap: _saving ? null : _pickDate,
                        mouseCursor: SystemMouseCursors.click,
                        borderRadius: BorderRadius.circular(10),
                        child: InputDecorator(
                          isEmpty: false,
                          decoration: appFieldDecoration().copyWith(
                            suffixIcon: const Icon(Icons.event_rounded, size: 18, color: DashUi.slate),
                          ),
                          child: Text(
                            _dateFmt.format(_date),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 14, color: DashUi.ink),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const AppFieldLabel('How is it paid?'),
          AppSegmented<bool>(
            value: _spread,
            options: const [(false, 'All at once'), (true, 'Spread over weeks')],
            onChanged: _saving ? (_) {} : _toggleSpread,
          ),
          // The weeks open below with a short size-and-fade (instant with reduced motion).
          AnimatedSize(
            duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _spread ? _weeksEditor() : const SizedBox(width: double.infinity),
          ),
        ],
      ),
      footer: _serverError != null
          ? AppNotice(_serverError!, kind: AppNoticeKind.error)
          : preview == null
              ? null
              : AppNotice(preview),
      actions: [
        AppButton.ghost('Cancel', _saving ? null : () => Navigator.of(context).pop()),
        AppButton.ink(_saving ? 'Saving…' : 'Save transaction', _saving ? null : _save, icon: Icons.check_rounded),
      ],
    );
  }

  /// Number of weeks, then one row per week: its date, its percent and what that comes to.
  Widget _weeksEditor() {
    final weeks = _percents.length;
    final amounts = _weekAmounts;
    final total = _percentTotal;
    final error = _spreadError;
    final showError = error != null && (_tried || (total - 100).abs() > 0.001 && _percentValues.every((p) => p != null));
    const amountStyle = TextStyle(
      fontSize: 13.5,
      fontWeight: FontWeight.w700,
      color: DashUi.ink,
      fontFeatures: [FontFeature.tabularFigures()],
    );

    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text('Weeks', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: DashUi.ink)),
              const SizedBox(width: 10),
              IconButton(
                tooltip: 'One week fewer',
                visualDensity: VisualDensity.compact,
                onPressed: _saving || weeks <= 2 ? null : () => setState(() => _setWeeks(weeks - 1)),
                icon: const Icon(Icons.remove_rounded, size: 18),
              ),
              Semantics(
                label: '$weeks weeks',
                excludeSemantics: true,
                child: SizedBox(
                  width: 28,
                  child: Text('$weeks', textAlign: TextAlign.center, style: amountStyle.copyWith(fontSize: 15)),
                ),
              ),
              IconButton(
                tooltip: 'One week more',
                visualDensity: VisualDensity.compact,
                onPressed: _saving || weeks >= _maxWeeks ? null : () => setState(() => _setWeeks(weeks + 1)),
                icon: const Icon(Icons.add_rounded, size: 18),
              ),
              const Spacer(),
              TextButton(
                onPressed: _saving ? null : () => setState(() => _setWeeks(weeks)),
                style: TextButton.styleFrom(foregroundColor: DashUi.slate),
                child: const Text('Split evenly', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: DashUi.line)),
            child: Column(
              children: [
                for (var i = 0; i < weeks; i++)
                  Container(
                    padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                    decoration: BoxDecoration(
                      border: i == 0 ? null : const Border(top: BorderSide(color: DashUi.line)),
                    ),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 64,
                          child: Text('Week ${i + 1}',
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: DashUi.ink)),
                        ),
                        Expanded(
                          child: Text(
                            _weekFmt.format(_weekDate(i)),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13, color: DashUi.slate),
                          ),
                        ),
                        SizedBox(
                          width: 96,
                          child: TextField(
                            controller: _percents[i],
                            enabled: !_saving,
                            textAlign: TextAlign.right,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                            onChanged: (_) => setState(() {}),
                            style: amountStyle,
                            decoration: appFieldDecoration().copyWith(
                              suffixText: '%',
                              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 100,
                          child: Text(
                            amounts == null ? '—' : dashMoney(amounts[i]),
                            textAlign: TextAlign.right,
                            style: amountStyle,
                          ),
                        ),
                      ],
                    ),
                  ),
                Container(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  decoration: const BoxDecoration(
                    color: DashUi.faint,
                    border: Border(top: BorderSide(color: DashUi.line)),
                    borderRadius: BorderRadius.vertical(bottom: Radius.circular(11)),
                  ),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text('Total', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: DashUi.ink)),
                      ),
                      SizedBox(
                        width: 96,
                        child: Text(
                          '${_pct(total)}%',
                          textAlign: TextAlign.right,
                          style: amountStyle.copyWith(
                            color: (total - 100).abs() > 0.001 ? DashUi.redText : DashUi.ink,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 100,
                        child: Text(
                          _amountValue == null ? '—' : dashMoney(_amountValue!),
                          textAlign: TextAlign.right,
                          style: amountStyle,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (showError) ...[
            const SizedBox(height: 8),
            Text(error, style: const TextStyle(fontSize: 12.5, color: DashUi.redText, fontWeight: FontWeight.w600)),
          ],
        ],
      ),
    );
  }
}
