import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

// ---------------------------------------------------------------------------
// Palette
// ---------------------------------------------------------------------------
class _C {
  static const ink = Color(0xFF14213D); // navy: header, primary text
  static const paper = Color(0xFFF4F5F7); // page background
  static const card = Colors.white;
  static const line = Color(0xFFE3E6EB); // borders / dividers
  static const muted = Color(0xFF6B7585); // secondary text
  static const amber = Color(0xFFE09F1F); // primary action
  static const pay = Color(0xFF1B7F4B); // take-home money
  static const loss = Color(0xFFB4412F); // penalties
  static const barTrack = Color(0xFFEDEFF3);
}

class _PayrollRow {
  final String name;
  final int jobs;
  final double penalized;
  final double takeHome;

  const _PayrollRow({
    required this.name,
    required this.jobs,
    required this.penalized,
    required this.takeHome,
  });

  factory _PayrollRow.fromJson(Map<String, dynamic> j) => _PayrollRow(
        name: (j['tech_name'] ?? 'Unknown').toString(),
        jobs: int.tryParse(j['jobs_worked'].toString()) ?? 0,
        penalized: double.tryParse(j['penalized_amount'].toString()) ?? 0.0,
        takeHome: double.tryParse(j['take_home_pay'].toString()) ?? 0.0,
      );

  String get initials {
    final parts =
        name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }
}

class _Preset {
  final String label;
  final DateTimeRange range;
  const _Preset(this.label, this.range);
}

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------
class PayrollScreen extends StatefulWidget {
  const PayrollScreen({super.key});

  @override
  State<PayrollScreen> createState() => _PayrollScreenState();
}

class _PayrollScreenState extends State<PayrollScreen> {
  bool isLoading = false;
  bool hasRun = false;
  String? errorMessage;
  List<_PayrollRow> rows = [];

  final NumberFormat currency = NumberFormat.currency(symbol: '\$');
  final DateFormat dateFormat = DateFormat('MMM d, yyyy');
  final DateFormat shortFormat = DateFormat('MMM d');

  late DateTimeRange selectedDateRange;

  static DateTime _today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  @override
  void initState() {
    super.initState();
    final t = _today();
    selectedDateRange =
        DateTimeRange(start: t.subtract(const Duration(days: 7)), end: t);
  }

  List<_Preset> get _presets {
    final t = _today();
    final monday = t.subtract(Duration(days: t.weekday - 1));
    final lastMonday = monday.subtract(const Duration(days: 7));
    return [
      _Preset('Last 7 days',
          DateTimeRange(start: t.subtract(const Duration(days: 7)), end: t)),
      _Preset('This week', DateTimeRange(start: monday, end: t)),
      _Preset(
          'Last week',
          DateTimeRange(
              start: lastMonday, end: lastMonday.add(const Duration(days: 6)))),
      _Preset('This month',
          DateTimeRange(start: DateTime(t.year, t.month, 1), end: t)),
    ];
  }

  bool _sameRange(DateTimeRange a, DateTimeRange b) =>
      a.start.year == b.start.year &&
      a.start.month == b.start.month &&
      a.start.day == b.start.day &&
      a.end.year == b.end.year &&
      a.end.month == b.end.month &&
      a.end.day == b.end.day;

  Future<void> pickDateRange() async {
    final DateTimeRange? newRange = await showDateRangePicker(
      context: context,
      initialDateRange: selectedDateRange,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      builder: (context, child) {
        return Theme(
          data: ThemeData.light().copyWith(
            colorScheme: const ColorScheme.light(
              primary: _C.ink,
              onPrimary: Colors.white,
              surface: Colors.white,
              onSurface: _C.ink,
            ),
          ),
          child: child!,
        );
      },
    );

    if (newRange != null) {
      setState(() => selectedDateRange = newRange);
    }
  }

  Future<void> generatePayroll() async {
    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    final startDateStr =
        DateFormat('yyyy-MM-dd').format(selectedDateRange.start);
    final endDateStr = DateFormat('yyyy-MM-dd').format(selectedDateRange.end);

    try {
      final url =
          'https://integrity-backend-cr02.onrender.com/api/payroll/weekly-summary?startDate=$startDateStr&endDate=$endDateStr';
      final response = await http.get(Uri.parse(url));
      if (!mounted) return;

      if (response.statusCode == 200) {
        final jsonResponse = json.decode(response.body);
        final list = (jsonResponse['data'] ?? []) as List<dynamic>;
        final parsed = list
            .map((e) => _PayrollRow.fromJson(e as Map<String, dynamic>))
            .toList()
          ..sort((a, b) => b.takeHome.compareTo(a.takeHome));
        setState(() {
          rows = parsed;
          hasRun = true;
          isLoading = false;
        });
      } else {
        setState(() {
          errorMessage =
              'The server returned an error (${response.statusCode}). Try again in a moment.';
          isLoading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        errorMessage =
            'Could not reach the server. Check your connection and try again.';
        isLoading = false;
      });
    }
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _C.paper,
      appBar: AppBar(
        backgroundColor: _C.ink,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text(
          'Payroll',
          style: TextStyle(
              fontWeight: FontWeight.w700, color: Colors.white, fontSize: 20),
        ),
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              _buildControls(),
              const SizedBox(height: 20),
              ..._buildResults(),
            ],
          ),
        ),
      ),
    );
  }

  // --- Pay period + run -----------------------------------------------------
  Widget _buildControls() {
    final presets = _presets;
    final rangeText =
        '${dateFormat.format(selectedDateRange.start)} – ${dateFormat.format(selectedDateRange.end)}';
    final days = selectedDateRange.end.difference(selectedDateRange.start).inDays + 1;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _C.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _C.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 16,
            runSpacing: 16,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Pay period',
                      style: TextStyle(
                          fontSize: 13,
                          color: _C.muted,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(rangeText,
                      style: const TextStyle(
                          fontSize: 24,
                          color: _C.ink,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.3)),
                  const SizedBox(height: 2),
                  Text('$days ${days == 1 ? 'day' : 'days'}',
                      style: const TextStyle(fontSize: 13, color: _C.muted)),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.edit_calendar_outlined, size: 18),
                    label: const Text('Custom dates'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _C.ink,
                      side: const BorderSide(color: _C.line),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: pickDateRange,
                  ),
                  const SizedBox(width: 10),
                  FilledButton.icon(
                    icon: isLoading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: _C.ink))
                        : const Icon(Icons.play_arrow_rounded, size: 22),
                    label: Text(isLoading ? 'Running…' : 'Run payroll'),
                    style: FilledButton.styleFrom(
                      backgroundColor: _C.amber,
                      foregroundColor: _C.ink,
                      textStyle: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 15),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 22, vertical: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: isLoading ? null : generatePayroll,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: presets.map((p) {
              final selected = _sameRange(p.range, selectedDateRange);
              return ChoiceChip(
                label: Text(p.label),
                selected: selected,
                showCheckmark: false,
                labelStyle: TextStyle(
                  color: selected ? Colors.white : _C.ink,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
                backgroundColor: _C.paper,
                selectedColor: _C.ink,
                side: BorderSide(color: selected ? _C.ink : _C.line),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20)),
                onSelected: (_) => setState(() => selectedDateRange = p.range),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  // --- Results area ---------------------------------------------------------
  List<Widget> _buildResults() {
    if (isLoading && rows.isEmpty) {
      return [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 80),
          child: Center(child: CircularProgressIndicator(color: _C.ink)),
        ),
      ];
    }

    final widgets = <Widget>[];

    if (errorMessage != null) {
      widgets.add(_buildError(errorMessage!));
      widgets.add(const SizedBox(height: 20));
    }

    if (!hasRun) {
      if (errorMessage == null) {
        widgets.add(_buildEmpty(
          icon: Icons.request_quote_outlined,
          title: 'No report yet',
          message: 'Choose a pay period, then select Run payroll.',
        ));
      }
      return widgets;
    }

    if (rows.isEmpty) {
      widgets.add(_buildEmpty(
        icon: Icons.search_off_rounded,
        title: 'No payroll for this period',
        message: 'No technician activity was found for these dates.',
      ));
      return widgets;
    }

    final totalTake = rows.fold<double>(0, (s, r) => s + r.takeHome);
    final totalPenalty = rows.fold<double>(0, (s, r) => s + r.penalized);
    final totalJobs = rows.fold<int>(0, (s, r) => s + r.jobs);
    final maxTake = rows.map((r) => r.takeHome).fold<double>(0, (a, b) => a > b ? a : b);

    widgets.add(_buildSummary(totalTake, totalPenalty, totalJobs));
    widgets.add(const SizedBox(height: 20));
    widgets.add(_buildTable(maxTake));
    return widgets;
  }

  Widget _buildSummary(double totalTake, double totalPenalty, int totalJobs) {
    final tiles = [
      _StatTile(
        label: 'Total take-home',
        value: currency.format(totalTake),
        color: _C.pay,
        big: true,
      ),
      _StatTile(
        label: 'Penalized',
        value: currency.format(totalPenalty),
        color: totalPenalty > 0 ? _C.loss : _C.muted,
      ),
      _StatTile(
        label: 'Jobs worked',
        value: totalJobs.toString(),
        color: _C.ink,
      ),
      _StatTile(
        label: 'Technicians',
        value: rows.length.toString(),
        color: _C.ink,
      ),
    ];

    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth >= 760) {
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 5, child: tiles[0]),
              const SizedBox(width: 12),
              Expanded(flex: 3, child: tiles[1]),
              const SizedBox(width: 12),
              Expanded(flex: 3, child: tiles[2]),
              const SizedBox(width: 12),
              Expanded(flex: 3, child: tiles[3]),
            ],
          ),
        );
      }
      return Column(
        children: [
          tiles[0],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: tiles[1]),
              const SizedBox(width: 12),
              Expanded(child: tiles[2]),
            ],
          ),
          const SizedBox(height: 12),
          tiles[3],
        ],
      );
    });
  }

  Widget _buildTable(double maxTake) {
    return Container(
      decoration: BoxDecoration(
        color: _C.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _C.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(builder: (context, c) {
        final wide = c.maxWidth >= 720;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
              child: Row(
                children: [
                  const Text('Technicians',
                      style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          color: _C.ink)),
                  const SizedBox(width: 8),
                  Text('${rows.length}',
                      style: const TextStyle(
                          fontSize: 15,
                          color: _C.muted,
                          fontWeight: FontWeight.w600)),
                  const Spacer(),
                  const Text('Highest take-home first',
                      style: TextStyle(fontSize: 12, color: _C.muted)),
                ],
              ),
            ),
            if (wide) _buildHeaderRow(),
            const Divider(height: 1, color: _C.line),
            for (int i = 0; i < rows.length; i++) ...[
              wide ? _wideRow(rows[i], maxTake) : _narrowRow(rows[i], maxTake),
              if (i != rows.length - 1)
                const Divider(height: 1, color: _C.line),
            ],
          ],
        );
      }),
    );
  }

  Widget _buildHeaderRow() {
    const style = TextStyle(
        fontSize: 12, fontWeight: FontWeight.w600, color: _C.muted);
    return Container(
      color: _C.paper,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: const Row(
        children: [
          Expanded(flex: 5, child: Text('Technician', style: style)),
          Expanded(
              flex: 2,
              child:
                  Text('Jobs', textAlign: TextAlign.right, style: style)),
          Expanded(
              flex: 3,
              child: Text('Penalized',
                  textAlign: TextAlign.right, style: style)),
          Expanded(
              flex: 4,
              child: Text('Take-home',
                  textAlign: TextAlign.right, style: style)),
        ],
      ),
    );
  }

  static const _figures = [FontFeature.tabularFigures()];

  Widget _avatar(_PayrollRow r) {
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: _C.ink,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(r.initials,
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14)),
    );
  }

  Widget _shareBar(_PayrollRow r, double maxTake) {
    final frac = maxTake <= 0 ? 0.0 : (r.takeHome / maxTake).clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: LinearProgressIndicator(
        value: frac,
        minHeight: 5,
        backgroundColor: _C.barTrack,
        valueColor: const AlwaysStoppedAnimation(_C.pay),
      ),
    );
  }

  Widget _penaltyText(_PayrollRow r) {
    if (r.penalized <= 0) {
      return const Text('—', style: TextStyle(color: _C.muted, fontSize: 15));
    }
    return Text(
      '−${currency.format(r.penalized)}',
      style: const TextStyle(
          color: _C.loss,
          fontWeight: FontWeight.w600,
          fontSize: 15,
          fontFeatures: _figures),
    );
  }

  Widget _wideRow(_PayrollRow r, double maxTake) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Row(
        children: [
          Expanded(
            flex: 5,
            child: Row(
              children: [
                _avatar(r),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(r.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                          color: _C.ink)),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Text('${r.jobs}',
                textAlign: TextAlign.right,
                style: const TextStyle(
                    fontSize: 15, color: _C.ink, fontFeatures: _figures)),
          ),
          Expanded(
            flex: 3,
            child: Align(
                alignment: Alignment.centerRight, child: _penaltyText(r)),
          ),
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(currency.format(r.takeHome),
                    style: const TextStyle(
                        color: _C.pay,
                        fontWeight: FontWeight.w800,
                        fontSize: 17,
                        fontFeatures: _figures)),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.only(left: 24),
                  child: _shareBar(r, maxTake),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _narrowRow(_PayrollRow r, double maxTake) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _avatar(r),
              const SizedBox(width: 12),
              Expanded(
                child: Text(r.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: _C.ink)),
              ),
              Text(currency.format(r.takeHome),
                  style: const TextStyle(
                      color: _C.pay,
                      fontWeight: FontWeight.w800,
                      fontSize: 17,
                      fontFeatures: _figures)),
            ],
          ),
          const SizedBox(height: 10),
          _shareBar(r, maxTake),
          const SizedBox(height: 10),
          Row(
            children: [
              Text('${r.jobs} ${r.jobs == 1 ? 'job' : 'jobs'}',
                  style: const TextStyle(color: _C.muted, fontSize: 13)),
              const Spacer(),
              if (r.penalized > 0) ...[
                const Text('Penalized ',
                    style: TextStyle(color: _C.muted, fontSize: 13)),
                _penaltyText(r),
              ],
            ],
          ),
        ],
      ),
    );
  }

  // --- States ---------------------------------------------------------------
  Widget _buildEmpty({
    required IconData icon,
    required String title,
    required String message,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 56, horizontal: 24),
      decoration: BoxDecoration(
        color: _C.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _C.line),
      ),
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: _C.paper,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, size: 30, color: _C.muted),
          ),
          const SizedBox(height: 16),
          Text(title,
              style: const TextStyle(
                  fontSize: 17, fontWeight: FontWeight.w800, color: _C.ink)),
          const SizedBox(height: 6),
          Text(message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: _C.muted)),
        ],
      ),
    );
  }

  Widget _buildError(String message) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFBEDEA),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFEBC4BC)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, color: _C.loss),
          const SizedBox(width: 12),
          Expanded(
            child: Text(message,
                style: const TextStyle(color: _C.loss, fontSize: 14)),
          ),
          TextButton(
            onPressed: isLoading ? null : generatePayroll,
            child: const Text('Try again'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Summary tile
// ---------------------------------------------------------------------------
class _StatTile extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final bool big;

  const _StatTile({
    required this.label,
    required this.value,
    required this.color,
    this.big = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: _C.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _C.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 13, color: _C.muted, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: TextStyle(
                fontSize: big ? 32 : 24,
                fontWeight: FontWeight.w800,
                color: color,
                letterSpacing: -0.5,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}