import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'config/access.dart';
import 'services/line_items_api.dart';
import 'widgets/app_ribbon.dart';
import 'widgets/dashboard_kit.dart';
import 'widgets/flat_page.dart';

/// Services Catalog: every service the office has put on a job or estimate line, with the price it usually charges.
/// Service Fusion has no price-list endpoint, so (like the job page's catalog search) the list is built from the
/// synced lines of the last 18 months. Read-only: nothing here is written back to Service Fusion.
class ServicesCatalogScreen extends StatefulWidget {
  /// Swappable for tests; the real call is [LineItemsApi.listCatalog].
  final Future<({List<CatalogEntry> entries, bool canSeeCost, int historyDays})> Function()? load;
  const ServicesCatalogScreen({super.key, this.load});

  @override
  State<ServicesCatalogScreen> createState() => _ServicesCatalogScreenState();
}

class _ServicesCatalogScreenState extends State<ServicesCatalogScreen> {
  final _search = TextEditingController();
  final _activity = RibbonActivity();
  Timer? _slowTimer;

  List<CatalogEntry> _all = const [];
  bool _canSeeCost = false;
  int _historyDays = 540;
  bool _loading = true;
  bool _slow = false; // the first load has taken long enough to say the server may be waking up
  bool _loaded = false;
  String? _error;

  /// The server refused the list (403): this person's Services Catalog switch is off (Team).
  bool _noAccess = false;
  int _request = 0; // a late answer from an older request is dropped

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void dispose() {
    _slowTimer?.cancel();
    _search.dispose();
    _activity.dispose();
    super.dispose();
  }

  Future<void> _fetch() async {
    final id = ++_request;
    final first = !_loaded;
    _slowTimer?.cancel();
    if (first) {
      _slowTimer = Timer(const Duration(seconds: 8), () {
        if (mounted && _loading) setState(() => _slow = true);
      });
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    _activity.setRefreshing(true);
    try {
      // Inactive too: a service a renamed line has taken over is kept here, with its history, though no longer offered.
      final r = await (widget.load ?? () => LineItemsApi.listCatalog(kind: 'service', includeInactive: true))();
      if (!mounted || id != _request) return;
      setState(() {
        // The services offered first, in the server's order (most billed first); the superseded ones after them.
        _all = [...r.entries.where((e) => e.supersededBy == null), ...r.entries.where((e) => e.supersededBy != null)];
        _canSeeCost = r.canSeeCost;
        _historyDays = r.historyDays;
        _loaded = true;
        _noAccess = false;
        _loading = false;
        _slow = false;
      });
      _activity.landed();
    } catch (e) {
      if (!mounted || id != _request) return;
      setState(() {
        _error = e is LineItemsException ? e.message : 'Could not load the services.';
        // No access (the switch is off, or was turned off since the page opened): nothing of the list stays on show.
        _noAccess = e is LineItemsException && e.status == 403;
        if (_noAccess) {
          _all = const [];
          _loaded = false;
        }
        _loading = false;
        _slow = false;
      });
    } finally {
      _slowTimer?.cancel();
      if (mounted && id == _request) _activity.setRefreshing(false);
    }
  }

  List<CatalogEntry> get _shown {
    final words = _search.text.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return _all;
    return [
      for (final e in _all)
        if (words.every((w) => '${e.name} ${e.description}'.toLowerCase().contains(w))) e,
    ];
  }

  static String _money(double? v) => v == null ? '–' : dashMoney(v);

  String _range(CatalogEntry e) {
    final lo = e.rateMin, hi = e.rateMax;
    if (lo == null || hi == null) return '–';
    return lo == hi ? dashMoney(lo) : '${dashMoney(lo)} – ${dashMoney(hi)}';
  }

  String _date(String? iso) {
    final d = iso == null ? null : DateTime.tryParse(iso);
    return d == null ? '–' : DateFormat.yMMMd().format(d);
  }

  Widget _figure(String text) => Text(text, style: flatCellStyle.copyWith(fontFeatures: flatFigures));

  Widget _table(List<CatalogEntry> rows) {
    final cols = [
      const FlatCol('Service', flex: 6),
      const FlatCol('Usual Price', flex: 2, right: true),
      const FlatCol('Price Range', flex: 3, right: true),
      if (_canSeeCost) const FlatCol('Unit Cost', flex: 2, right: true),
      const FlatCol('Times Used', flex: 2, right: true),
      const FlatCol('Last Used', flex: 2),
      const FlatCol('Tax', flex: 2),
    ];
    return FlatTable(
      columns: cols,
      rows: [
        for (final e in rows)
          [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(e.name, style: e.supersededBy == null ? flatCellBold : flatCellBold.copyWith(color: DashUi.subtle)),
                // Superseded: kept with its history, no longer offered on new lines; say what replaced it.
                if (e.supersededBy case final by?)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      'Superseded by ${by.name}', // "Not offered" stands in its Usual Price column
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: flatCellMuted.copyWith(fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                  )
                else if (e.replaces.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      'Replaces ${e.replaces.map((r) => r.name).join(', ')}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: flatCellMuted.copyWith(fontSize: 13),
                    ),
                  ),
                if (e.description.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(e.description.trim().replaceAll(RegExp(r'\s+'), ' '), maxLines: 1, overflow: TextOverflow.ellipsis, style: flatCellMuted.copyWith(fontSize: 13)),
                  ),
              ],
            ),
            if (e.supersededBy != null) Text('Not offered', style: flatCellMuted) else _figure(_money(e.rate)),
            _figure(_range(e)),
            if (_canSeeCost) _figure(_money(e.cost)),
            _figure('${e.uses}'),
            Text(_date(e.lastUsed), style: flatCellMuted),
            Text(e.taxable ? 'Taxable' : 'No tax', style: e.taxable ? flatCellStyle : flatCellMuted),
          ],
      ],
    );
  }

  Widget _body(List<CatalogEntry> shown, bool compact) {
    if (_noAccess && !_loading) {
      return const FlatEmpty(
        icon: Icons.lock_outline_rounded,
        title: "You don't have access to the Services Catalog",
        message: 'Ask an admin to turn it on in Team.',
      );
    }
    if (_loading && !_loaded) {
      return FlatLoading(label: 'Loading services', flex: const [6, 2, 3, 2, 2, 2], compact: compact, slow: _slow);
    }
    if (_error != null && !_loaded) {
      return FlatEmpty(
        icon: Icons.cloud_off_rounded,
        title: 'Could not load the services',
        message: _error!,
        action: FilledButton(
          onPressed: _loading ? null : _fetch,
          style: FilledButton.styleFrom(backgroundColor: DashUi.ink),
          child: const Text('Try again'),
        ),
      );
    }
    if (_all.isEmpty) {
      return const FlatEmpty(
        icon: Icons.handyman_outlined,
        title: 'No services yet',
        message: 'Services show up here once they have been on a job or estimate line.',
      );
    }
    if (shown.isEmpty) {
      return FlatEmpty(
        icon: Icons.search_off_rounded,
        title: 'No services match',
        message: 'Nothing matches "${_search.text.trim()}".',
        action: OutlinedButton(onPressed: () => setState(_search.clear), child: const Text('Clear search')),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_error != null)
          FlatStaleNotice(message: 'Could not refresh. These may be out of date.', busy: _loading, onRetry: _fetch),
        // Narrower than the columns need: scroll sideways rather than wrap prices mid-number.
        if (compact)
          SingleChildScrollView(scrollDirection: Axis.horizontal, child: SizedBox(width: 900, child: _table(shown)))
        else
          _table(shown),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    // Counted among the services offered; a superseded one only adds its lines (its history) to the total.
    final offered = _all.where((e) => e.supersededBy == null).toList();
    final priced = offered.where((e) => e.rate != null).length;
    final months = (_historyDays / 30).round();
    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageBanner(
            title: 'Services Catalog',
            icon: accessIcon('services_catalog'),
            activity: _activity,
            actions: [PageBanner.refresh(onPressed: _loading ? null : _fetch)],
          ),
          Expanded(
            child: PageSheet(
              child: LayoutBuilder(
                builder: (context, c) => SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_loaded)
                        FlatStats(
                          stats: [
                            FlatStat('Services', '${offered.length}'),
                            FlatStat('With a Usual Price', '$priced'),
                            FlatStat('Lines in $months Months', '${_all.fold<int>(0, (s, e) => s + e.uses)}'),
                          ],
                        ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
                        child: Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            SizedBox(
                              width: 340,
                              child: TextField(
                                controller: _search,
                                style: const TextStyle(fontSize: 14),
                                onChanged: (_) => setState(() {}),
                                decoration: flatSearchDecoration(
                                  'Search services...',
                                  onClear: _search.text.isEmpty ? null : () => setState(_search.clear),
                                ),
                              ),
                            ),
                            if (_loaded)
                              Text(
                                'Built from the service lines on jobs and estimates in the last $months months.',
                                style: flatCellMuted.copyWith(fontSize: 13),
                              ),
                          ],
                        ),
                      ),
                      _body(shown, c.maxWidth < 900),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
