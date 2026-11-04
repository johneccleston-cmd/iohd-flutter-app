import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../config/access.dart';
import '../config/api_config.dart';
import '../config/auth_session.dart';
import '../theme/app_theme.dart';
import 'dashboard_kit.dart';

// The search in the top bar: as you type, a dropdown lists the customers, jobs, estimates, invoices, purchase orders and
// vendors that match, and picking one opens it. It reads the same endpoints those screens use. Customers, jobs and
// estimates have pages of their own; invoices and purchase orders have none, so they open their list narrowed to that
// one. There is no vendor table yet (the Vendors screen is sample data), so vendors are the names on real purchase
// orders, and open those orders.

const int _minLength = 2;
const int _perSection = 4;
const Duration _debounce = Duration(milliseconds: 250);
const Duration _timeout = Duration(seconds: 15);
const Duration _ordersFresh = Duration(minutes: 1); // the purchase orders endpoint can't search, so the list is reused

enum SearchKind {
  customer('customers', 'Customers', 'customers', '/customers', '/api/customers'),
  job('jobs', 'Jobs', 'jobs', '/jobs', '/api/jobs'),
  estimate('estimates', 'Estimates', 'estimates', '/estimates', '/api/estimates'),
  invoice('invoices', 'Invoices', 'invoices', '/invoices', '/api/invoices'),
  purchaseOrder('purchase_orders', 'Purchase Orders', 'purchase orders', '/inventory/purchase-orders', '/api/purchase-orders'),
  vendor('vendors', 'Vendors', 'vendors', '/inventory/purchase-orders', '/api/purchase-orders');

  final String accessKey;
  final String heading;
  final String noun;
  final String route;
  final String api;
  const SearchKind(this.accessKey, this.heading, this.noun, this.route, this.api);
}

/// One line in the dropdown: a record, or (with [more]) the link to the full list when there are too many to show.
class SearchRow {
  final SearchKind kind;
  final String title;
  final String subtitle;
  final String status;
  final String route;
  final Object? extra; // the row from the list, so the record's page can draw at once
  final bool more;

  const SearchRow({
    required this.kind,
    required this.title,
    required this.route,
    this.subtitle = '',
    this.status = '',
    this.extra,
    this.more = false,
  });
}

/// What the user chose: a record's [route], or no route to search the lists for [query] instead.
class SearchPick {
  final String query;
  final String? route;
  final Object? extra;
  const SearchPick(this.query, {this.route, this.extra});
}

String _text(Object? v) => (v ?? '').toString().trim();

SearchRow _customerRow(Map<String, dynamic> r) {
  final name = _text(r['customer_name']);
  final contact = _text(r['primary_contact']);
  final place = [_text(r['city']), _text(r['state'])].where((s) => s.isNotEmpty).join(', ');
  return SearchRow(
    kind: SearchKind.customer,
    title: name.isEmpty ? 'Unnamed customer' : name,
    subtitle: [
      if (contact.isNotEmpty && contact.toLowerCase() != name.toLowerCase()) contact,
      _text(r['phone']),
      place.isEmpty ? _text(r['service_location']) : place,
    ].where((s) => s.isNotEmpty).join(' · '),
    route: '/customers/${Uri.encodeComponent(_text(r['id']))}',
    extra: r,
  );
}

SearchRow _recordRow(SearchKind kind, Map<String, dynamic> r) {
  final id = _text(r['job_id']);
  final name = _text(r['customer_name']);
  return SearchRow(
    kind: kind,
    title: name.isEmpty ? 'No customer name' : name,
    subtitle: ['#$id', _text(r['location'])].where((s) => s.isNotEmpty).join(' · '),
    status: _text(r['status']),
    route: '${kind.route}/${Uri.encodeComponent(id)}',
    extra: r,
  );
}

SearchRow _invoiceRow(Map<String, dynamic> r) {
  final number = _text(r['number']);
  final name = _text(r['customer']);
  final total = double.tryParse(_text(r['total']));
  return SearchRow(
    kind: SearchKind.invoice,
    title: name.isEmpty ? 'No customer on file' : name,
    subtitle: [
      if (number.isNotEmpty) '#$number',
      if (total != null) dashMoney(total),
      _text(r['po_number']),
    ].where((s) => s.isNotEmpty).join(' · '),
    status: r['is_paid'] == true ? 'Paid' : (r['overdue'] == true ? 'Overdue' : 'Unpaid'),
    route: '${SearchKind.invoice.route}?q=${Uri.encodeQueryComponent(number)}',
  );
}

SearchRow _orderRow(Map<String, dynamic> r) {
  final number = _text(r['poNumber']);
  final total = (r['total'] as num?)?.toDouble();
  return SearchRow(
    kind: SearchKind.purchaseOrder,
    title: number,
    subtitle: [_text(r['vendor']), if (total != null) dashMoney(total)].where((s) => s.isNotEmpty).join(' · '),
    status: _text(r['status']),
    route: '${SearchKind.purchaseOrder.route}?q=${Uri.encodeQueryComponent(number)}',
  );
}

SearchRow _vendorRow(String name, int orders) => SearchRow(
      kind: SearchKind.vendor,
      title: name,
      subtitle: orders == 1 ? '1 purchase order' : '$orders purchase orders',
      route: '${SearchKind.vendor.route}?q=${Uri.encodeQueryComponent(name)}',
    );

class _Part {
  final SearchKind kind;
  final List<SearchRow> rows;
  final bool exact; // holds the record whose number is exactly what was typed
  const _Part(this.kind, this.rows, {this.exact = false});
}

/// The search itself, shared by the bar's dropdown and the narrow window's search box: debounces typing, drops answers
/// to a query that has since changed, and keeps which row is highlighted.
class GlobalSearch extends ChangeNotifier {
  String _query = '';
  List<SearchRow> rows = const [];
  bool loading = false;
  bool failed = false; // at least one list didn't answer
  int highlight = 0;
  bool byKeyboard = false; // the highlight moved by arrow key, so it should scroll into view

  Timer? _timer;
  Future<void>? _inFlight;
  int _seq = 0;
  bool _disposed = false;
  Future<List<Map<String, dynamic>>>? _orders;
  DateTime? _ordersAt;

  String get query => _query;
  bool get active => _query.length >= _minLength;
  SearchRow? get highlighted => highlight < rows.length ? rows[highlight] : null;

  void update(String text) {
    final q = text.trim();
    if (q == _query) return;
    _query = q;
    _timer?.cancel();
    _seq++;
    failed = false;
    if (active) {
      loading = true;
      _timer = Timer(_debounce, _run);
    } else {
      loading = false;
      rows = const [];
      highlight = 0;
    }
    notifyListeners();
  }

  /// Enter: searches now if typing is still being waited on, then answers with the highlighted row, if any.
  Future<SearchRow?> submit() async {
    if (_timer?.isActive ?? false) {
      _timer!.cancel();
      await _run();
    } else if (loading) {
      await _inFlight;
    }
    return highlighted;
  }

  void retry() {
    if (active) _run();
  }

  void move(int by) {
    if (rows.isEmpty) return;
    highlight = (highlight + by) % rows.length;
    byKeyboard = true;
    notifyListeners();
  }

  void hover(int index) {
    if (index == highlight) return;
    highlight = index;
    byKeyboard = false;
    notifyListeners();
  }

  /// Up and Down, from whichever text field drives this search.
  KeyEventResult handleArrows(KeyEvent event) {
    if (event is KeyUpEvent || rows.isEmpty) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      move(1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      move(-1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _run() => _inFlight = _fetchAll();

  Future<void> _fetchAll() async {
    final seq = ++_seq;
    final q = _query;
    loading = true;
    failed = false;
    notifyListeners();

    // A number is most likely a job, so jobs lead; anything else is most likely a customer.
    final numeric = RegExp(r'^\d+$').hasMatch(q);
    final order = numeric
        ? const [SearchKind.job, SearchKind.estimate, SearchKind.invoice, SearchKind.customer, SearchKind.purchaseOrder, SearchKind.vendor]
        : const [SearchKind.customer, SearchKind.job, SearchKind.estimate, SearchKind.invoice, SearchKind.purchaseOrder, SearchKind.vendor];
    final session = AuthSession.instance;
    final kinds = [
      for (final k in order)
        // A vendor opens its purchase orders, so it takes both.
        if (session.canView(k.accessKey) && (k != SearchKind.vendor || session.canView(SearchKind.purchaseOrder.accessKey))) k,
    ];
    final parts = await Future.wait(kinds.map((k) => _fetch(k, q)));
    if (_disposed || seq != _seq) return;

    final answered = parts.whereType<_Part>().toList();
    // Stable, so the record with exactly this number comes first and the lists otherwise keep their order.
    final ranked = [...answered.where((p) => p.exact), ...answered.where((p) => !p.exact)];
    rows = [for (final p in ranked) ...p.rows];
    failed = answered.length < parts.length;
    loading = false;
    highlight = 0;
    byKeyboard = false;
    notifyListeners();
  }

  /// The decoded answer; null when the account may not read it. Throws when the server didn't answer properly.
  Future<Map<String, dynamic>?> _get(Uri uri) async {
    final res = await http.get(uri, headers: AuthSession.instance.headers(json: false)).timeout(_timeout);
    if (res.statusCode == 401) {
      AuthSession.instance.logout();
      return null;
    }
    if (res.statusCode == 403) return null;
    if (res.statusCode != 200) throw Exception('Server error (${res.statusCode})');
    return json.decode(res.body) as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> _loadOrders() async {
    final body = await _get(Uri.parse('$kApiBaseUrl${SearchKind.purchaseOrder.api}'));
    return List<Map<String, dynamic>>.from(body?['purchaseOrders'] ?? const []);
  }

  /// Purchase orders and vendors share one list, so both sections cost one request, and typing costs none for a minute.
  Future<List<Map<String, dynamic>>> _allOrders() {
    final at = _ordersAt;
    if (_orders == null || at == null || DateTime.now().difference(at) > _ordersFresh) {
      _ordersAt = DateTime.now();
      _orders = _loadOrders();
    }
    return _orders!;
  }

  /// One list's matches; null when it didn't answer. An account that may not read a list just gets none from it.
  Future<_Part?> _fetch(SearchKind kind, String q) async {
    try {
      return switch (kind) {
        SearchKind.purchaseOrder => _orderPart(q, await _allOrders()),
        SearchKind.vendor => _vendorPart(q, await _allOrders()),
        _ => await _listPart(kind, q),
      };
    } catch (_) {
      _orders = null; // Try again asks the server, not a saved failure
      return null;
    }
  }

  Future<_Part> _listPart(SearchKind kind, String q) async {
    final uri = Uri.parse('$kApiBaseUrl${kind.api}').replace(queryParameters: {'q': q, 'page': '1', 'limit': '$_perSection'});
    final body = await _get(uri);
    if (body == null) return _Part(kind, const []);
    final data = List<Map<String, dynamic>>.from(body['data'] ?? const []);
    final total = (body['total'] as num?)?.toInt() ?? data.length;

    final number = switch (kind) { SearchKind.customer => null, SearchKind.invoice => 'number', _ => 'job_id' };
    bool isExact(Map<String, dynamic> r) => number != null && _text(r[number]).toLowerCase() == q.toLowerCase();
    final exact = data.where(isExact).toList();
    final hits = [...exact, ...data.where((r) => !isExact(r))];
    return _section(
      kind,
      q,
      [
        for (final r in hits)
          switch (kind) {
            SearchKind.customer => _customerRow(r),
            SearchKind.invoice => _invoiceRow(r),
            _ => _recordRow(kind, r),
          },
      ],
      total,
      exact: exact.isNotEmpty,
    );
  }

  _Part _orderPart(String q, List<Map<String, dynamic>> orders) {
    final needle = q.toLowerCase();
    bool isExact(Map<String, dynamic> r) => _text(r['poNumber']).toLowerCase() == needle;
    final found = [
      for (final r in orders)
        if ('${_text(r['poNumber'])} ${_text(r['vendor'])}'.toLowerCase().contains(needle)) r,
    ];
    final exact = found.where(isExact).toList();
    final hits = [...exact, ...found.where((r) => !isExact(r))].take(_perSection);
    return _section(SearchKind.purchaseOrder, q, [for (final r in hits) _orderRow(r)], found.length, exact: exact.isNotEmpty);
  }

  _Part _vendorPart(String q, List<Map<String, dynamic>> orders) {
    final needle = q.toLowerCase();
    final counts = <String, int>{};
    for (final r in orders) {
      final name = _text(r['vendor']);
      if (name.toLowerCase().contains(needle)) counts[name] = (counts[name] ?? 0) + 1;
    }
    final names = counts.keys.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return _Part(SearchKind.vendor, [for (final n in names.take(_perSection)) _vendorRow(n, counts[n]!)]);
  }

  _Part _section(SearchKind kind, String q, List<SearchRow> rows, int total, {required bool exact}) => _Part(
        kind,
        [
          ...rows,
          if (total > rows.length)
            SearchRow(
              kind: kind,
              title: 'See all $total ${kind.noun}',
              route: '${kind.route}?q=${Uri.encodeQueryComponent(q)}',
              more: true,
            ),
        ],
        exact: exact,
      );

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

/// Puts the dropdown under a search field. Owns the search and watches [controller]; [builder] builds the field, and
/// must call the callback it is given when the field is submitted.
class GlobalSearchDropdown extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<SearchPick> onPick;
  final Widget Function(BuildContext context, VoidCallback submit) builder;

  const GlobalSearchDropdown({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onPick,
    required this.builder,
  });

  @override
  State<GlobalSearchDropdown> createState() => _GlobalSearchDropdownState();
}

class _GlobalSearchDropdownState extends State<GlobalSearchDropdown> {
  static const double _gap = 6;
  static const double _edge = 12;

  final _search = GlobalSearch();
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  bool _dismissed = false; // Escape closed it; typing or clicking the field brings it back
  double _width = 440;
  double _height = 520;
  Size? _window;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onText);
    widget.focusNode.addListener(_sync);
    // The field is rebuilt when the bar changes fit, possibly with something already typed.
    _search.update(widget.controller.text);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sync();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final window = MediaQuery.sizeOf(context);
    if (window == _window) return;
    _window = window;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _portal.isShowing) setState(_measure);
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onText);
    widget.focusNode.removeListener(_sync);
    _search.dispose();
    super.dispose();
  }

  void _onText() {
    if (widget.controller.text.trim() == _search.query) return;
    _dismissed = false;
    _search.update(widget.controller.text);
    _sync();
  }

  void _sync() {
    if (!widget.focusNode.hasFocus) _dismissed = false;
    final show = widget.focusNode.hasFocus && _search.active && !_dismissed;
    if (show && !_portal.isShowing) {
      _measure();
      _portal.show();
    } else if (!show && _portal.isShowing) {
      _portal.hide();
    }
  }

  /// The dropdown is wider than the field and hangs from its right edge, so it has to fit between there and the left
  /// of the window, and between the field and the bottom.
  void _measure() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final corner = box.localToGlobal(box.size.bottomRight(Offset.zero));
    _width = math.min(440, corner.dx - _edge);
    _height = math.max(120, math.min(520, MediaQuery.sizeOf(context).height - corner.dy - _gap - _edge));
  }

  void _finish(SearchPick pick) {
    widget.controller.clear();
    widget.focusNode.unfocus();
    widget.onPick(pick);
  }

  void _pick(SearchRow row) => _finish(SearchPick(_search.query, route: row.route, extra: row.extra));

  Future<void> _submit() async {
    final query = widget.controller.text.trim();
    if (query.isEmpty) return;
    final row = await _search.submit();
    if (!mounted || widget.controller.text.trim() != query) return;
    _finish(SearchPick(query, route: row?.route, extra: row?.extra));
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!_portal.isShowing) return KeyEventResult.ignored;
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
      _dismissed = true;
      _sync();
      return KeyEventResult.handled;
    }
    return _search.handleArrows(event);
  }

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: (_) => Positioned(
        width: _width,
        child: CompositedTransformFollower(
          link: _link,
          showWhenUnlinked: false,
          targetAnchor: Alignment.bottomRight,
          followerAnchor: Alignment.topRight,
          offset: const Offset(0, _gap),
          // The field's own tap region: a click in here doesn't count as leaving it.
          child: TextFieldTapRegion(
            child: _Reveal(
              child: Material(
                color: Colors.white,
                elevation: 10,
                shadowColor: Colors.black.withValues(alpha: 0.18),
                clipBehavior: Clip.antiAlias,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: DashUi.line),
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: _height),
                  child: GlobalSearchResults(search: _search, onPick: _pick),
                ),
              ),
            ),
          ),
        ),
      ),
      child: CompositedTransformTarget(
        link: _link,
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: _onKey,
          child: Listener(
            onPointerDown: (_) {
              if (!_dismissed) return;
              _dismissed = false;
              _sync();
            },
            child: widget.builder(context, _submit),
          ),
        ),
      ),
    );
  }
}

/// Drops the dropdown in from just under the field.
class _Reveal extends StatelessWidget {
  final Widget child;
  const _Reveal({required this.child});

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOutCubic,
      child: child,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, (1 - t) * -6), child: child),
      ),
    );
  }
}

/// The list of matches, with its searching, nothing-found and couldn't-search states.
class GlobalSearchResults extends StatelessWidget {
  final GlobalSearch search;
  final ValueChanged<SearchRow> onPick;

  const GlobalSearchResults({super.key, required this.search, required this.onPick});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: search,
      builder: (context, _) {
        final rows = search.rows;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (rows.isNotEmpty)
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (i, row) in rows.indexed) ...[
                        if (i == 0 || rows[i - 1].kind != row.kind) _Heading(row.kind.heading, first: i == 0),
                        _ResultRow(
                          row: row,
                          query: search.query,
                          highlighted: i == search.highlight,
                          reveal: search.byKeyboard,
                          onHover: () => search.hover(i),
                          onTap: () => onPick(row),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            if (search.loading && rows.isEmpty)
              const _Note(busy: true, text: 'Searching…')
            else if (search.failed)
              _Note(
                text: rows.isEmpty ? "Search isn't responding." : "Some results didn't load.",
                actionLabel: 'Try again',
                onAction: search.retry,
              )
            else if (!search.loading && rows.isEmpty)
              _Note(text: 'No matches for "${search.query}"'),
          ],
        );
      },
    );
  }
}

class _Heading extends StatelessWidget {
  final String text;
  final bool first;
  const _Heading(this.text, {required this.first});

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(14, first ? 4 : 10, 14, 4),
        child: Semantics(
          header: true,
          child: Text(text, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: DashUi.subtle)),
        ),
      );
}

class _Note extends StatelessWidget {
  final String text;
  final bool busy;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _Note({required this.text, this.busy = false, this.actionLabel, this.onAction});

  @override
  Widget build(BuildContext context) => Semantics(
        liveRegion: true,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          child: Row(
            children: [
              if (busy) ...[
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2, color: DashUi.subtle),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, color: DashUi.slate),
                ),
              ),
              if (actionLabel != null) ...[
                const SizedBox(width: 10),
                // Not focusable: focus stays in the field, which keeps the dropdown open.
                InkWell(
                  canRequestFocus: false,
                  borderRadius: BorderRadius.circular(6),
                  onTap: onAction,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    child: Text(
                      actionLabel!,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: DashUi.ink),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
}

class _ResultRow extends StatefulWidget {
  final SearchRow row;
  final String query;
  final bool highlighted;
  final bool reveal;
  final VoidCallback onHover;
  final VoidCallback onTap;

  const _ResultRow({
    required this.row,
    required this.query,
    required this.highlighted,
    required this.reveal,
    required this.onHover,
    required this.onTap,
  });

  @override
  State<_ResultRow> createState() => _ResultRowState();
}

class _ResultRowState extends State<_ResultRow> {
  @override
  void didUpdateWidget(_ResultRow old) {
    super.didUpdateWidget(old);
    if (!widget.highlighted || old.highlighted || !widget.reveal) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Scrollable.ensureVisible(context, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
      if (mounted) Scrollable.ensureVisible(context, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart);
    });
  }

  /// [text] with the part that matches what was typed in bold ink.
  TextSpan _marked(String text, TextStyle style) {
    final at = widget.query.isEmpty ? -1 : text.toLowerCase().indexOf(widget.query.toLowerCase());
    final end = at + widget.query.length;
    if (at < 0 || end > text.length) return TextSpan(text: text, style: style);
    return TextSpan(style: style, children: [
      TextSpan(text: text.substring(0, at)),
      TextSpan(
        text: text.substring(at, end),
        style: const TextStyle(fontWeight: FontWeight.w800, color: DashUi.ink),
      ),
      TextSpan(text: text.substring(end)),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    const titleStyle = TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: DashUi.ink);
    const subStyle = TextStyle(fontSize: 12, color: DashUi.slate);

    return MouseRegion(
      onEnter: (_) => widget.onHover(),
      child: Semantics(
        button: true,
        selected: widget.highlighted,
        label: [row.title, row.subtitle, row.status].where((s) => s.isNotEmpty).join(', '),
        excludeSemantics: true,
        child: Material(
          color: widget.highlighted ? AppTheme.subtleFill : Colors.transparent,
          child: InkWell(
            canRequestFocus: false, // focus stays in the field, where the arrow keys work
            onTap: widget.onTap,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 14, vertical: row.more ? 8 : 7),
              child: row.more
                  ? Row(
                      children: [
                        Expanded(
                          child: Text(
                            row.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: DashUi.slate),
                          ),
                        ),
                        const Icon(Icons.arrow_forward_rounded, size: 15, color: DashUi.slate),
                      ],
                    )
                  : Row(
                      children: [
                        Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(color: DashUi.faint, borderRadius: BorderRadius.circular(8)),
                          child: Icon(accessIcon(row.kind.accessKey), size: 16, color: DashUi.slate),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text.rich(_marked(row.title, titleStyle), maxLines: 1, overflow: TextOverflow.ellipsis),
                              if (row.subtitle.isNotEmpty)
                                Text.rich(_marked(row.subtitle, subStyle), maxLines: 1, overflow: TextOverflow.ellipsis),
                            ],
                          ),
                        ),
                        if (row.status.isNotEmpty) ...[
                          const SizedBox(width: 10),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 120),
                            child: Text(
                              row.status,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12, color: DashUi.subtle),
                            ),
                          ),
                        ],
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
