import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:intl/intl.dart';
import 'config/api_config.dart';

Color getStatusColor(String? status) {
  if (status == null) return const Color(0xFF9C9C9C);

  switch (status.trim().toLowerCase()) {
    case 'need deposit':
      return const Color(0xFFA80000);
    case 'need to order':
      return const Color(0xFF00B3FF);
    case 'manage project':
    case 'verify delivery':
      return const Color(0xFF0051FF);
    case 'need to schedule':
      return const Color(0xFF08EB00);
    case 'site check':
    case 'scheduled':
    case 'warranty work':
    case 'callback':
      return const Color(0xFF009E18);
    case 'appointment':
      return const Color(0xFF00B51B);
    case 'delayed':
    case 'need to warranty':
    case 'partially complete':
      return const Color(0xFFFFAE00);
    case 'need to sell':
    case 'google review sent':
      return const Color(0xFF000AC4);
    case 'cancelled':
      return const Color(0xFF592D00);
    case 'complete':
      return const Color(0xFF9C9C9C);
    case 'final invoice sent':
      return const Color(0xFFDB0000);
    case 'write-off':
      return const Color(0xFFD92100);
    case 'close job':
    case 'paid & closed':
      return const Color(0xFF000000);
    case 'part ordered':
      return const Color(0xFF7F83EB);
    case 'estimate requested':
    case 'estimate follow up':
    case 'estimate accepted':
      return const Color(0xFFEB36FF);
    case 'estimate provided':
      return const Color(0xFF5F0069);
    case 'estimate won':
      return const Color(0xFF3C0045);
    case 'lost':
      return const Color(0xFF59320C);
    case '14 day notice':
    case '30 day notice':
    case '60 day notice':
    case '90 day notice':
    case 'check on payment':
      return const Color(0xFFFF0000);
    default:
      return const Color(0xFF9C9C9C);
  }
}

class EstimatesScreen extends StatefulWidget {
  const EstimatesScreen({super.key});

  @override
  State<EstimatesScreen> createState() => _EstimatesScreenState();
}

class _EstimatesScreenState extends State<EstimatesScreen> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  List<dynamic> _displayedEstimates = [];
  bool isEstimatesLoading = true;
  bool isCountsLoading = true;
  String errorMessage = '';
  TextEditingController searchController = TextEditingController();

  // Status Filter State
  String _selectedStatus = 'All';
  int _totalEstimatesCount = 0;
  List<dynamic> _statusCounts = [];

  // Pagination & Prefetching State
  int _currentPage = 1;
  int _totalPages = 1;
  int _totalFilteredEstimates = 0;
  int _pageSize = 100;

  final Map<int, List<dynamic>> _pageCache = {};
  final NumberFormat _currencyFormat = NumberFormat.currency(symbol: '\$');

  // Every request goes through here so the auth header can't be forgotten.
  Future<http.Response> _get(String pathAndQuery) {
    return http.get(
      Uri.parse('$kApiBaseUrl$pathAndQuery'),
      headers: {'Authorization': 'Bearer $kAuthToken'},
    );
  }

  @override
  void initState() {
    super.initState();
    _fetchStatusCounts();
    _fetchEstimates(status: 'All', query: '', page: 1);
  }

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  Future<void> _fetchStatusCounts() async {
    setState(() => isCountsLoading = true);
    try {
      final response = await _get('/api/estimates/status-counts');

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (!mounted) return;
        setState(() {
          _totalEstimatesCount = data['total'] ?? 0;
          _statusCounts = data['counts'] ?? [];
          isCountsLoading = false;
        });
      } else {
        if (!mounted) return;
        setState(() => isCountsLoading = false);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => isCountsLoading = false);
    }
  }

  Future<void> _fetchEstimates({
    required String status,
    required String query,
    required int page,
  }) async {
    if (_pageCache.containsKey(page)) {
      setState(() {
        _displayedEstimates = _pageCache[page]!;
        _currentPage = page;
        isEstimatesLoading = false;
        errorMessage = '';
      });
      _prefetchNextPage(status: status, query: query, nextPage: page + 1);
      return;
    }

    setState(() => isEstimatesLoading = true);
    try {
      final encodedStatus = Uri.encodeComponent(status);
      final encodedQuery = Uri.encodeComponent(query);

      final response = await _get(
        '/api/estimates?status=$encodedStatus&q=$encodedQuery&page=$page&limit=$_pageSize',
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final estimatesList = data['data'] ?? [];

        _pageCache[page] = estimatesList;

        setState(() {
          _displayedEstimates = estimatesList;
          _totalFilteredEstimates = data['total'] ?? 0;
          _currentPage = data['page'] ?? 1;
          _totalPages = data['totalPages'] ?? 1;
          isEstimatesLoading = false;
          errorMessage = '';
        });

        _prefetchNextPage(status: status, query: query, nextPage: page + 1);
      } else {
        setState(() {
          isEstimatesLoading = false;
          errorMessage = 'Server error: ${response.statusCode}';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        isEstimatesLoading = false;
        errorMessage = 'Error connecting to server.';
      });
    }
  }

  Future<void> _prefetchNextPage({
    required String status,
    required String query,
    required int nextPage,
  }) async {
    if (nextPage > _totalPages || _pageCache.containsKey(nextPage)) return;

    try {
      final encodedStatus = Uri.encodeComponent(status);
      final encodedQuery = Uri.encodeComponent(query);

      final response = await _get(
        '/api/estimates?status=$encodedStatus&q=$encodedQuery&page=$nextPage&limit=$_pageSize',
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        _pageCache[nextPage] = data['data'] ?? [];
      }
    } catch (_) {}
  }

  void _onStatusSelected(String statusName) {
    if (_selectedStatus == statusName) return;
    _pageCache.clear();
    setState(() {
      _selectedStatus = statusName;
      _currentPage = 1;
    });
    _fetchEstimates(status: statusName, query: searchController.text, page: 1);
  }

  void _onSearchSubmitted(String query) {
    _pageCache.clear();
    setState(() => _currentPage = 1);
    _fetchEstimates(status: _selectedStatus, query: query, page: 1);
  }

  void _changePage(int newPage) {
    if (newPage < 1 || newPage > _totalPages) return;
    _fetchEstimates(status: _selectedStatus, query: searchController.text, page: newPage);
  }

  void _changePageSize(int newSize) {
    if (newSize == _pageSize) return;
    _pageCache.clear();
    setState(() {
      _pageSize = newSize;
      _currentPage = 1;
    });
    _fetchEstimates(status: _selectedStatus, query: searchController.text, page: 1);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FB),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "All Estimates",
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Color(0xFF1A1C1E)),
            ),
            const SizedBox(height: 24),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildStatusSidebar(),
                  const SizedBox(width: 24),
                  Expanded(
                    child: Card(
                      color: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: const BorderSide(color: Color(0xFFE5E7EB), width: 1),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Search Bar
                          Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: TextField(
                              controller: searchController,
                              onSubmitted: _onSearchSubmitted,
                              decoration: InputDecoration(
                                hintText: 'Search estimates by Customer, Estimate #, or Address...',
                                prefixIcon: const Icon(Icons.search, color: Color(0xFF4B5563)),
                                suffixIcon: IconButton(
                                  icon: const Icon(Icons.arrow_forward, color: Color(0xFFCC0007)),
                                  onPressed: () => _onSearchSubmitted(searchController.text),
                                ),
                                filled: true,
                                fillColor: const Color(0xFFF9FAFB),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
                                ),
                              ),
                            ),
                          ),
                          const Divider(height: 1, color: Color(0xFFE5E7EB)),

                          // Table Area
                          Expanded(
                            child: isEstimatesLoading
                                ? const Center(child: CircularProgressIndicator())
                                : errorMessage.isNotEmpty
                                    ? Center(child: Text(errorMessage, style: const TextStyle(color: Colors.redAccent)))
                                    : _displayedEstimates.isEmpty
                                        ? Center(child: Text("No estimates found for status: $_selectedStatus", style: const TextStyle(color: Color(0xFF4B5563))))
                                        : LayoutBuilder(
                                            builder: (context, constraints) {
                                              return SingleChildScrollView(
                                                scrollDirection: Axis.vertical,
                                                padding: const EdgeInsets.all(16),
                                                child: SingleChildScrollView(
                                                  scrollDirection: Axis.horizontal,
                                                  child: ConstrainedBox(
                                                    constraints: BoxConstraints(
                                                      minWidth: constraints.maxWidth - 32,
                                                    ),
                                                    child: DataTable(
                                                      headingTextStyle: const TextStyle(
                                                        fontWeight: FontWeight.bold,
                                                        fontSize: 16,
                                                        color: Color(0xFF1A1C1E),
                                                      ),
                                                      dataRowMinHeight: 90,
                                                      dataRowMaxHeight: 140,
                                                      columns: const [
                                                        DataColumn(label: Text('Estimate Info')),
                                                        DataColumn(label: Text('Customer & Details')),
                                                        DataColumn(label: Text('Techs Assigned')),
                                                        DataColumn(label: Text('Status')),
                                                      ],
                                                      rows: _displayedEstimates.map((estimate) {
                                                        return DataRow(cells: [
                                                          DataCell(_buildEstimateInfoCell(estimate)),
                                                          DataCell(_buildCustomerInfoCell(estimate)),
                                                          DataCell(
                                                            SizedBox(
                                                              width: 160,
                                                              child: Text(
                                                                estimate['techs_assigned'] ?? 'Unassigned',
                                                                style: const TextStyle(fontSize: 13, color: Color(0xFF1A1C1E)),
                                                              ),
                                                            ),
                                                          ),
                                                          DataCell(_buildStatusBadge(estimate['status'] ?? 'ESTIMATE REQUESTED')),
                                                        ]);
                                                      }).toList(),
                                                    ),
                                                  ),
                                                ),
                                              );
                                            },
                                          ),
                          ),

                          _buildPaginationFooter(),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEstimateInfoCell(dynamic estimate) {
    final String dateStr = estimate['start_date'] != null
        ? DateFormat('MM/dd/yyyy').format(DateTime.parse(estimate['start_date']))
        : 'No Date';
    final String estimateIdStr = '#${estimate['job_id'] ?? estimate['id']}';
    final double revenue = double.tryParse(estimate['total_revenue']?.toString() ?? '0') ?? 0.0;
    final String revenueStr = _currencyFormat.format(revenue);

    return SizedBox(
      width: 120,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            dateStr,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFF1A1C1E)),
          ),
          const SizedBox(height: 2),
          Text(
            estimateIdStr,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.normal, color: Color(0xFF4B5563)),
          ),
          const SizedBox(height: 2),
          Text(
            revenueStr,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF1A7A4A)),
          ),
        ],
      ),
    );
  }

  Widget _buildCustomerInfoCell(dynamic estimate) {
    final String customerName = estimate['customer_name'] ?? 'Unknown Customer';
    final String address = (estimate['location'] != null && estimate['location'].toString().trim().isNotEmpty)
        ? estimate['location'].toString().trim()
        : 'No Address Provided';
    final String? description = estimate['description'];

    return SizedBox(
      width: 320,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            customerName,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF1A1C1E)),
          ),
          const SizedBox(height: 3),
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 2.0),
                child: Icon(Icons.location_on_outlined, size: 14, color: Color(0xFFCC0007)),
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  address,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, color: Color(0xFF4B5563), fontWeight: FontWeight.w400),
                ),
              ),
            ],
          ),
          if (description != null && description.trim().isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(
              description.trim(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: Color(0xFF4B5563), fontWeight: FontWeight.w400),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPaginationFooter() {
    final startItem = _totalFilteredEstimates == 0 ? 0 : ((_currentPage - 1) * _pageSize) + 1;
    final endItem = (_currentPage * _pageSize) > _totalFilteredEstimates ? _totalFilteredEstimates : (_currentPage * _pageSize);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: const BoxDecoration(
        color: Color(0xFFF9FAFB),
        border: Border(top: BorderSide(color: Color(0xFFE5E7EB))),
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(14),
          bottomRight: Radius.circular(14),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                const Text('Rows per page: ', style: TextStyle(color: Color(0xFF4B5563), fontWeight: FontWeight.w500)),
                const SizedBox(width: 8),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment<int>(value: 50, label: Text('50')),
                    ButtonSegment<int>(value: 100, label: Text('100')),
                  ],
                  selected: {_pageSize},
                  onSelectionChanged: (Set<int> selection) {
                    _changePageSize(selection.first);
                  },
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
                const SizedBox(width: 20),
                Text(
                  'Showing $startItem - $endItem of $_totalFilteredEstimates',
                  style: const TextStyle(color: Color(0xFF4B5563), fontWeight: FontWeight.w500),
                ),
              ],
            ),
            const SizedBox(width: 40),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _currentPage > 1 ? () => _changePage(_currentPage - 1) : null,
                  icon: const Icon(Icons.chevron_left, size: 18),
                  label: const Text('Previous'),
                ),
                const SizedBox(width: 16),
                Text(
                  'Page $_currentPage of $_totalPages',
                  style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF1A1C1E)),
                ),
                const SizedBox(width: 16),
                OutlinedButton.icon(
                  onPressed: _currentPage < _totalPages ? () => _changePage(_currentPage + 1) : null,
                  icon: const Icon(Icons.chevron_right, size: 18),
                  label: const Text('Next'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusSidebar() {
    return SizedBox(
      width: 260,
      child: Card(
        color: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: Color(0xFFE5E7EB), width: 1),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16.0),
                child: Text(
                  "Filter by Status",
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF1A1C1E)),
                ),
              ),
              const SizedBox(height: 8),
              const Divider(height: 1, color: Color(0xFFE5E7EB)),
              Expanded(
                child: isCountsLoading
                    ? const Center(child: CircularProgressIndicator())
                    : ListView(
                        children: [
                          _buildSidebarRow('All', _totalEstimatesCount),
                          ..._statusCounts.map((item) {
                            final statusName = item['status'] as String;
                            final count = int.tryParse(item['count'].toString()) ?? 0;
                            return _buildSidebarRow(statusName, count);
                          }),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSidebarRow(String statusName, int count) {
    bool isSelected = _selectedStatus == statusName;
    Color solidStatusColor = statusName == 'All' ? const Color(0xFF0051FF) : getStatusColor(statusName);

    return InkWell(
      onTap: () => _onStatusSelected(statusName),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? solidStatusColor.withValues(alpha: 0.12) : Colors.transparent,
          border: Border(
            left: BorderSide(
              color: isSelected ? solidStatusColor : Colors.transparent,
              width: 4,
            ),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                statusName,
                style: TextStyle(
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                  color: isSelected ? solidStatusColor : const Color(0xFF1A1C1E),
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: solidStatusColor,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                count.toString(),
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBadge(String status) {
    Color solidStatusColor = getStatusColor(status);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: solidStatusColor,
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 2,
            offset: Offset(0, 1),
          ),
        ],
      ),
      child: Text(
        status.toUpperCase(),
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: 11,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}