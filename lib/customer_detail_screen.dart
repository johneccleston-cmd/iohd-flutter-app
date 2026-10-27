import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import 'config/api_config.dart';
import 'config/auth_session.dart';
import 'utils/status_colors.dart';
import 'widgets/dashboard_kit.dart' show DashUi, SkeletonPulse;
import 'widgets/flat_page.dart';
import 'widgets/quo_activity_panel.dart';

/// The `/customers/:id` route (a child of `/customers`). Keyed by id so a different customer never reuses the old state.
GoRoute customerDetailRoute() => GoRoute(
  path: ':id',
  builder: (context, state) {
    final id = state.pathParameters['id'] ?? '';
    return CustomerDetailScreen(
      key: ValueKey('customer-$id'),
      customerId: id,
      initial: state.extra is Map ? Map<String, dynamic>.from(state.extra as Map) : null,
    );
  },
);

/// Full-page view of one customer, laid out like the Service Fusion "Edit Customer" page: tabs along the top, Account
/// Info first. Read-only for now: edits would have to be saved to our own database, never to Service Fusion.
/// [initial] is the row the Customers list already had, shown right away while the full record loads.
class CustomerDetailScreen extends StatefulWidget {
  final String customerId;
  final Map<String, dynamic>? initial;
  const CustomerDetailScreen({super.key, required this.customerId, this.initial});

  @override
  State<CustomerDetailScreen> createState() => _CustomerDetailScreenState();
}

class _CustomerDetailScreenState extends State<CustomerDetailScreen> {
  static const _tabs = ['Account Info', 'Financial Data', 'Service Locations', 'Jobs & Estimates', 'Calls & Texts'];
  static const double _maxWidth = 1100;

  Map<String, dynamic>? _customer;
  List<Map<String, dynamic>> _jobs = const [];
  bool _loading = true;
  String? _error;
  int _tab = 0;

  final _money = NumberFormat.currency(symbol: r'$');

  @override
  void initState() {
    super.initState();
    _customer = widget.initial;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    unawaited(QuoActivityPanel.prefetch(customerId: widget.customerId)); // so the Calls & Texts tab opens with them
    try {
      final res = await http
          .get(Uri.parse('$kApiBaseUrl/api/customers/${Uri.encodeComponent(widget.customerId)}'), headers: AuthSession.instance.headers())
          .timeout(const Duration(seconds: 40));
      if (!mounted) return;
      if (res.statusCode == 401) {
        AuthSession.instance.logout(); // sends the app back to the sign-in screen
        return;
      }
      if (res.statusCode == 404) return _fail('Customer ${widget.customerId} was not found.');
      if (res.statusCode == 403) return _fail('Your account does not have access to customer data.');
      if (res.statusCode != 200) return _fail('Server error (${res.statusCode}).');
      final data = json.decode(res.body) as Map<String, dynamic>;
      setState(() {
        _customer = Map<String, dynamic>.from(data['customer'] as Map);
        _jobs = List<Map<String, dynamic>>.from(data['jobs'] ?? const []);
        _loading = false;
      });
    } on TimeoutException {
      if (mounted) _fail('The server is taking too long to respond. It may be waking up — try again in a moment.');
    } catch (_) {
      if (mounted) _fail('Could not reach the server.');
    }
  }

  void _fail(String message) => setState(() {
    _loading = false;
    _error = message;
  });

  String? _clean(dynamic v) {
    final s = v?.toString().trim();
    return s == null || s.isEmpty || s == '--' ? null : s;
  }

  /// "Lisa Swaim" -> ("Lisa", "Swaim"). One word is a first name.
  (String, String) _splitName(String? full) {
    final parts = (full ?? '').trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return ('', '');
    if (parts.length == 1) return (parts.first, '');
    return (parts.first, parts.sublist(1).join(' '));
  }

  @override
  Widget build(BuildContext context) {
    final c = _customer;
    final name = _clean(c?['customer_name']) ?? (_loading ? 'Customer' : 'Unknown customer');
    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageBanner(
            title: name,
            actions: [
              PageBanner.button(icon: Icons.arrow_back_rounded, label: 'All customers', onPressed: () => context.go('/customers')),
              PageBanner.refresh(onPressed: _loading ? null : _load),
            ],
          ),
          SizedBox(height: 3, child: _loading ? const LinearProgressIndicator(minHeight: 3, color: DashUi.ink, backgroundColor: DashUi.line) : null),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_error != null && _customer == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 44, color: DashUi.red),
            const SizedBox(height: 16),
            const Text("Couldn't load this customer", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: DashUi.ink)),
            const SizedBox(height: 6),
            Text(_error!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 14.5, color: DashUi.slate)),
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: _load, child: const Text('Try again')),
          ],
        ),
      );
    }
    if (_customer == null) {
      return const Padding(padding: EdgeInsets.all(24), child: SkeletonPulse(child: SizedBox(height: 160, width: double.infinity)));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _tabBar(),
        Expanded(
          child: SingleChildScrollView(
            child: Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _maxWidth),
                child: switch (_tab) {
                  0 => _accountInfo(_customer!),
                  1 => _financial(),
                  2 => _serviceLocations(_customer!),
                  3 => _jobsTable(),
                  _ => QuoActivityPanel(key: ValueKey('quo-${widget.customerId}'), customerId: widget.customerId),
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _tabBar() {
    return Container(
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: DashUi.line))),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (var i = 0; i < _tabs.length; i++)
              InkWell(
                onTap: () => setState(() => _tab = i),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(border: Border(bottom: BorderSide(color: _tab == i ? DashUi.ink : Colors.transparent, width: 3))),
                  child: Text(
                    i == 3 ? '${_tabs[i]} (${_jobs.length})' : _tabs[i],
                    style: TextStyle(fontSize: 15, fontWeight: _tab == i ? FontWeight.w800 : FontWeight.w500, color: _tab == i ? DashUi.ink : DashUi.slate),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ---- Account Info ---------------------------------------------------------
  Widget _accountInfo(Map<String, dynamic> c) {
    final (first, last) = _splitName(_clean(c['primary_contact']));
    final since = DateTime.tryParse('${c['first_seen_at'] ?? ''}')?.toLocal();
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _fieldRow([
            _Field('Customer name', _clean(c['customer_name'])),
            _Field('Account number', _clean(c['account_number'])),
            _Field('Customer since', since == null ? null : DateFormat.yMMMd().format(since)),
          ]),
          const SizedBox(height: 28),
          const _SectionTitle('Primary Contact'),
          _fieldRow([
            _Field('First name', first),
            _Field('Last name', last),
          ]),
          _fieldRow([
            _Field('Phone', _clean(c['phone']), copy: true),
            _Field('Email', _clean(c['email']), copy: true),
          ]),
        ],
      ),
    );
  }

  Widget _fieldRow(List<_Field> fields) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth < 560) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (final f in fields) Padding(padding: const EdgeInsets.only(bottom: 12), child: f)]);
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < fields.length; i++) ...[
              if (i > 0) const SizedBox(width: 20),
              Expanded(child: fields[i]),
            ],
          ],
        );
      },
    ),
  );

  // ---- Service Locations ----------------------------------------------------
  Widget _serviceLocations(Map<String, dynamic> c) {
    final address = _clean(c['service_location']);
    final cityState = [_clean(c['city']), _clean(c['state'])].whereType<String>().join(', ');
    if (address == null && cityState.isEmpty) {
      return const FlatEmpty(icon: Icons.place_outlined, title: 'No service location', message: 'This customer has no address on file.');
    }
    return Padding(
      padding: const EdgeInsets.all(24),
      child: _fieldRow([
        _Field('Address', address, copy: true),
        _Field('City, state', cityState.isEmpty ? null : cityState),
      ]),
    );
  }

  // ---- Financial Data -------------------------------------------------------
  Widget _financial() {
    final real = _jobs.where((j) => j['is_estimate'] != true).toList();
    num sum(Iterable<Map<String, dynamic>> rows, String k) => rows.fold<num>(0, (a, j) => a + (j[k] is num ? j[k] as num : 0));
    final open = real.where((j) => (j['due_total'] is num ? j['due_total'] as num : 0) > 0 && _clean(j['status']) != 'Write-Off');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FlatStats(stats: [
          FlatStat('Jobs', '${real.length}'),
          FlatStat('Estimates', '${_jobs.length - real.length}'),
          FlatStat('Total job revenue', _money.format(sum(real, 'total_revenue'))),
          FlatStat('Balance due', _money.format(sum(open, 'due_total')), tone: open.isEmpty ? null : DashUi.amber),
        ]),
      ],
    );
  }

  // ---- Jobs & Estimates -----------------------------------------------------
  Widget _jobsTable() {
    if (_jobs.isEmpty) {
      return const FlatEmpty(icon: Icons.work_outline_rounded, title: 'No jobs yet', message: 'Jobs and estimates for this customer will show up here.');
    }
    String date(dynamic v) {
      final d = DateTime.tryParse('${v ?? ''}')?.toLocal();
      return d == null ? '—' : DateFormat.yMMMd().format(d);
    }

    return FlatTable(
      columns: const [
        FlatCol('Number'),
        FlatCol('Status', flex: 3),
        FlatCol('Category', flex: 2),
        FlatCol('Date', flex: 2),
        FlatCol('Total', right: true),
      ],
      onRowTap: (i) {
        final j = _jobs[i];
        context.go('/${j['is_estimate'] == true ? 'estimates' : 'jobs'}/${Uri.encodeComponent('${j['job_id']}')}');
      },
      rows: [
        for (final j in _jobs)
          [
            Text('${j['is_estimate'] == true ? 'Est ' : ''}${j['job_id']}', style: flatCellBold),
            _clean(j['status']) == null ? const Text('—', style: flatCellMuted) : FlatStatus(_clean(j['status'])!, statusColor(_clean(j['status']))),
            Text(_clean(j['category']) ?? '—', style: flatCellStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(date(j['start_date']), style: flatCellStyle),
            Text(_money.format(j['total_revenue'] is num ? j['total_revenue'] : 0), style: flatCellStyle.copyWith(fontFeatures: flatFigures)),
          ],
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Text(text, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: DashUi.ink)),
  );
}

/// A label over a boxed value, like the fields on the Service Fusion form. Read-only; tap to copy when [copy] is on.
class _Field extends StatelessWidget {
  final String label;
  final String? value;
  final bool copy;
  const _Field(this.label, this.value, {this.copy = false});

  @override
  Widget build(BuildContext context) {
    final box = Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(color: DashUi.faint, borderRadius: BorderRadius.circular(6), border: Border.all(color: DashUi.line)),
      child: Text(value ?? '—', style: TextStyle(fontSize: 15, color: value == null ? DashUi.muted : DashUi.ink)),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: DashUi.slate)),
        const SizedBox(height: 6),
        if (copy && value != null)
          Tooltip(
            message: 'Click to copy',
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: value!));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(SnackBar(content: Text('$label copied'), duration: const Duration(seconds: 1), behavior: SnackBarBehavior.floating, width: 220));
              },
              child: box,
            ),
          )
        else
          box,
      ],
    );
  }
}
