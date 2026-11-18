import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'app_dialog.dart';
import 'company_pool_dialog.dart' show PoolSummaryTile;
import 'dashboard_data.dart';
import 'dashboard_kit.dart';

// The Financial dashboard's "Commercial pool" figure, opened: every commercial retainage row (the share withheld from
// each tech on a commercial job, and callback charges taken from it), whether it is still locked or was released, and
// when it unlocks. Read-only: retainage is released from payroll, not from here.
//
//   GET /api/retainage/commercial-pool  { balance, pending, readyToRelease, released, nextUnlock, entries: [...] }
//
// Needs the Payroll switch (View).

/// Opens the log.
Future<void> showCommercialPoolDialog(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const CommercialPoolDialog());

double _d(dynamic v) => v == null ? 0.0 : (v is num ? v.toDouble() : double.tryParse(v.toString()) ?? 0.0);

DateTime? _day(dynamic v) => v == null ? null : DateTime.tryParse(v.toString());

class CommercialEntry {
  final int? id;
  final bool callback;
  final double amount;
  final String? jobId;
  final String? customer;
  final String tech;
  final DateTime? date;
  final DateTime? unlockDate;
  final DateTime? releasedDate;
  final bool released;

  /// False while the job's pay week has no finalized payroll run: in the log but not in the balance yet.
  final bool counted;

  const CommercialEntry({
    required this.id,
    required this.callback,
    required this.amount,
    required this.jobId,
    required this.customer,
    required this.tech,
    required this.date,
    required this.unlockDate,
    required this.releasedDate,
    required this.released,
    required this.counted,
  });

  factory CommercialEntry.fromJson(Map<String, dynamic> j) {
    final job = j['jobId']?.toString().trim();
    return CommercialEntry(
      id: j['id'] is num ? (j['id'] as num).toInt() : int.tryParse('${j['id']}'),
      callback: j['kind'] == 'callback',
      amount: _d(j['amount']),
      jobId: job == null || job.isEmpty ? null : job,
      customer: (j['customer'] as String?)?.trim(),
      tech: (j['tech'] ?? '').toString().trim(),
      date: _day(j['date']),
      unlockDate: _day(j['unlockDate']),
      releasedDate: _day(j['releasedDate']),
      released: j['released'] == true,
      counted: j['counted'] == true,
    );
  }

  String get kindLabel => callback ? 'Callback charge' : 'Withheld';
}

class CommercialPoolLog {
  final double balance;
  final double pending;
  final double readyToRelease;
  final double released;
  final DateTime? nextUnlock;
  final List<CommercialEntry> entries;
  const CommercialPoolLog({
    required this.balance,
    required this.pending,
    required this.readyToRelease,
    required this.released,
    required this.nextUnlock,
    required this.entries,
  });

  factory CommercialPoolLog.fromJson(Map<String, dynamic> j) => CommercialPoolLog(
        balance: _d(j['balance']),
        pending: _d(j['pending']),
        readyToRelease: _d(j['readyToRelease']),
        released: _d(j['released']),
        nextUnlock: _day(j['nextUnlock']),
        entries: [
          for (final e in (j['entries'] as List<dynamic>? ?? const []))
            CommercialEntry.fromJson(e as Map<String, dynamic>),
        ],
      );
}

enum _Filter { all, locked, released, callbacks }

class CommercialPoolDialog extends StatefulWidget {
  const CommercialPoolDialog({super.key});

  @override
  State<CommercialPoolDialog> createState() => _CommercialPoolDialogState();
}

class _CommercialPoolDialogState extends State<CommercialPoolDialog> {
  static final _dateFmt = DateFormat('MMM d, yyyy');

  final _requests = DashRequests();
  bool _loading = true;
  DashLoadException? _error;
  CommercialPoolLog? _log;
  String _query = '';
  _Filter _filter = _Filter.all;

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
      final payload = await _requests.get('/api/retainage/commercial-pool');
      if (payload == null || !mounted) return;
      final CommercialPoolLog log;
      try {
        log = CommercialPoolLog.fromJson(payload.body);
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

  void _close() => Navigator.of(context).pop();

  List<CommercialEntry> get _visible {
    final all = _log?.entries ?? const <CommercialEntry>[];
    final q = _query.trim().toLowerCase().replaceFirst('#', '');
    return all.where((e) {
      final keep = switch (_filter) {
        _Filter.all => true,
        _Filter.locked => !e.released,
        _Filter.released => e.released,
        _Filter.callbacks => e.callback,
      };
      if (!keep) return false;
      if (q.isEmpty) return true;
      return (e.jobId ?? '').contains(q) ||
          (e.customer ?? '').toLowerCase().contains(q) ||
          e.tech.toLowerCase().contains(q) ||
          e.kindLabel.toLowerCase().contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final height = math.min(MediaQuery.sizeOf(context).height * 0.86, 780.0);
    final log = _log;
    final narrow = MediaQuery.sizeOf(context).width < 720;

    return Dialog(
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
    );
  }

  Widget _header(CommercialPoolLog? log) {
    final next = log?.nextUnlock;
    final sub = log == null
        ? 'Every commercial retainage entry'
        : [
            'All time · ${log.entries.length} ${log.entries.length == 1 ? 'entry' : 'entries'}',
            if (next != null) 'next release ${_dateFmt.format(next)}',
          ].join(' · ');
    return Row(
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(color: DashUi.ink.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(11)),
          child: const Icon(Icons.lock_clock_outlined, size: 20, color: DashUi.ink),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Commercial pool',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: DashUi.ink, letterSpacing: -0.3),
              ),
              const SizedBox(height: 3),
              Text(
                sub,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, color: DashUi.slate),
              ),
            ],
          ),
        ),
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

  Widget _summary(CommercialPoolLog log, bool narrow) {
    final tiles = [
      PoolSummaryTile(
        label: 'Locked',
        value: log.balance,
        caption: 'Same as the dashboard',
        color: log.balance < 0 ? DashUi.redText : DashUi.ink,
      ),
      PoolSummaryTile(
        label: 'Ready to release',
        value: log.readyToRelease,
        caption: 'Unlock date has passed',
        color: DashUi.emeraldText,
      ),
      PoolSummaryTile(label: 'Waiting for payroll', value: log.pending, caption: 'Until payroll is run', color: DashUi.amberText),
      PoolSummaryTile(label: 'Released', value: log.released, caption: 'Paid out to techs', color: DashUi.slate),
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

  Widget _filters(CommercialPoolLog log, bool narrow) {
    int count(bool Function(CommercialEntry) f) => log.entries.where(f).length;
    final pills = AppSegmented<_Filter>(
      value: _filter,
      options: [
        (_Filter.all, 'All (${log.entries.length})'),
        (_Filter.locked, 'Locked (${count((e) => !e.released)})'),
        (_Filter.released, 'Released (${count((e) => e.released)})'),
        (_Filter.callbacks, 'Callbacks (${count((e) => e.callback)})'),
      ],
      onChanged: (v) => setState(() => _filter = v),
    );
    final search = TextField(
      onChanged: (v) => setState(() => _query = v),
      decoration: appFieldDecoration(hint: 'Search job #, customer or tech').copyWith(
        prefixIcon: const Icon(Icons.search_rounded, size: 18, color: DashUi.muted),
      ),
    );
    if (narrow) return Column(children: [search, const SizedBox(height: 10), pills]);
    return Row(
      children: [
        Expanded(child: search),
        const SizedBox(width: 12),
        SizedBox(width: 420, child: pills),
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
            AppNotice('${error.title('the commercial pool')}. ${error.message}', kind: AppNoticeKind.error),
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
        child: Text(
          none ? 'No commercial retainage has been withheld yet.' : 'Nothing matches that filter.',
          style: const TextStyle(fontSize: 14, color: DashUi.muted),
        ),
      );
    }
    return ListView.separated(
      itemCount: visible.length,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (context, i) => _row(visible[i]),
    );
  }

  void _openJob(String jobId) {
    final router = GoRouter.of(context);
    Navigator.of(context).pop();
    router.go('/jobs/${Uri.encodeComponent(jobId)}');
  }

  Widget _row(CommercialEntry e) {
    final out = e.amount < 0;
    final (IconData icon, Color tone) =
        e.callback ? (Icons.replay_rounded, DashUi.red) : (Icons.south_west_rounded, DashUi.emeraldDeep);
    final title = [if (e.jobId != null) 'Job #${e.jobId}', if ((e.customer ?? '').isNotEmpty) e.customer!].join(' · ');
    final meta = [
      e.kindLabel,
      if (e.tech.isNotEmpty) e.tech,
      if (e.date != null) _dateFmt.format(e.date!),
      if (!e.released && e.unlockDate != null) 'unlocks ${_dateFmt.format(e.unlockDate!)}',
    ].join(' · ');

    final Widget? tag = e.released
        ? Tooltip(
            message: e.releasedDate == null
                ? 'Paid out to ${e.tech.isEmpty ? 'the tech' : e.tech}.'
                : 'Paid out to ${e.tech.isEmpty ? 'the tech' : e.tech} on ${_dateFmt.format(e.releasedDate!)}.',
            child: const AppTag('Released', color: DashUi.slate),
          )
        : !e.counted
            ? const Tooltip(
                message: 'Not in the balance yet: it counts once payroll is run for the week this job closed in.',
                child: AppTag('Waiting for payroll', color: DashUi.amberText),
              )
            : null;

    final row = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
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
          if (tag != null) ...[tag, const SizedBox(width: 10)],
          SizedBox(
            width: 104,
            child: Text(
              '${out ? '' : '+'}${dashMoney(e.amount)}',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: e.released ? DashUi.muted : (out ? DashUi.redText : DashUi.emeraldText),
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );

    final semantics = '$title, ${e.kindLabel}${e.tech.isEmpty ? '' : ', ${e.tech}'}, '
        '${out ? 'out' : 'in'} ${dashMoney(e.amount.abs())}'
        '${e.date == null ? '' : ', ${_dateFmt.format(e.date!)}'}'
        '${e.released ? ', released' : e.counted ? '' : ', waiting for payroll'}';
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
