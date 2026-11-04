import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import 'config/access.dart';
import 'config/api_config.dart';
import 'config/auth_session.dart';
import 'widgets/app_ribbon.dart';
import 'widgets/dashboard_kit.dart';
import 'widgets/flat_page.dart';
import 'widgets/stripe_mark.dart';

/// Every payment on file, newest first. Read-only. These are the Service Fusion payments (job_payments); one that is a
/// Stripe payment the office entered by hand shows the Stripe details instead (what it was for, Stripe's time, the
/// payment in Stripe). Stripe payments not entered in Service Fusion yet are listed too, marked "Not in SF": no total
/// counts them until they are entered. One whose job Service Fusion already has as paid (its payment entry just has not
/// synced here yet) is marked "Paid in SF". The "Final Invoice Sent, $0 balance" filter lists
/// the jobs Service Fusion still has open with nothing due: their payments, and a "No payment" row for a billed job with
/// none. The pairing and the filter are done by the server (payments_list.js).
class PaymentsScreen extends StatefulWidget {
  const PaymentsScreen({super.key});

  @override
  State<PaymentsScreen> createState() => _PaymentsScreenState();
}

/// A load failure whose message is already fit to show.
class _LoadError implements Exception {
  final String message;

  /// No access (403): trying again cannot help, so no Try again is offered.
  final bool forbidden;
  const _LoadError(this.message, {this.forbidden = false});
}

/// The kinds of payment the server can narrow the list to (?type=), in the order the chips show them.
const _kinds = [
  ('stripe', 'Stripe', 'Paid through Stripe, entered in Service Fusion or not'),
  ('card', 'Card', 'Cards run in Service Fusion'),
  ('check', 'Check', null),
  ('ach', 'ACH', null),
  ('cash', 'Cash', null),
  ('other', 'Other', 'Any payment type Service Fusion lists as Other'),
];

class _PaymentsScreenState extends State<PaymentsScreen> with SingleTickerProviderStateMixin {
  // The columns, also what the first-load skeleton is shaped like.
  static const _flex = [3, 3, 4, 3, 3, 3, 3];

  final TextEditingController _searchController = TextEditingController();
  final _scroll = ScrollController();
  final _activity = RibbonActivity();
  late final _rowsIn = AnimationController(vsync: this, duration: const Duration(milliseconds: 460), value: 1);
  final _date = DateFormat('MMM d, y');
  final _count = NumberFormat.decimalPattern();
  Timer? _debounce;
  Timer? _slowTimer;
  int _requestId = 0; // guards against out-of-order responses

  List<Map<String, dynamic>> _rows = const [];
  Map<String, dynamic> _stats = const {};
  int _page = 1;
  int _wantedPage = 1; // the page last asked for: Try again and Refresh ask for it again
  int _totalPages = 1;
  int _total = 0;
  int _firstRow = 1; // the number of the first row shown, for "1–50 of 10,930"
  int _pageSize = 50;
  bool _onlyFinalZero = false; // just the jobs at Final Invoice Sent with a $0 balance
  String _kind = ''; // '' = every kind of payment, else one of _kinds
  bool _kindSupported = false; // the server lists the type filter in its reply
  bool _filterSupported = false; // the server lists the filter in its reply; an older server would ignore it
  String _sort = 'date';
  bool _ascending = false;
  bool _sortSupported = false; // same: the server lists its sorts
  bool _loading = true;
  bool _slow = false; // the first load has taken long enough to say the server may be waking up
  String? _error; // nothing to show: takes the place of the table
  String? _stale; // a reload failed: said above the rows it could not replace
  bool _forbidden = false;

  // What the rows on screen were loaded for. The controls above can already say something else while a load is out.
  String? _shownView;
  String _shownQuery = '';
  bool _shownFinalZero = false;
  String _shownKind = '';

  @override
  void initState() {
    super.initState();
    _load(1);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _slowTimer?.cancel();
    _searchController.dispose();
    _scroll.dispose();
    _rowsIn.dispose();
    _activity.dispose();
    super.dispose();
  }

  bool get _defaultSort => _sort == 'date' && !_ascending;

  Future<void> _load(int page) async {
    final id = ++_requestId;
    final q = _searchController.text.trim();
    final finalZero = _onlyFinalZero;
    final kind = _kind;
    final view = '$q|$finalZero|$kind|$_pageSize|$_sort|$_ascending';
    _wantedPage = page;
    _slowTimer?.cancel();
    if (_rows.isEmpty) {
      _slowTimer = Timer(const Duration(seconds: 8), () {
        if (mounted && _loading) setState(() => _slow = true);
      });
    } else {
      _activity.setRefreshing(true);
    }
    setState(() {
      _loading = true;
      _slow = false;
      _error = null;
      _forbidden = false;
    });
    try {
      final uri = Uri.parse('$kApiBaseUrl/api/payments').replace(queryParameters: {
        'q': q,
        if (finalZero) 'show': 'final_zero',
        if (kind.isNotEmpty) 'type': kind,
        if (!_defaultSort) ...{'sort': _sort, 'dir': _ascending ? 'asc' : 'desc'},
        'page': '$page',
        'limit': '$_pageSize',
      });
      final res = await http.get(uri, headers: AuthSession.instance.headers(json: false)).timeout(const Duration(seconds: 40));
      if (!mounted || id != _requestId) return;
      _slowTimer?.cancel();
      _activity.setRefreshing(false);
      if (res.statusCode == 401) {
        AuthSession.instance.logout(); // sends the app back to the sign-in screen
        return;
      }
      if (res.statusCode == 403) throw const _LoadError("Your account doesn't have access to payments.", forbidden: true);
      if (res.statusCode != 200) throw _LoadError('Could not load payments (server error ${res.statusCode}).');
      final data = json.decode(res.body) as Map<String, dynamic>;
      final rows = List<Map<String, dynamic>>.from(data['data'] ?? const []);
      final total = (data['total'] as num?)?.toInt() ?? 0;
      final totalPages = (data['totalPages'] as num?)?.toInt() ?? 1;
      // Past the end: the list got shorter since this page was opened (Stripe payments got entered and paired). Show
      // the last page rather than "no payments".
      if (rows.isEmpty && total > 0 && page > totalPages) {
        unawaited(_load(totalPages));
        return;
      }
      // A reload of the same page just updates it; anything else is a new list, read from its top.
      final newList = view != _shownView || page != _page;
      setState(() {
        _rows = rows;
        _stats = Map<String, dynamic>.from(data['stats'] ?? const {});
        _total = total;
        _totalPages = totalPages;
        _firstRow = (page - 1) * _pageSize + 1;
        _filterSupported = (data['filters'] as List?)?.contains('final_zero') ?? false;
        _kindSupported = (data['filters'] as List?)?.contains('type') ?? false;
        _sortSupported = (data['sorts'] as List?)?.isNotEmpty ?? false;
        _page = page;
        _shownView = view;
        _shownQuery = q;
        _shownFinalZero = finalZero;
        _shownKind = kind;
        _stale = null;
        _loading = false;
      });
      if (!newList) {
        _activity.landed();
        return;
      }
      if (_scroll.hasClients) _scroll.jumpTo(0);
      if (MediaQuery.disableAnimationsOf(context)) {
        _rowsIn.value = 1;
      } else {
        _rowsIn.forward(from: 0);
      }
    } catch (e) {
      if (!mounted || id != _requestId) return;
      _slowTimer?.cancel();
      _activity.setRefreshing(false);
      // Never the raw exception: it can carry the request URL.
      final message = switch (e) {
        _LoadError(:final message) => message,
        TimeoutException() => 'The server is taking too long to respond. It may be waking up. Try again in a moment.',
        http.ClientException() => "Couldn't reach the server. Check your connection and try again.",
        _ => 'Could not load payments. The server sent a reply the app could not read.',
      };
      final forbidden = e is _LoadError && e.forbidden;
      setState(() {
        _loading = false;
        _slow = false;
        _forbidden = forbidden;
        // The rows on screen are still the list that was asked for, so they stay. Rows from another search or filter
        // would pass for the answer to this one.
        if (view == _shownView && _rows.isNotEmpty && !forbidden) {
          _stale = message;
        } else {
          _error = message;
          _stale = null;
        }
      });
    }
  }

  void _onSearchChanged(String _) {
    setState(() {}); // the clear button comes and goes with the text
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _load(1));
  }

  void _searchNow() {
    _debounce?.cancel();
    _load(1);
  }

  void _clearSearch() {
    _searchController.clear();
    _searchNow();
  }

  void _setFilter(bool onlyFinalZero) {
    if (_onlyFinalZero == onlyFinalZero) return;
    setState(() => _onlyFinalZero = onlyFinalZero);
    _load(1);
  }

  void _setKind(String kind) {
    if (_kind == kind) return;
    setState(() => _kind = kind);
    _load(1);
  }

  void _setSort(String key) {
    setState(() {
      _ascending = _sort == key ? !_ascending : key == 'customer'; // names read A to Z first, dates and money biggest first
      _sort = key;
    });
    _load(1);
  }

  void _setPageSize(int size) {
    if (size == _pageSize) return;
    setState(() => _pageSize = size);
    _load(1);
  }

  Future<void> _openStripe(String intent) async {
    final messenger = ScaffoldMessenger.of(context);
    final opened = await launchUrl(stripeDashboardUri(intent), mode: LaunchMode.externalApplication).catchError((_) => false);
    if (opened) return;
    messenger.showSnackBar(
      const SnackBar(behavior: SnackBarBehavior.floating, backgroundColor: DashUi.red, content: Text("Couldn't open Stripe. Try again.")),
    );
  }

  /// A search or the filter is narrowing the list.
  bool get _narrowed => _searchController.text.trim().isNotEmpty || _onlyFinalZero || _kind.isNotEmpty;

  double _n(Object? v) => double.tryParse('${v ?? ''}') ?? 0;

  String _day(Object? v) {
    final d = DateTime.tryParse('${v ?? ''}');
    return d == null ? '' : _date.format(d.toUtc()); // dates are stored as UTC midnight
  }

  bool _isStripeOnly(Map<String, dynamic> p) => p['source'] == 'stripe';

  /// A Stripe-only row whose job Service Fusion already has as paid: its payment entry is in Service Fusion but has not
  /// synced here yet. Nothing to enter, but in no total until it does.
  bool _settledInSf(Map<String, dynamic> p) => _isStripeOnly(p) && p['sf_settled'] == true;

  bool _hasStripe(Map<String, dynamic> p) => '${p['stripe_id'] ?? ''}'.isNotEmpty;

  /// A row for a billed job with no payment at all (only under the Final Invoice Sent filter).
  bool _noPayment(Map<String, dynamic> p) => p['source'] == 'job';

  /// The date shown: Stripe's own time when the row has it (a real moment, shown in local time), else Service Fusion's
  /// date (stored as UTC midnight).
  String _rowDay(Map<String, dynamic> p) {
    if (!_hasStripe(p)) return _day(p['received_on']);
    final d = DateTime.tryParse('${p['stripe_received_on'] ?? ''}');
    return d == null ? _day(p['received_on']) : _date.format(d.toLocal());
  }

  /// The date cell. A Stripe payment the office entered on another day says so: the totals above count it on Service
  /// Fusion's day, not the day shown.
  Widget _dateCell(Map<String, dynamic> p) {
    if (_noPayment(p)) return const Text('—', style: flatCellMuted);
    final shown = _rowDay(p);
    final text = Text(shown, style: flatCellBold);
    if (!_hasStripe(p) || _isStripeOnly(p)) return text;
    final sfDay = _day(p['received_on']);
    if (sfDay.isEmpty || sfDay == shown) return text;
    return Tooltip(message: 'Paid through Stripe on $shown. Entered in Service Fusion on $sfDay, the day the totals count it.', child: text);
  }

  /// Who paid, in full on hover when the column cuts it short.
  Widget _customerCell(Map<String, dynamic> p) {
    // A Stripe payment with no job on file still names who paid, from its memo.
    final customer = '${p['customer'] ?? ''}'.isNotEmpty ? '${p['customer']}' : stripeMemoCustomer(p['stripe_memo']);
    if (customer.isEmpty) return const Text('No job on file', style: flatCellMuted, maxLines: 1, overflow: TextOverflow.ellipsis);
    return Tooltip(
      message: customer,
      waitDuration: const Duration(milliseconds: 400),
      child: Text(customer, style: flatCellBold, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }

  /// The amount, on one line: a very large one shrinks a little in a narrow window rather than wrap.
  Widget _amountCell(Map<String, dynamic> p) {
    if (_noPayment(p)) return const Text('—', textAlign: TextAlign.right, style: flatCellMuted);
    final amount = _n(p['amount']);
    final color = amount < 0
        ? DashUi.redText
        : (_isStripeOnly(p) ? kStripeText : ('${p['transaction_type']}'.toLowerCase() == 'void' ? DashUi.slate : DashUi.ink));
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerRight,
      child: Text(dashMoney(amount), maxLines: 1, softWrap: false, style: flatCellBold.copyWith(fontFeatures: flatFigures, color: color)),
    );
  }

  /// What the job was billed, beside what was paid.
  Widget _jobTotalCell(Map<String, dynamic> p) => FittedBox(
    fit: BoxFit.scaleDown,
    alignment: Alignment.centerRight,
    child: Text(dashMoney(_n(p['job_total'])), maxLines: 1, softWrap: false, style: flatCellStyle.copyWith(fontFeatures: flatFigures)),
  );

  /// How it was paid: the Stripe mark and what the payment was for, or Service Fusion's payment type.
  Widget _method(Map<String, dynamic> p) {
    if (_noPayment(p)) return const Text('—', style: flatCellMuted);
    final type = '${p['payment_type'] ?? ''}'.trim();
    if (p['via_stripe'] != true) {
      if (type.isEmpty) return const Text('—', style: flatCellMuted);
      return Tooltip(
        message: type,
        waitDuration: const Duration(milliseconds: 400),
        child: Text(type, style: flatCellStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
      );
    }
    final refund = _n(p['amount']) < 0 || '${p['transaction_type']}'.toLowerCase() == 'refund';
    final tip = _settledInSf(p)
        ? 'Paid through Stripe. Service Fusion has the job paid, but its payment entry has not synced here yet, so no total counts it.'
        : _isStripeOnly(p)
        ? 'Paid through Stripe. Not entered in Service Fusion yet, so no total counts it.'
        : _hasStripe(p)
        ? 'Paid through Stripe. Entered in Service Fusion as ${type.isEmpty ? 'a payment' : type}.'
        : 'Paid through Stripe. Entered in Service Fusion as ${type.isEmpty ? 'a payment' : type}; no Stripe record to show.';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        StripeMark(size: 20, tip: tip),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            _hasStripe(p) ? stripePaymentLabel(p['stripe_memo'], refund: refund) : 'Stripe',
            style: flatCellStyle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  /// What the office types as the reference for a Stripe payment copied from the payment sheet: the sheet's name, not a
  /// reference to anything.
  static const _sheetName = 'Job Payment Database';

  /// The reference: the Stripe payment (opens it in Stripe) when there is one, else Service Fusion's reference. The
  /// payment sheet's name is not a reference, so it shows as a dash that says where the entry came from.
  Widget _reference(Map<String, dynamic> p) {
    final intent = '${p['stripe_intent'] ?? ''}'.trim();
    if (intent.isNotEmpty) return FlatLink(intent, tip: 'Open this payment in Stripe', onTap: () => _openStripe(intent));
    final ref = '${p['reference_number'] ?? ''}'.trim();
    if (ref.isEmpty) return const Text('—', style: flatCellMuted);
    if (ref.toLowerCase() == _sheetName.toLowerCase()) {
      return const Tooltip(
        message: 'Copied into Service Fusion from the payment sheet ("$_sheetName"). No Stripe record to link to.',
        child: Text('—', style: flatCellMuted),
      );
    }
    return Text(ref, style: flatCellMuted, maxLines: 1, overflow: TextOverflow.ellipsis);
  }

  /// Receipt-style label for the status column: a refund or void reads differently from money received, and so does a
  /// negative entry that is not a refund (a correction typed as a payment). Text tones, so they stay readable on the
  /// striped rows.
  (String, Color) _status(String type, double amount) {
    switch (type.toLowerCase()) {
      case 'refund':
        return ('Refund', DashUi.amberText);
      case 'void':
        return ('Void', DashUi.slate);
      default:
        return amount < 0 ? ('Adjustment', DashUi.amberText) : ('Paid', DashUi.emeraldText);
    }
  }

  Widget _statusCell(Map<String, dynamic> p) {
    if (_noPayment(p)) {
      return const Tooltip(
        message: 'Service Fusion shows nothing due on this job, but no payment is on file for it.',
        child: FlatStatus('No payment', DashUi.slate),
      );
    }
    if (_settledInSf(p)) {
      return const Tooltip(
        message: 'Service Fusion has this job paid. Its payment entry has not synced here yet, so there is nothing to enter, '
            'but no total counts it until it does.',
        child: FlatStatus('Paid in SF', DashUi.slate),
      );
    }
    if (_isStripeOnly(p)) {
      return const Tooltip(
        message: 'Paid through Stripe but not entered in Service Fusion yet, so no total counts it.',
        child: FlatStatus('Not in SF', kStripeText),
      );
    }
    final (label, color) = _status('${p['transaction_type'] ?? ''}', _n(p['amount']));
    return FlatStatus(label, color);
  }

  List<FlatCol> get _columns => [
    FlatCol('Date', flex: _flex[0], sortKey: 'date'),
    FlatCol('Job #', flex: _flex[1]),
    FlatCol('Customer', flex: _flex[2], sortKey: 'customer'),
    FlatCol('Method', flex: _flex[3]),
    if (_shownFinalZero) FlatCol('Job total', flex: _flex[4], right: true) else FlatCol('Reference', flex: _flex[4]),
    FlatCol('Amount', flex: _flex[5], right: true, sortKey: 'amount'),
    FlatCol('Status', flex: _flex[6]),
  ];

  List<Widget> _cells(Map<String, dynamic> p) => [
    _dateCell(p),
    _JobLink('${p['job_id'] ?? ''}', onFile: p['job_on_file'] != false),
    _customerCell(p),
    _method(p),
    if (_shownFinalZero) _jobTotalCell(p) else _reference(p),
    _amountCell(p),
    // Shrinks a little in a narrow window rather than overflow the column.
    FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: _statusCell(p)),
  ];

  /// A row too narrow for the columns: who and how much first, then the rest under it, so nothing hides off to the side.
  Widget _compactRow(Map<String, dynamic> p, int index) {
    final jobId = '${p['job_id'] ?? ''}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      decoration: BoxDecoration(
        color: index.isOdd ? DashUi.faint : null,
        border: const Border(top: BorderSide(color: DashUi.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(flex: 3, child: Align(alignment: Alignment.centerLeft, child: _customerCell(p))),
              const SizedBox(width: 12),
              Expanded(flex: 2, child: Align(alignment: Alignment.centerRight, child: _amountCell(p))),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Wrap(spacing: 12, children: [_dateCell(p), if (jobId.isNotEmpty) _JobLink(jobId, onFile: p['job_on_file'] != false)]),
              ),
              const SizedBox(width: 12),
              _statusCell(p),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Flexible(child: _method(p)),
              const SizedBox(width: 16),
              Flexible(
                child: _shownFinalZero
                    ? Text('Job total ${dashMoney(_n(p['job_total']))}', style: flatCellMuted, maxLines: 1, overflow: TextOverflow.ellipsis)
                    : _reference(p),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statStrip() {
    String count(double v) => _count.format(v.round());
    FlatStat stat(String label, String key, String Function(double) format) =>
        _stats.isEmpty ? FlatStat(label, '—') : FlatStat.counted(label, _n(_stats[key]), format);
    return FlatStats(
      stats: [
        stat('Collected today', 'today', dashMoney),
        stat('Collected this month', 'month', dashMoney),
        stat('Payments this month', 'monthCount', count),
      ],
    );
  }

  String get _countLabel {
    if (_narrowed) return '${_count.format(_total)} matching';
    return _total == 1 ? '1 payment' : '${_count.format(_total)} payments';
  }

  Widget _toolbar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
      child: Wrap(
        spacing: 16,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 340),
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              onSubmitted: (_) => _searchNow(),
              textInputAction: TextInputAction.search,
              style: const TextStyle(fontSize: 14),
              decoration: flatSearchDecoration(
                'Search customer, job # or reference...',
                onClear: _searchController.text.isEmpty ? null : _clearSearch,
              ),
            ),
          ),
          if (_filterSupported)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FlatFilterChip(label: 'All payments', selected: !_onlyFinalZero, onSelected: () => _setFilter(false)),
                FlatFilterChip(
                  label: 'Final Invoice Sent, \$0 balance',
                  tooltip: 'Jobs Service Fusion still has at Final Invoice Sent with nothing due',
                  selected: _onlyFinalZero,
                  onSelected: () => _setFilter(true),
                ),
              ],
            ),
          if (_kindSupported)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FlatFilterChip(label: 'All types', selected: _kind.isEmpty, onSelected: () => _setKind('')),
                for (final (key, label, tip) in _kinds)
                  FlatFilterChip(label: label, tooltip: tip, selected: _kind == key, onSelected: () => _setKind(key)),
              ],
            ),
          // No count without rows: a failed load has nothing to count, and an empty list says so itself.
          if (_error == null && _rows.isNotEmpty)
            Semantics(liveRegion: true, child: Text(_countLabel, style: flatCellMuted)),
        ],
      ),
    );
  }

  Widget _errorState() {
    return FlatEmpty(
      icon: _forbidden ? Icons.lock_outline_rounded : Icons.cloud_off_rounded,
      title: _forbidden ? 'No access to payments' : "Payments didn't load",
      message: _error!,
      action: _forbidden
          ? null
          : FilledButton.icon(
              onPressed: _loading ? null : () => _load(_wantedPage),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Try again'),
            ),
    );
  }

  Widget _emptyState() {
    if (_shownQuery.isNotEmpty) {
      return FlatEmpty(
        icon: Icons.search_off_rounded,
        title: 'No matching payments',
        message: 'Nothing matches "$_shownQuery". Try a different customer name, job number or reference.',
        action: OutlinedButton(onPressed: _clearSearch, child: const Text('Clear search')),
      );
    }
    if (_shownKind.isNotEmpty) {
      final label = _kinds.firstWhere((k) => k.$1 == _shownKind).$2;
      return FlatEmpty(
        icon: Icons.payments_outlined,
        title: 'No $label payments',
        message: _shownFinalZero ? 'No $label payments on the jobs at Final Invoice Sent with a \$0 balance.' : 'No payments of this type on file.',
        action: OutlinedButton(onPressed: () => _setKind(''), child: const Text('Show all types')),
      );
    }
    if (_shownFinalZero) {
      return FlatEmpty(
        icon: Icons.payments_outlined,
        title: 'No jobs to show',
        message: 'No job is at Final Invoice Sent with a \$0 balance.',
        action: OutlinedButton(onPressed: () => _setFilter(false), child: const Text('Show all payments')),
      );
    }
    return const FlatEmpty(icon: Icons.payments_outlined, title: 'No payments yet', message: 'Payments show here once they are received.');
  }

  /// What sits under the toolbar, as slivers so the table's header can stay pinned while the rows scroll under it.
  List<Widget> _content(bool compact) {
    if (_error != null) return [SliverToBoxAdapter(child: _errorState())];
    if (_rows.isEmpty) return [SliverToBoxAdapter(child: _loading ? FlatLoading(label: 'Loading payments', flex: _flex, compact: compact, slow: _slow) : _emptyState())];
    final columns = _columns;
    return [
      if (!compact)
        PinnedHeaderSliver(
          child: FlatTableHeader(
            columns: columns,
            striped: true,
            sortKey: _sort,
            ascending: _ascending,
            onSort: _sortSupported ? _setSort : null,
          ),
        ),
      // Rows being replaced fade back a little, so a slow search does not look finished.
      SliverAnimatedOpacity(
        opacity: _loading ? 0.55 : 1,
        duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 160),
        sliver: SliverList.builder(
          itemCount: _rows.length,
          itemBuilder: (_, i) => flatRowEntrance(
            _rowsIn,
            i,
            compact ? _compactRow(_rows[i], i) : FlatTableRow(columns: columns, cells: _cells(_rows[i]), index: i, striped: true),
          ),
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: LayoutBuilder(
        builder: (context, c) {
          // Larger text needs the room too, so the columns give way sooner.
          final compact = c.maxWidth < MediaQuery.textScalerOf(context).scale(FlatTable.minWidth);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PageBanner(
                title: 'Payments',
                icon: accessIcon('payments'),
                activity: _activity,
                actions: [PageBanner.refresh(onPressed: _loading ? null : () => _load(_wantedPage))],
              ),
              Expanded(
                child: CustomScrollView(
                  controller: _scroll,
                  slivers: [
                    SliverToBoxAdapter(child: _statStrip()),
                    SliverToBoxAdapter(child: _toolbar()),
                    if (_stale != null)
                      SliverToBoxAdapter(
                        child: FlatStaleNotice(
                          message: '$_stale Showing the last loaded payments.',
                          busy: _loading,
                          onRetry: () => _load(_wantedPage),
                        ),
                      ),
                    ..._content(compact),
                  ],
                ),
              ),
              if (_error == null && _rows.isNotEmpty)
                FlatPager(
                  page: _page,
                  totalPages: _totalPages,
                  total: _total,
                  firstRow: _firstRow,
                  rowsShown: _rows.length,
                  pageSize: _pageSize,
                  busy: _loading,
                  compact: compact,
                  onPage: _load,
                  onPageSize: _setPageSize,
                ),
            ],
          );
        },
      ),
    );
  }
}

/// The job number as a link to that job. A payment with no job on file shows a dash, and one whose job is not in the app
/// shows the number as plain text (there is no job page to open).
class _JobLink extends StatelessWidget {
  final String jobId;
  final bool onFile;
  const _JobLink(this.jobId, {this.onFile = true});

  @override
  Widget build(BuildContext context) {
    if (jobId.isEmpty) return const Text('—', style: flatCellMuted);
    if (!onFile) {
      return Tooltip(message: 'Job $jobId is not in the app, so there is no job page to open.', child: Text(jobId, style: flatCellMuted));
    }
    return FlatLink(jobId, tip: 'Open job $jobId', onTap: () => context.go('/jobs/${Uri.encodeComponent(jobId)}'));
  }
}
