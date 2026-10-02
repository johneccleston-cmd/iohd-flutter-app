import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'config/api_config.dart';
import 'config/auth_session.dart';

// --- Shared Design Tokens ---
const Color _brandRed = Color(0xFFCC0007);
const Color _inkColor = Color(0xFF181B1F);
const Color _slateColor = Color(0xFF5B6572);
const Color _strokeBorder = Color(0xFFE4E7EC);
const Color _fieldFill = Color(0xFFF6F7F9);
const Color _okGreen = Color(0xFF1E7B4F);
const Color _warnAmber = Color(0xFFB45309);
const Color _pageBg = Color(0xFFFAFAFA);

// Used until the API returns a per-item minimum.
const int _kLowStockThreshold = 5;

const _figures = [FontFeature.tabularFigures()];

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------
enum _Status { inStock, low, out }

enum _SortBy { name, category, stock, status }

class _Item {
  final String name;
  final String category;
  final String sku; // empty when the API doesn't provide one
  final int stock;
  final int min;

  const _Item({
    required this.name,
    required this.category,
    required this.sku,
    required this.stock,
    required this.min,
  });

  factory _Item.fromJson(Map<String, dynamic> j) {
    final rawQty = j['qty'];
    final qty = int.tryParse('$rawQty') ??
        double.tryParse('$rawQty')?.round() ??
        0;
    final rawSku = (j['sku'] ?? '').toString().trim();
    return _Item(
      name: (j['name'] ?? 'Unknown').toString(),
      category: (j['category'] ?? 'Uncategorized').toString(),
      sku: rawSku == 'N/A' ? '' : rawSku,
      stock: qty,
      min: _kLowStockThreshold,
    );
  }

  _Status get status {
    if (stock <= 0) return _Status.out;
    if (stock <= min) return _Status.low;
    return _Status.inStock;
  }
}

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------
class InventoryScreen extends StatefulWidget {
  const InventoryScreen({super.key});

  @override
  State<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends State<InventoryScreen> {
  final TextEditingController _searchController = TextEditingController();

  List<_Item> _items = [];
  bool _isLoading = true;
  String _errorMessage = '';
  DateTime? _lastUpdated;

  String _query = '';
  String? _category; // null = all
  _Status? _statusFilter; // null = all
  _SortBy _sortBy = _SortBy.status;
  bool _ascending = true;

  @override
  void initState() {
    super.initState();
    _fetchInventory();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetchInventory() async {
    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    try {
      final response = await http.get(
        Uri.parse('$kApiBaseUrl/get_full_inventory'),
        headers: AuthSession.instance.headers(),
      ).timeout(const Duration(seconds: 15));
      if (!mounted) return;

      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        setState(() {
          _items = data
              .map((e) => _Item.fromJson(Map<String, dynamic>.from(e as Map)))
              .toList();
          _lastUpdated = DateTime.now();
          _isLoading = false;
        });
      } else {
        setState(() {
          _errorMessage =
              'Couldn\'t load inventory (status ${response.statusCode}).';
          _isLoading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage =
            'Couldn\'t reach the server. Check your connection and try again.';
        _isLoading = false;
      });
    }
  }

  // ---- derived data -------------------------------------------------------
  bool get _hasSku => _items.any((i) => i.sku.isNotEmpty);

  List<String> get _categories {
    final set = _items.map((i) => i.category).toSet().toList()..sort();
    return set;
  }

  int _count(_Status s) => _items.where((i) => i.status == s).length;

  List<_Item> get _visible {
    final q = _query.trim().toLowerCase();
    final list = _items.where((i) {
      if (_category != null && i.category != _category) return false;
      if (_statusFilter != null && i.status != _statusFilter) return false;
      if (q.isEmpty) return true;
      return i.name.toLowerCase().contains(q) ||
          i.sku.toLowerCase().contains(q) ||
          i.category.toLowerCase().contains(q);
    }).toList();

    int cmp(_Item a, _Item b) {
      switch (_sortBy) {
        case _SortBy.name:
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case _SortBy.category:
          final c = a.category.toLowerCase().compareTo(b.category.toLowerCase());
          return c != 0 ? c : a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case _SortBy.stock:
          return a.stock.compareTo(b.stock);
        case _SortBy.status:
          // Out first, then low, then in stock; fewest units first within a group.
          final s = b.status.index.compareTo(a.status.index);
          return s != 0 ? s : a.stock.compareTo(b.stock);
      }
    }

    list.sort((a, b) => _ascending ? cmp(a, b) : cmp(b, a));
    return list;
  }

  void _setSort(_SortBy by) {
    setState(() {
      if (_sortBy == by) {
        _ascending = !_ascending;
      } else {
        _sortBy = by;
        _ascending = true;
      }
    });
  }

  void _clearFilters() {
    _searchController.clear();
    setState(() {
      _query = '';
      _category = null;
      _statusFilter = null;
    });
  }

  String _updatedText() {
    final t = _lastUpdated;
    if (t == null) return '';
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    final m = t.minute.toString().padLeft(2, '0');
    return 'Updated $h:$m ${t.hour >= 12 ? 'PM' : 'AM'}';
  }

  // ---- build --------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _pageBg,
      body: LayoutBuilder(builder: (context, c) {
        final narrow = c.maxWidth < 720;
        final pad = narrow ? 16.0 : 32.0;

        return Padding(
          padding: EdgeInsets.fromLTRB(pad, pad, pad, narrow ? 0 : pad),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(narrow),
              const SizedBox(height: 20),
              if (_errorMessage.isNotEmpty && _items.isNotEmpty) ...[
                _buildErrorBanner(),
                const SizedBox(height: 16),
              ],
              if (_items.isNotEmpty) ...[
                _buildMetrics(narrow),
                const SizedBox(height: 20),
              ],
              Expanded(child: _buildBody(narrow)),
            ],
          ),
        );
      }),
    );
  }

  Widget _buildHeader(bool narrow) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Inventory',
                    style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        color: _inkColor,
                        letterSpacing: -0.6),
                  ),
                  if (_lastUpdated != null) ...[
                    const SizedBox(height: 2),
                    Text(_updatedText(),
                        style: const TextStyle(
                            fontSize: 13, color: _slateColor)),
                  ],
                ],
              ),
            ),
            OutlinedButton.icon(
              onPressed: _isLoading ? null : _fetchInventory,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Refresh',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              style: OutlinedButton.styleFrom(
                foregroundColor: _inkColor,
                side: const BorderSide(color: _strokeBorder),
                backgroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ],
        ),
        if (_isLoading && _items.isNotEmpty) ...[
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: const LinearProgressIndicator(
              minHeight: 3,
              color: _brandRed,
              backgroundColor: _strokeBorder,
            ),
          ),
        ],
      ],
    );
  }

  // ---- metrics ------------------------------------------------------------
  Widget _buildMetrics(bool narrow) {
    final totalUnits = _items.fold<int>(0, (s, i) => s + i.stock);
    final low = _count(_Status.low);
    final out = _count(_Status.out);

    final cards = [
      _MetricCard(
          title: 'Unique items',
          value: '${_items.length}',
          icon: Icons.inventory_2_outlined),
      _MetricCard(
          title: 'Units on hand',
          value: '$totalUnits',
          icon: Icons.stacked_bar_chart_rounded),
      _MetricCard(
          title: 'Low stock',
          value: '$low',
          icon: Icons.warning_amber_rounded,
          tone: low > 0 ? _warnAmber : null),
      _MetricCard(
          title: 'Out of stock',
          value: '$out',
          icon: Icons.remove_shopping_cart_outlined,
          tone: out > 0 ? _brandRed : null),
    ];

    if (!narrow) {
      return Row(
        children: [
          for (int i = 0; i < cards.length; i++) ...[
            Expanded(child: cards[i]),
            if (i != cards.length - 1) const SizedBox(width: 16),
          ],
        ],
      );
    }
    return Column(
      children: [
        Row(children: [
          Expanded(child: cards[0]),
          const SizedBox(width: 12),
          Expanded(child: cards[1]),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: cards[2]),
          const SizedBox(width: 12),
          Expanded(child: cards[3]),
        ]),
      ],
    );
  }

  // ---- body ---------------------------------------------------------------
  Widget _buildBody(bool narrow) {
    if (_isLoading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator(color: _brandRed));
    }

    if (_items.isEmpty) {
      return _buildMessageCard(
        icon: _errorMessage.isNotEmpty
            ? Icons.cloud_off_rounded
            : Icons.inventory_2_outlined,
        title: _errorMessage.isNotEmpty
            ? 'Inventory didn\'t load'
            : 'No inventory items yet',
        message: _errorMessage.isNotEmpty
            ? _errorMessage
            : 'Items will appear here once they\'re added.',
        actionLabel: 'Try again',
        onAction: _fetchInventory,
      );
    }

    final visible = _visible;

    return Container(
      margin: EdgeInsets.only(bottom: narrow ? 16 : 0),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _strokeBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildToolbar(visible.length),
          const Divider(height: 1, color: _strokeBorder),
          if (!narrow) _buildTableHeader(),
          Expanded(
            child: visible.isEmpty
                ? _buildNoMatches()
                : RefreshIndicator(
                    color: _brandRed,
                    onRefresh: _fetchInventory,
                    child: ListView.separated(
                      physics: const AlwaysScrollableScrollPhysics(),
                      itemCount: visible.length,
                      separatorBuilder: (_, __) =>
                          const Divider(height: 1, color: _strokeBorder),
                      itemBuilder: (_, i) => narrow
                          ? _narrowRow(visible[i])
                          : _wideRow(visible[i]),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar(int shown) {
    final filtered =
        _query.isNotEmpty || _category != null || _statusFilter != null;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ConstrainedBox(
                constraints:
                    const BoxConstraints(minWidth: 220, maxWidth: 360),
                child: SizedBox(
                  width: 340,
                  height: 40,
                  child: TextField(
                    controller: _searchController,
                    onChanged: (v) => setState(() => _query = v),
                    style: const TextStyle(fontSize: 14),
                    decoration: InputDecoration(
                      hintText:
                          _hasSku ? 'Search name, SKU or category' : 'Search name or category',
                      hintStyle: const TextStyle(
                          color: Color(0xFF9CA3AF), fontSize: 13),
                      prefixIcon: const Icon(Icons.search,
                          size: 18, color: _slateColor),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close_rounded, size: 16),
                              color: _slateColor,
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _query = '');
                              },
                            ),
                      filled: true,
                      fillColor: _fieldFill,
                      contentPadding: EdgeInsets.zero,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide:
                            const BorderSide(color: _brandRed, width: 1.2),
                      ),
                    ),
                  ),
                ),
              ),
              _buildCategoryDropdown(),
              _filterChip('All', null, _items.length),
              _filterChip('Low', _Status.low, _count(_Status.low)),
              _filterChip('Out', _Status.out, _count(_Status.out)),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Text(
                filtered
                    ? 'Showing $shown of ${_items.length} items'
                    : '${_items.length} items',
                style: const TextStyle(fontSize: 12, color: _slateColor),
              ),
              if (filtered) ...[
                const SizedBox(width: 12),
                InkWell(
                  onTap: _clearFilters,
                  child: const Text('Clear filters',
                      style: TextStyle(
                          fontSize: 12,
                          color: _brandRed,
                          fontWeight: FontWeight.w700)),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryDropdown() {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: _fieldFill,
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          value: _category,
          icon: const Icon(Icons.keyboard_arrow_down_rounded,
              size: 18, color: _slateColor),
          style: const TextStyle(fontSize: 13, color: _inkColor),
          borderRadius: BorderRadius.circular(8),
          items: [
            const DropdownMenuItem<String?>(
                value: null, child: Text('All categories')),
            ..._categories.map(
                (c) => DropdownMenuItem<String?>(value: c, child: Text(c))),
          ],
          onChanged: (v) => setState(() => _category = v),
        ),
      ),
    );
  }

  Widget _filterChip(String label, _Status? status, int count) {
    final selected = _statusFilter == status;
    return ChoiceChip(
      label: Text('$label  $count'),
      selected: selected,
      showCheckmark: false,
      labelStyle: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: selected ? Colors.white : _inkColor,
      ),
      backgroundColor: Colors.white,
      selectedColor: _inkColor,
      side: BorderSide(color: selected ? _inkColor : _strokeBorder),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      onSelected: (_) => setState(() => _statusFilter = status),
    );
  }

  // ---- table --------------------------------------------------------------
  Widget _buildTableHeader() {
    return Container(
      color: _fieldFill,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      child: Row(
        children: [
          Expanded(flex: 5, child: _sortHeader('Item', _SortBy.name)),
          if (_hasSku)
            const Expanded(
                flex: 3,
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('SKU', style: _headStyle),
                )),
          Expanded(flex: 3, child: _sortHeader('Category', _SortBy.category)),
          Expanded(flex: 4, child: _sortHeader('Stock', _SortBy.stock)),
          Expanded(flex: 3, child: _sortHeader('Status', _SortBy.status)),
        ],
      ),
    );
  }

  static const _headStyle = TextStyle(
      fontSize: 12, fontWeight: FontWeight.w700, color: _slateColor);

  Widget _sortHeader(String label, _SortBy by) {
    final active = _sortBy == by;
    return InkWell(
      onTap: () => _setSort(by),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: _headStyle.copyWith(
                    color: active ? _inkColor : _slateColor)),
            const SizedBox(width: 4),
            Icon(
              active
                  ? (_ascending
                      ? Icons.arrow_upward_rounded
                      : Icons.arrow_downward_rounded)
                  : Icons.unfold_more_rounded,
              size: 14,
              color: active ? _inkColor : const Color(0xFF9CA3AF),
            ),
          ],
        ),
      ),
    );
  }

  Color _statusColor(_Status s) {
    switch (s) {
      case _Status.out:
        return _brandRed;
      case _Status.low:
        return _warnAmber;
      case _Status.inStock:
        return _okGreen;
    }
  }

  Widget _stockBar(_Item item) {
    final color = _statusColor(item.status);
    double frac = 0;
    if (item.stock > 0) {
      frac = (item.stock / (item.min * 4)).clamp(0.06, 1.0).toDouble();
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: LinearProgressIndicator(
        value: frac,
        minHeight: 6,
        backgroundColor: _strokeBorder,
        valueColor: AlwaysStoppedAnimation(color),
      ),
    );
  }

  Widget _wideRow(_Item item) {
    final color = _statusColor(item.status);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      child: Row(
        children: [
          Expanded(
            flex: 5,
            child: Text(item.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: _inkColor)),
          ),
          if (_hasSku)
            Expanded(
              flex: 3,
              child: Text(item.sku.isEmpty ? '—' : item.sku,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14, color: _slateColor)),
            ),
          Expanded(
            flex: 3,
            child: Text(item.category,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, color: _slateColor)),
          ),
          Expanded(
            flex: 4,
            child: Row(
              children: [
                SizedBox(
                  width: 44,
                  child: Text('${item.stock}',
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: item.status == _Status.inStock
                              ? _inkColor
                              : color,
                          fontFeatures: _figures)),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 24),
                    child: _stockBar(item),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 3,
            child: Align(
              alignment: Alignment.centerLeft,
              child: _StatusPill(status: item.status, color: color),
            ),
          ),
        ],
      ),
    );
  }

  Widget _narrowRow(_Item item) {
    final color = _statusColor(item.status);
    final sub = [
      item.category,
      if (item.sku.isNotEmpty) item.sku,
    ].join('  •  ');

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.name,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                            color: _inkColor)),
                    const SizedBox(height: 2),
                    Text(sub,
                        style: const TextStyle(
                            fontSize: 13, color: _slateColor)),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _StatusPill(status: item.status, color: color),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Text('${item.stock}',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color:
                          item.status == _Status.inStock ? _inkColor : color,
                      fontFeatures: _figures)),
              const SizedBox(width: 6),
              const Text('on hand',
                  style: TextStyle(fontSize: 12, color: _slateColor)),
              const SizedBox(width: 16),
              Expanded(child: _stockBar(item)),
            ],
          ),
        ],
      ),
    );
  }

  // ---- states -------------------------------------------------------------
  Widget _buildNoMatches() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_off_rounded, size: 36, color: _slateColor),
            const SizedBox(height: 12),
            const Text('No items match',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: _inkColor)),
            const SizedBox(height: 4),
            const Text('Try a different search or clear the filters.',
                style: TextStyle(fontSize: 13, color: _slateColor)),
            const SizedBox(height: 12),
            TextButton(
              onPressed: _clearFilters,
              style: TextButton.styleFrom(foregroundColor: _brandRed),
              child: const Text('Clear filters'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageCard({
    required IconData icon,
    required String title,
    required String message,
    required String actionLabel,
    required VoidCallback onAction,
  }) {
    return Align(
      alignment: Alignment.topCenter,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 56, horizontal: 24),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _strokeBorder),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: _fieldFill,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(icon, size: 30, color: _slateColor),
            ),
            const SizedBox(height: 16),
            Text(title,
                style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: _inkColor)),
            const SizedBox(height: 6),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, color: _slateColor)),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: onAction,
              style: FilledButton.styleFrom(
                backgroundColor: _brandRed,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              child: Text(actionLabel),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorBanner() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _brandRed.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _brandRed.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: _brandRed, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text('$_errorMessage Showing the last loaded data.',
                style: const TextStyle(
                    color: _brandRed,
                    fontWeight: FontWeight.w600,
                    fontSize: 13)),
          ),
          TextButton(
            onPressed: _isLoading ? null : _fetchInventory,
            style: TextButton.styleFrom(foregroundColor: _brandRed),
            child: const Text('Try again'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Small widgets
// ---------------------------------------------------------------------------
class _MetricCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final Color? tone; // null = neutral

  const _MetricCard({
    required this.title,
    required this.value,
    required this.icon,
    this.tone,
  });

  @override
  Widget build(BuildContext context) {
    final accent = tone ?? _slateColor;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: tone != null ? tone!.withValues(alpha: 0.45) : _strokeBorder),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: tone != null ? tone!.withValues(alpha: 0.1) : _fieldFill,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: accent, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13,
                        color: _slateColor,
                        fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text(value,
                    style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        color: tone ?? _inkColor,
                        letterSpacing: -0.5,
                        fontFeatures: _figures)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final _Status status;
  final Color color;

  const _StatusPill({required this.status, required this.color});

  @override
  Widget build(BuildContext context) {
    final label = switch (status) {
      _Status.out => 'Out of stock',
      _Status.low => 'Low stock',
      _Status.inStock => 'In stock',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700, color: color)),
        ],
      ),
    );
  }
}