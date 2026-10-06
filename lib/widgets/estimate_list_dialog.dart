import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart' hide TextDirection;

import '../config/auth_session.dart';
import 'app_dialog.dart';
import 'dashboard_kit.dart';

// The click-through window used by the Sales and Estimates dashboards: click a number or a chart bar
// and this shows the estimates behind it. The caller supplies the heading and the endpoint URI; the
// endpoint returns { items: [...] } (see EstimateListItem.fromJson for the fields).

final _whole = NumberFormat('#,##0');
String _money(num v) => '${v < 0 ? '-' : ''}\$${_whole.format(v.abs())}';
double _d(dynamic v) => v == null ? 0.0 : (v is num ? v.toDouble() : double.tryParse(v.toString()) ?? 0.0);
int? _iOrNull(dynamic v) => v == null ? null : (v is num ? v.toInt() : int.tryParse(v.toString()));

/// One Clopay line on an estimate (door lists only).
class EstimateDoorLine {
  final String name;
  final double total;
  const EstimateDoorLine(this.name, this.total);
}

class EstimateListItem {
  final String jobId;
  final String customerName;
  final String status;
  final String location;
  final String description;
  final DateTime? startDate;
  final double value;
  final String outcome; // won | lost | open
  final String owner;

  /// Door lists only: what the chosen style's lines add up to, and the lines themselves.
  final double? doorValue;
  final List<EstimateDoorLine> doorLines;

  /// Days since the estimate date (pipeline lists).
  final int? daysOld;

  const EstimateListItem({
    required this.jobId,
    required this.customerName,
    required this.status,
    required this.location,
    required this.description,
    required this.startDate,
    required this.value,
    required this.outcome,
    this.owner = '',
    this.doorValue,
    this.doorLines = const [],
    this.daysOld,
  });

  factory EstimateListItem.fromJson(Map<String, dynamic> j) => EstimateListItem(
        jobId: (j['jobId'] ?? '').toString(),
        customerName: (j['customerName'] ?? 'Unknown').toString(),
        status: (j['status'] ?? '').toString(),
        location: (j['location'] ?? '').toString(),
        description: (j['description'] ?? '').toString(),
        startDate: DateTime.tryParse((j['startDate'] ?? '').toString()),
        value: _d(j['value']),
        outcome: (j['outcome'] ?? 'open').toString(),
        owner: (j['owner'] ?? '').toString(),
        doorValue: j['doorValue'] == null ? null : _d(j['doorValue']),
        doorLines: [
          for (final l in (j['doorLines'] as List<dynamic>? ?? const []))
            EstimateDoorLine((l['name'] ?? '').toString(), _d(l['total'])),
        ],
        daysOld: _iOrNull(j['daysOld']),
      );
}

enum EstimateListSort { newest, oldest, value }

class EstimateListDialog extends StatefulWidget {
  final int year;
  final String heading;

  /// Appended to the dollar total in the subtitle, e.g. "in door lines".
  final String totalLabel;
  final Color color;
  final IconData icon;
  final Uri uri;
  final EstimateListSort initialSort;

  /// Show the All / Won / Lost / Open pills (lists that mix outcomes).
  final bool outcomeFilter;
  final String initialOutcome;

  /// Singular name of what is listed ("estimate" or "job"), and a label to show instead of the year
  /// for lists that aren't year-scoped (e.g. "All time").
  final String noun;
  final String? periodLabel;

  /// Word after the day count on each row: "12 days old" (estimates) or "12 days overdue" (unpaid balances).
  final String ageLabel;

  const EstimateListDialog({
    super.key,
    required this.year,
    required this.heading,
    required this.color,
    required this.icon,
    required this.uri,
    this.totalLabel = '',
    this.initialSort = EstimateListSort.newest,
    this.outcomeFilter = false,
    this.initialOutcome = 'all',
    this.noun = 'estimate',
    this.periodLabel,
    this.ageLabel = 'old',
  });

  @override
  State<EstimateListDialog> createState() => _EstimateListDialogState();
}

class _EstimateListDialogState extends State<EstimateListDialog> {
  static final _dateFmt = DateFormat('MMM d, yyyy');

  bool _loading = true;
  String? _error;
  List<EstimateListItem> _items = [];
  String _query = '';
  late EstimateListSort _sort = widget.initialSort;
  late String _outcome = widget.initialOutcome;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await http.get(widget.uri, headers: AuthSession.instance.headers()).timeout(const Duration(seconds: 60));
      if (response.statusCode != 200) throw Exception('The server returned status ${response.statusCode}.');
      final body = json.decode(response.body) as Map<String, dynamic>;
      final items = ((body['items'] as List<dynamic>?) ?? const [])
          .map((e) => EstimateListItem.fromJson(e as Map<String, dynamic>))
          .toList();
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } on TimeoutException {
      if (mounted) {
        setState(() {
          _error = 'The list took too long to load.';
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString().replaceFirst('Exception: ', '');
          _loading = false;
        });
      }
    }
  }

  /// What a row is "worth" here: the door lines for a door list, otherwise the estimate itself.
  double _amount(EstimateListItem i) => i.doorValue ?? i.value;

  int _count(String outcome) => outcome == 'all' ? _items.length : _items.where((i) => i.outcome == outcome).length;

  List<EstimateListItem> get _visible {
    final q = _query.trim().toLowerCase();
    var list = [..._items];
    if (widget.outcomeFilter && _outcome != 'all') {
      list = list.where((i) => i.outcome == _outcome).toList();
    }
    if (q.isNotEmpty) {
      list = list
          .where((i) =>
              i.customerName.toLowerCase().contains(q) ||
              i.location.toLowerCase().contains(q) ||
              i.description.toLowerCase().contains(q) ||
              i.status.toLowerCase().contains(q) ||
              i.owner.toLowerCase().contains(q) ||
              i.doorLines.any((l) => l.name.toLowerCase().contains(q)) ||
              i.jobId.contains(q))
          .toList();
    }
    final epoch = DateTime(0);
    switch (_sort) {
      case EstimateListSort.value:
        list.sort((a, b) => _amount(b).compareTo(_amount(a)));
      case EstimateListSort.oldest:
        list.sort((a, b) => (a.startDate ?? epoch).compareTo(b.startDate ?? epoch));
      case EstimateListSort.newest:
        list.sort((a, b) => (b.startDate ?? epoch).compareTo(a.startDate ?? epoch));
    }
    return list;
  }

  Color _outcomeColor(String outcome) => switch (outcome) {
        'won' => DashUi.emeraldDeep,
        'lost' => DashUi.red,
        _ => DashUi.amber,
      };

  /// "1 x Clopay Classic Steel | T42L | Complete Door | Taxable" -> "Clopay Classic Steel | T42L | Complete Door".
  static String _cleanLine(String n) => n
      .replaceFirst(RegExp(r'^\s*\d+\s*x\s*', caseSensitive: false), '')
      .replaceAll(RegExp(r'\s*\|\s*(Sales Tax Applied|Taxable)[^|]*', caseSensitive: false), '')
      .trim();

  String _doorSummary(EstimateListItem it) {
    if (it.doorLines.isEmpty) return '';
    final first = _cleanLine(it.doorLines.first.name);
    final more = it.doorLines.length - 1;
    return more > 0 ? '$first   +$more more' : first;
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    final total = visible.fold<double>(0, (s, i) => s + _amount(i));
    final height = math.min(MediaQuery.sizeOf(context).height * 0.86, 780.0);

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
                Row(
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(color: widget.color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(11)),
                      child: Icon(widget.icon, size: 20, color: widget.color),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.heading,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: DashUi.ink, letterSpacing: -0.3),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            _loading
                                ? (widget.periodLabel ?? '${widget.year}')
                                : '${widget.periodLabel ?? widget.year} · ${visible.length} ${widget.noun}${visible.length == 1 ? '' : 's'} · '
                                    '${_money(total)}${widget.totalLabel.isEmpty ? '' : ' ${widget.totalLabel}'}',
                            style: const TextStyle(fontSize: 13, color: DashUi.slate),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close_rounded, size: 19, color: DashUi.muted),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        onChanged: (v) => setState(() => _query = v),
                        decoration: appFieldDecoration(hint: 'Search customer, address, description or status').copyWith(
                          prefixIcon: const Icon(Icons.search_rounded, size: 18, color: DashUi.muted),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 320,
                      child: AppSegmented<EstimateListSort>(
                        value: _sort,
                        options: const [
                          (EstimateListSort.newest, 'Newest'),
                          (EstimateListSort.oldest, 'Oldest'),
                          (EstimateListSort.value, 'Highest value'),
                        ],
                        onChanged: (v) => setState(() => _sort = v),
                        activeColor: widget.color,
                      ),
                    ),
                  ],
                ),
                if (widget.outcomeFilter) ...[
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SizedBox(
                      width: 420,
                      child: AppSegmented<String>(
                        value: _outcome,
                        options: [
                          ('all', 'All (${_count('all')})'),
                          ('won', 'Won (${_count('won')})'),
                          ('lost', 'Lost (${_count('lost')})'),
                          ('open', 'Open (${_count('open')})'),
                        ],
                        onChanged: (v) => setState(() => _outcome = v),
                        activeColor: widget.color,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                Expanded(child: _body(visible)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(List<EstimateListItem> visible) {
    if (_loading) {
      return SkeletonPulse(
        child: Column(
          children: [
            for (var i = 0; i < 7; i++) ...const [SkeletonBox(h: 58, r: 12), SizedBox(height: 8)],
          ],
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppNotice(_error!, kind: AppNoticeKind.error),
            const SizedBox(height: 12),
            AppButton.ink('Try again', _load, icon: Icons.refresh_rounded),
          ],
        ),
      );
    }
    if (visible.isEmpty) {
      return Center(
        child: Text(
          _items.isEmpty ? 'No ${widget.noun}s found${widget.periodLabel == null ? ' for ${widget.year}' : ''}.' : 'Nothing matches that filter.',
          style: const TextStyle(fontSize: 14, color: DashUi.muted),
        ),
      );
    }
    return ListView.separated(
      itemCount: visible.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) => _row(visible[i]),
    );
  }

  Widget _row(EstimateListItem it) {
    final doorMode = it.doorValue != null;
    final doorSummary = doorMode ? _doorSummary(it) : '';
    final sub = doorSummary.isNotEmpty
        ? doorSummary
        : (it.description.trim().isNotEmpty ? it.description.trim() : it.location.trim());
    final tagColor = _outcomeColor(it.outcome);
    final meta = [
      if (it.owner.isNotEmpty) it.owner,
      '#${it.jobId}',
      if (it.startDate != null) _dateFmt.format(it.startDate!),
      if (it.daysOld != null)
        it.daysOld! >= 0
            ? '${it.daysOld} ${it.daysOld == 1 ? 'day' : 'days'} ${widget.ageLabel}'
            : 'starts in ${-it.daysOld!} ${it.daysOld == -1 ? 'day' : 'days'}',
    ].join(' · ');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: DashUi.line),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  it.customerName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: DashUi.ink),
                ),
                if (sub.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5, color: DashUi.slate),
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  meta,
                  style: const TextStyle(fontSize: 11.5, color: DashUi.muted, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _money(_amount(it)),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: DashUi.ink,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              if (doorMode)
                Text(
                  'Estimate ${_money(it.value)}',
                  style: const TextStyle(fontSize: 11, color: DashUi.muted, fontWeight: FontWeight.w600),
                ),
              const SizedBox(height: 4),
              if (it.status.isNotEmpty) AppTag(it.status, color: tagColor),
            ],
          ),
        ],
      ),
    );
  }
}
