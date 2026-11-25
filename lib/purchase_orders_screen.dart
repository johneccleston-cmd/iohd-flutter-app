import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'config/access.dart';
import 'config/auth_session.dart';
import 'purchase_order_detail_screen.dart';
import 'purchase_orders_api.dart';
import 'widgets/app_ribbon.dart';
import 'widgets/dashboard_kit.dart';
import 'widgets/flat_page.dart';

/// Every purchase order, built like Invoices and Payments: what is on order up top, then search, status filters and a
/// sortable table. A row opens the PO's own page (`/inventory/purchase-orders/<id>`), where it is edited and received.
/// The whole list comes in one request (POs are few), so search, filters, sorting and paging all happen here.
class PurchaseOrdersScreen extends StatefulWidget {
  /// A search to start with (the nav bar search sends `?q=` with a vendor's name).
  final String? initialQuery;

  const PurchaseOrdersScreen({super.key, this.initialQuery});

  @override
  State<PurchaseOrdersScreen> createState() => _PurchaseOrdersScreenState();
}

class _PurchaseOrdersScreenState extends State<PurchaseOrdersScreen> with SingleTickerProviderStateMixin {
  static const _filters = [
    ('all', 'All'),
    ('draft', 'Draft'),
    ('open', 'Open'),
    ('late', 'Past due'),
    ('received', 'Received'),
    ('canceled', 'Canceled'),
  ];
  static const _flex = [3, 4, 3, 2, 3, 4, 3, 3]; // the columns, also what the first-load skeleton is shaped like
  static const _tableWidth = 1000.0; // below this the rows stack

  final _searchController = TextEditingController();
  final _scroll = ScrollController();
  final _activity = RibbonActivity();
  late final _rowsIn = AnimationController(vsync: this, duration: const Duration(milliseconds: 460), value: 1);
  final _count = NumberFormat.decimalPattern();
  Timer? _slowTimer;
  int _requestId = 0;

  List<PurchaseOrder> _orders = const [];
  bool _loading = true;
  bool _loaded = false; // a list has arrived at least once (an empty one too)
  bool _slow = false;
  String? _error; // nothing to show: takes the place of the table
  String? _stale; // a reload failed: said above the rows it could not replace
  bool _forbidden = false;

  String _status = 'all';
  String _sort = 'ordered';
  bool _ascending = false;
  int _page = 1;
  int _pageSize = 50;

  final _session = AuthSession.instance;
  bool get _canCreate => _session.can('purchase_orders', AccessAction.create);

  @override
  void initState() {
    super.initState();
    _searchController.text = (widget.initialQuery ?? '').trim();
    PoApi.changes.addListener(_onChanged);
    _load();
  }

  @override
  void didUpdateWidget(PurchaseOrdersScreen old) {
    super.didUpdateWidget(old);
    final q = (widget.initialQuery ?? '').trim();
    if (q.isEmpty || q == (old.initialQuery ?? '').trim()) return;
    setState(() {
      _searchController.text = q;
      _status = 'all'; // the order asked for may not be in the filter left on
      _page = 1;
    });
  }

  @override
  void dispose() {
    PoApi.changes.removeListener(_onChanged);
    _slowTimer?.cancel();
    _searchController.dispose();
    _scroll.dispose();
    _rowsIn.dispose();
    _activity.dispose();
    super.dispose();
  }

  /// A PO was saved or deleted on its own page: this list, still open underneath, catches up.
  void _onChanged() {
    if (mounted) _load();
  }

  Future<void> _load() async {
    final id = ++_requestId;
    _slowTimer?.cancel();
    if (!_loaded) {
      _slowTimer = Timer(const Duration(seconds: 8), () {
        if (mounted && _loading) setState(() => _slow = true);
      });
    } else {
      _activity.setRefreshing(true);
    }
    setState(() {
      _loading = true;
      _slow = false;
      _forbidden = false;
    });
    try {
      final result = await PoApi.list();
      if (!mounted || id != _requestId) return;
      final first = !_loaded;
      setState(() {
        _orders = result.orders;
        _loaded = true;
        _loading = false;
        _error = null;
        _stale = null;
      });
      _slowTimer?.cancel();
      _activity.setRefreshing(false);
      if (!first) {
        _activity.landed();
        return;
      }
      if (MediaQuery.disableAnimationsOf(context)) {
        _rowsIn.value = 1;
      } else {
        _rowsIn.forward(from: 0);
      }
    } on PoApiError catch (e) {
      if (!mounted || id != _requestId) return;
      _slowTimer?.cancel();
      _activity.setRefreshing(false);
      if (e.status == 401) return; // signed out: the router takes over
      setState(() {
        _loading = false;
        _slow = false;
        _forbidden = e.forbidden;
        if (_loaded && _orders.isNotEmpty && !e.forbidden) {
          _stale = e.message;
        } else {
          _error = e.message;
        }
      });
    }
  }

  // ---- what is shown -------------------------------------------------------------------------------------------

  DateTime get _today => poToday();

  bool _inFilter(PurchaseOrder po, String filter) => switch (filter) {
    'draft' => po.isDraft,
    'open' => po.isOpen,
    'late' => po.stage(_today) == PoStage.late,
    'received' => po.isReceived,
    'canceled' => po.isCanceled,
    _ => true,
  };

  String get _query => _searchController.text.trim().toLowerCase();

  List<PurchaseOrder> get _matching {
    final q = _query;
    final words = q.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    return [
      for (final po in _orders)
        if (words.every(po.searchText.contains)) po,
    ];
  }

  List<PurchaseOrder> get _shown {
    final list = [
      for (final po in _matching)
        if (_inFilter(po, _status)) po,
    ];
    int by(PurchaseOrder a, PurchaseOrder b) => switch (_sort) {
      'po' => a.poNumber.toLowerCase().compareTo(b.poNumber.toLowerCase()),
      'vendor' => a.vendor.toLowerCase().compareTo(b.vendor.toLowerCase()),
      'expected' => _dateOrder(a.expectedDate, b.expectedDate),
      'total' => a.total.compareTo(b.total),
      _ => _dateOrder(a.orderDate, b.orderDate),
    };
    list.sort((a, b) {
      final c = by(a, b);
      // Ties keep the newest first, whichever way the column runs.
      return c != 0 ? (_ascending ? c : -c) : b.id.compareTo(a.id);
    });
    // A PO with no expected date goes last however expected is sorted.
    if (_sort == 'expected') list.sort((a, b) => (a.expectedDate == null ? 1 : 0) - (b.expectedDate == null ? 1 : 0));
    return list;
  }

  static int _dateOrder(DateTime? a, DateTime? b) {
    if (a == null && b == null) return 0;
    if (a == null) return -1;
    if (b == null) return 1;
    return a.compareTo(b);
  }

  void _setStatus(String status) {
    if (_status == status) return;
    setState(() {
      _status = status;
      _page = 1;
    });
    _replayRows();
  }

  void _setSort(String key) {
    setState(() {
      // Names read A to Z first; dates and money newest or biggest first, except expected, soonest first.
      _ascending = _sort == key ? !_ascending : const {'po', 'vendor', 'expected'}.contains(key);
      _sort = key;
      _page = 1;
    });
  }

  void _onSearch(String _) => setState(() => _page = 1);

  void _clearSearch() {
    _searchController.clear();
    setState(() => _page = 1);
  }

  void _replayRows() {
    if (_scroll.hasClients) _scroll.jumpTo(0);
    if (!MediaQuery.disableAnimationsOf(context)) _rowsIn.forward(from: 0);
  }

  void _open(PurchaseOrder po) => _go('/inventory/purchase-orders/${po.id}', () => PurchaseOrderDetailScreen(orderId: po.id));

  void _new() => _go('/inventory/purchase-orders/new', () => const PurchaseOrderDetailScreen());

  /// In the app the router moves; on its own (a test) the page is pushed.
  void _go(String location, Widget Function() page) {
    final router = GoRouter.maybeOf(context);
    if (router != null) {
      router.go(location);
    } else {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => page()));
    }
  }

  // ---- cells ---------------------------------------------------------------------------------------------------

  Widget _dateCell(DateTime? d, {TextStyle style = flatCellMuted}) =>
      d == null ? const Text('—', style: flatCellMuted) : Text(poDate.format(d), style: style, maxLines: 1, softWrap: false);

  /// The expected date, and for an order still on its way how far off it is: "In 3 days", or red "5 days late".
  Widget _expectedCell(PurchaseOrder po) {
    final e = po.expectedDate;
    if (e == null) return const Text('—', style: flatCellMuted);
    if (!po.isOpen) return _dateCell(e);
    final late = po.daysLate(_today)!;
    final tone = late > 0 ? DashUi.redText : (late >= -2 ? DashUi.amberText : DashUi.slate);
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: poShortDate.format(e), style: flatCellStyle),
          TextSpan(text: '  ·  ', style: flatCellMuted.copyWith(color: DashUi.muted)),
          TextSpan(
            text: poDueText(late),
            style: flatCellStyle.copyWith(color: tone, fontWeight: late > 0 || late >= -2 ? FontWeight.w700 : FontWeight.w500),
          ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _vendorCell(PurchaseOrder po) =>
      OverflowTooltip(message: po.vendor, child: Text(po.vendor, style: flatCellStyle, maxLines: 1, overflow: TextOverflow.ellipsis));

  Widget _jobCell(PurchaseOrder po) {
    final job = po.jobNumber.trim();
    if (job.isEmpty) return const Text('—', style: flatCellMuted);
    return FlatLink(job, tip: 'Open job $job', onTap: () => context.go('/jobs/${Uri.encodeComponent(job)}'));
  }

  /// "3 items", and while they arrive "4 of 10 in".
  Widget _itemsCell(PurchaseOrder po) {
    if (po.lines.isEmpty) return const Text('—', style: flatCellMuted);
    final n = po.lines.length;
    final text = n == 1 ? '1 item' : '$n items';
    if (!po.isOpen || !po.anyReceived) return Text(text, style: flatCellStyle, maxLines: 1, softWrap: false);
    return Tooltip(
      message: '${poQty(po.unitsReceived)} of ${poQty(po.unitsOrdered)} units received',
      child: Text(text, style: flatCellStyle, maxLines: 1, softWrap: false),
    );
  }

  Widget _totalCell(PurchaseOrder po) => FittedBox(
    fit: BoxFit.scaleDown,
    alignment: Alignment.centerRight,
    child: Text(
      dashMoney(po.total),
      maxLines: 1,
      softWrap: false,
      style: (po.isCanceled ? flatCellMuted : flatCellBold).copyWith(
        fontFeatures: flatFigures,
        decoration: po.isCanceled ? TextDecoration.lineThrough : null,
        decorationColor: DashUi.muted,
      ),
    ),
  );

  Widget _statusCell(PurchaseOrder po) {
    final stage = po.stage(_today);
    final status = FlatStatus(stage.label, stage.tone);
    if (stage == PoStage.partial || (stage == PoStage.late && po.anyReceived)) {
      return Tooltip(message: '${poQty(po.unitsReceived)} of ${poQty(po.unitsOrdered)} units received', child: status);
    }
    return status;
  }

  List<FlatCol> get _columns => [
    FlatCol('PO #', flex: _flex[0], sortKey: 'po'),
    FlatCol('Vendor', flex: _flex[1], sortKey: 'vendor'),
    FlatCol('Job #', flex: _flex[2]),
    FlatCol('Items', flex: _flex[3]),
    FlatCol('Ordered', flex: _flex[4], sortKey: 'ordered'),
    FlatCol('Expected', flex: _flex[5], sortKey: 'expected'),
    FlatCol('Total', flex: _flex[6], right: true, sortKey: 'total'),
    FlatCol('Status', flex: _flex[7]),
  ];

  List<Widget> _cells(PurchaseOrder po) => [
    Text(po.poNumber, style: flatCellBold, maxLines: 1, overflow: TextOverflow.ellipsis),
    _vendorCell(po),
    _jobCell(po),
    _itemsCell(po),
    _dateCell(po.orderDate, style: flatCellStyle),
    _expectedCell(po),
    _totalCell(po),
    FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: _statusCell(po)),
  ];

  /// A row too narrow for the columns: who and how much first, then where it stands, then the rest.
  Widget _compactRow(PurchaseOrder po, int index) {
    final e = po.expectedDate;
    return InkWell(
      mouseCursor: WidgetStateMouseCursor.clickable,
      onTap: () => _open(po),
      hoverColor: DashUi.rowHover,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        decoration: BoxDecoration(
          color: index.isOdd ? DashUi.rowStripe : null,
          border: const Border(top: BorderSide(color: DashUi.rowRule)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: Text(po.vendor, style: flatCellBold, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                const SizedBox(width: 12),
                Expanded(flex: 2, child: Align(alignment: Alignment.centerRight, child: _totalCell(po))),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Text(
                    [po.poNumber, if (po.orderDate != null) poDate.format(po.orderDate!)].join('  ·  '),
                    style: flatCellMuted,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 12),
                _statusCell(po),
              ],
            ),
            if (e != null || po.jobNumber.isNotEmpty || po.lines.isNotEmpty) ...[
              const SizedBox(height: 4),
              Wrap(
                spacing: 16,
                runSpacing: 2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (e != null)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Expected ', style: flatCellMuted),
                        Flexible(child: _expectedCell(po)),
                      ],
                    ),
                  if (po.jobNumber.isNotEmpty) Row(mainAxisSize: MainAxisSize.min, children: [const Text('Job ', style: flatCellMuted), _jobCell(po)]),
                  if (po.lines.isNotEmpty) _itemsCell(po),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ---- the page ------------------------------------------------------------------------------------------------

  Widget _statStrip(bool compact) {
    if (!_loaded) {
      return const FlatStats(
        stats: [FlatStat('On order', '—'), FlatStat('Past due', '—'), FlatStat('Due this week', '—'), FlatStat('Received (30 days)', '—')],
      );
    }
    final today = _today;
    final open = [for (final po in _orders) if (po.isOpen) po];
    final late = [for (final po in open) if ((po.daysLate(today) ?? 0) > 0) po];
    final week = [
      for (final po in open)
        if (po.daysLate(today) case final d? when d <= 0 && d >= -7) po,
    ];
    // Calendar days, not 30 x 24 hours: across a daylight-saving change that lands an hour into the day and drops it.
    final cutoff = DateTime(today.year, today.month, today.day - 30);
    final received = [
      for (final po in _orders)
        if (po.isReceived && !(po.receivedDate ?? po.orderDate ?? DateTime(2000)).isBefore(cutoff)) po,
    ];
    double sum(List<PurchaseOrder> l) => l.fold(0, (s, po) => s + po.total);
    String label(String what, int n) => '$what (${_count.format(n)})';
    return FlatStats(
      stats: [
        FlatStat.counted(label('On order', open.length), sum(open), dashMoney),
        FlatStat.counted(label('Past due', late.length), sum(late), dashMoney, tone: late.isEmpty ? null : DashUi.red),
        FlatStat.counted(label(compact ? 'This week' : 'Due this week', week.length), sum(week), dashMoney),
        // No count here: "Received (30 days) (2)" reads badly. Invoices' "Invoiced (30 days)" has none either.
        FlatStat.counted(compact ? 'Received, 30 days' : 'Received (30 days)', sum(received), dashMoney),
      ],
    );
  }

  Widget _toolbar(List<PurchaseOrder> shown) {
    final matching = _matching;
    final narrowed = _query.isNotEmpty || _status != 'all';
    final countLabel = narrowed
        ? '${_count.format(shown.length)} matching'
        : (shown.length == 1 ? '1 purchase order' : '${_count.format(shown.length)} purchase orders');
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
              onChanged: _onSearch,
              textInputAction: TextInputAction.search,
              style: const TextStyle(fontSize: 14),
              decoration: flatSearchDecoration(
                'Search PO #, vendor, job # or part...',
                onClear: _searchController.text.isEmpty ? null : _clearSearch,
              ),
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (value, label) in _filters)
                FlatFilterChip(
                  label: label,
                  selected: _status == value,
                  count: _loaded && value != 'all' ? matching.where((po) => _inFilter(po, value)).length : null,
                  onSelected: () => _setStatus(value),
                ),
            ],
          ),
          if (_error == null && shown.isNotEmpty) Semantics(liveRegion: true, child: Text(countLabel, style: flatCellMuted)),
        ],
      ),
    );
  }

  Widget _errorState() => FlatEmpty(
    icon: _forbidden ? Icons.lock_outline_rounded : Icons.cloud_off_rounded,
    title: _forbidden ? 'No access to purchase orders' : "Purchase orders didn't load",
    message: _error!,
    action: _forbidden
        ? null
        : FilledButton.icon(
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Try again'),
          ),
  );

  Widget _emptyState() {
    if (_orders.isEmpty) {
      return FlatEmpty(
        icon: Icons.shopping_cart_checkout_rounded,
        title: 'No purchase orders yet',
        message: 'Create a PO when you order parts from a vendor, and receive it here when they arrive.',
        action: _canCreate
            ? FilledButton.icon(onPressed: _new, icon: const Icon(Icons.add_rounded, size: 18), label: const Text('New purchase order'))
            : null,
      );
    }
    if (_query.isNotEmpty) {
      return FlatEmpty(
        icon: Icons.search_off_rounded,
        title: 'No matching purchase orders',
        message: 'Nothing matches "${_searchController.text.trim()}". Try a PO number, vendor, job number or part.',
        action: OutlinedButton(onPressed: _clearSearch, child: const Text('Clear search')),
      );
    }
    final label = _filters.firstWhere((f) => f.$1 == _status).$2.toLowerCase();
    return FlatEmpty(
      icon: Icons.filter_alt_off_outlined,
      title: _status == 'late' ? 'Nothing is past due' : 'No $label purchase orders',
      message: _status == 'late' ? 'Every open order is still within its expected date.' : 'There are no purchase orders with this status right now.',
      action: OutlinedButton(onPressed: () => _setStatus('all'), child: const Text('Show all purchase orders')),
    );
  }

  List<Widget> _content(bool compact, List<PurchaseOrder> page) {
    if (_error != null) return [SliverToBoxAdapter(child: _errorState())];
    if (!_loaded) {
      return [SliverToBoxAdapter(child: FlatLoading(label: 'Loading purchase orders', flex: _flex, compact: compact, slow: _slow))];
    }
    if (page.isEmpty) return [SliverToBoxAdapter(child: _emptyState())];
    final columns = _columns;
    return [
      if (!compact)
        PinnedHeaderSliver(
          child: FlatTableHeader(columns: columns, striped: true, sortKey: _sort, ascending: _ascending, onSort: _setSort),
        ),
      SliverAnimatedOpacity(
        opacity: _loading ? 0.55 : 1,
        duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 160),
        sliver: SliverList.builder(
          itemCount: page.length,
          itemBuilder: (_, i) => flatRowEntrance(
            _rowsIn,
            i,
            compact
                ? _compactRow(page[i], i)
                : FlatTableRow(columns: columns, cells: _cells(page[i]), index: i, striped: true, onTap: () => _open(page[i])),
          ),
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    final totalPages = shown.isEmpty ? 1 : (shown.length / _pageSize).ceil();
    final page = _page.clamp(1, totalPages);
    final first = (page - 1) * _pageSize;
    final rows = shown.skip(first).take(_pageSize).toList();
    return Scaffold(
      backgroundColor: Colors.white,
      body: LayoutBuilder(
        builder: (context, c) {
          final compact = c.maxWidth < MediaQuery.textScalerOf(context).scale(_tableWidth);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PageBanner(
                title: 'Purchase Orders',
                icon: accessIcon('purchase_orders'),
                activity: _activity,
                actions: [
                  if (_canCreate) PageBanner.button(icon: Icons.add_rounded, label: compact ? 'New' : 'New PO', onPressed: _new),
                  PageBanner.refresh(onPressed: _loading ? null : _load),
                ],
              ),
              Expanded(
                child: PageSheet(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: CustomScrollView(
                          controller: _scroll,
                          slivers: [
                            SliverToBoxAdapter(child: _statStrip(compact)),
                            SliverToBoxAdapter(child: _toolbar(shown)),
                            if (_stale != null)
                              SliverToBoxAdapter(
                                child: FlatStaleNotice(
                                  message: '$_stale Showing the last loaded purchase orders.',
                                  busy: _loading,
                                  onRetry: _load,
                                ),
                              ),
                            ..._content(compact, rows),
                          ],
                        ),
                      ),
                      if (_error == null && rows.isNotEmpty)
                        FlatPager(
                          page: page,
                          totalPages: totalPages,
                          total: shown.length,
                          firstRow: first + 1,
                          rowsShown: rows.length,
                          pageSize: _pageSize,
                          busy: _loading,
                          compact: compact,
                          onPage: (p) {
                            setState(() => _page = p);
                            _replayRows();
                          },
                          onPageSize: (s) => setState(() {
                            _pageSize = s;
                            _page = 1;
                          }),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
