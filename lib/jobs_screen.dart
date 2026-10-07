import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:intl/intl.dart';
import 'config/api_config.dart';
import 'utils/status_colors.dart';
import 'config/auth_session.dart';

class JobsScreen extends StatefulWidget {
  const JobsScreen({super.key});

  @override
  State<JobsScreen> createState() => _JobsScreenState();
}

class _JobsScreenState extends State<JobsScreen> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  List<dynamic> _displayedJobs = [];
  bool isJobsLoading = true;
  bool isCountsLoading = true;
  String errorMessage = '';
  TextEditingController searchController = TextEditingController();

  // Status Filter State
  String _selectedStatus = 'All';
  int _totalJobsCount = 0;
  List<dynamic> _statusCounts = [];

  // Pagination & Prefetching State
  int _currentPage = 1;
  int _totalPages = 1;
  int _totalFilteredJobs = 0;
  int _pageSize = 100;

  final Map<int, List<dynamic>> _pageCache = {};
  final NumberFormat _currencyFormat = NumberFormat.currency(symbol: '\$');

  // Every request goes through here so the auth header can't be forgotten.
  Future<http.Response> _get(String pathAndQuery) {
    return http.get(
      Uri.parse('$kApiBaseUrl$pathAndQuery'),
      headers: AuthSession.instance.headers(json: false),
    );
  }

  @override
  void initState() {
    super.initState();
    _fetchStatusCounts();
    _fetchJobs(status: 'All', query: '', page: 1);
  }

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  Future<void> _fetchStatusCounts() async {
    setState(() => isCountsLoading = true);
    try {
      final response = await _get('/api/jobs/status-counts');

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (!mounted) return;
        setState(() {
          _totalJobsCount = data['total'] ?? 0;
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

  Future<void> _fetchJobs({
    required String status,
    required String query,
    required int page,
  }) async {
    if (_pageCache.containsKey(page)) {
      setState(() {
        _displayedJobs = _pageCache[page]!;
        _currentPage = page;
        isJobsLoading = false;
        errorMessage = '';
      });
      _prefetchNextPage(status: status, query: query, nextPage: page + 1);
      return;
    }

    setState(() => isJobsLoading = true);
    try {
      final encodedStatus = Uri.encodeComponent(status);
      final encodedQuery = Uri.encodeComponent(query);

      final response = await _get(
        '/api/jobs?status=$encodedStatus&q=$encodedQuery&page=$page&limit=$_pageSize',
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final jobsList = data['data'] ?? [];

        _pageCache[page] = jobsList;

        setState(() {
          _displayedJobs = jobsList;
          _totalFilteredJobs = data['total'] ?? 0;
          _currentPage = data['page'] ?? 1;
          _totalPages = data['totalPages'] ?? 1;
          isJobsLoading = false;
          errorMessage = '';
        });

        _prefetchNextPage(status: status, query: query, nextPage: page + 1);
      } else {
        setState(() {
          isJobsLoading = false;
          errorMessage = 'Server error: ${response.statusCode}';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        isJobsLoading = false;
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
        '/api/jobs?status=$encodedStatus&q=$encodedQuery&page=$nextPage&limit=$_pageSize',
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
    _fetchJobs(status: statusName, query: searchController.text, page: 1);
  }

  void _onSearchSubmitted(String query) {
    _pageCache.clear();
    setState(() => _currentPage = 1);
    _fetchJobs(status: _selectedStatus, query: query, page: 1);
  }

  void _changePage(int newPage) {
    if (newPage < 1 || newPage > _totalPages) return;
    _fetchJobs(status: _selectedStatus, query: searchController.text, page: newPage);
  }

  void _changePageSize(int newSize) {
    if (newSize == _pageSize) return;
    _pageCache.clear();
    setState(() {
      _pageSize = newSize;
      _currentPage = 1;
    });
    _fetchJobs(status: _selectedStatus, query: searchController.text, page: 1);
  }

  Color _getStatusColor(String status) => statusColor(status);

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Page Header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Job Management",
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0F172A),
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      "Filter, search, and manage ongoing job operations",
                      style: TextStyle(fontSize: 13, color: Color(0xFF64748B), fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: Color(0xFF10B981),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '$_totalJobsCount Total System Jobs',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF334155)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildStatusSidebar(),
                  const SizedBox(width: 20),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF0F172A).withValues(alpha: 0.03),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Search Bar Header
                          Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: TextField(
                              controller: searchController,
                              onSubmitted: _onSearchSubmitted,
                              style: const TextStyle(fontSize: 14, color: Color(0xFF0F172A)),
                              decoration: InputDecoration(
                                hintText: 'Search jobs by customer name, job #, address, or description...',
                                hintStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                                prefixIcon: const Icon(Icons.search_rounded, color: Color(0xFF64748B), size: 20),
                                suffixIcon: IconButton(
                                  icon: const Icon(Icons.arrow_forward_rounded, color: Color(0xFF2563EB), size: 18),
                                  onPressed: () => _onSearchSubmitted(searchController.text),
                                ),
                                filled: true,
                                fillColor: const Color(0xFFF8FAFC),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: const BorderSide(color: Color(0xFF2563EB), width: 1.5),
                                ),
                              ),
                            ),
                          ),
                          const Divider(height: 1, color: Color(0xFFE2E8F0)),

                          // Table Area
                          Expanded(
                            child: isJobsLoading
                                ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
                                : errorMessage.isNotEmpty
                                    ? Center(child: Text(errorMessage, style: const TextStyle(color: Colors.redAccent)))
                                    : _displayedJobs.isEmpty
                                        ? Center(
                                            child: Text(
                                              "No jobs found for status: $_selectedStatus",
                                              style: const TextStyle(color: Color(0xFF64748B), fontWeight: FontWeight.w500),
                                            ),
                                          )
                                        : LayoutBuilder(
                                            builder: (context, constraints) {
                                              return SingleChildScrollView(
                                                scrollDirection: Axis.vertical,
                                                child: SingleChildScrollView(
                                                  scrollDirection: Axis.horizontal,
                                                  child: ConstrainedBox(
                                                    constraints: BoxConstraints(
                                                      minWidth: constraints.maxWidth,
                                                    ),
                                                    child: DataTable(
                                                      headingRowColor: WidgetStateProperty.all(const Color(0xFFF8FAFC)),
                                                      headingTextStyle: const TextStyle(
                                                        fontWeight: FontWeight.w700,
                                                        fontSize: 12,
                                                        color: Color(0xFF475569),
                                                        letterSpacing: 0.5,
                                                      ),
                                                      dataRowMinHeight: 80,
                                                      dataRowMaxHeight: 120,
                                                      horizontalMargin: 20,
                                                      columnSpacing: 28,
                                                      columns: const [
                                                        DataColumn(label: Text('JOB INFO')),
                                                        DataColumn(label: Text('CUSTOMER & LOCATION')),
                                                        DataColumn(label: Text('TECHS ASSIGNED')),
                                                        DataColumn(label: Text('STATUS')),
                                                      ],
                                                      rows: _displayedJobs.map((job) {
                                                        return DataRow(cells: [
                                                          DataCell(_buildJobInfoCell(job)),
                                                          DataCell(_buildCustomerInfoCell(job)),
                                                          DataCell(
                                                            SizedBox(
                                                              width: 150,
                                                              child: Text(
                                                                job['techs_assigned'] ?? 'Unassigned',
                                                                style: const TextStyle(fontSize: 13, color: Color(0xFF334155), fontWeight: FontWeight.w500),
                                                              ),
                                                            ),
                                                          ),
                                                          DataCell(_buildStatusBadge(job['status'] ?? 'PENDING')),
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

  Widget _buildJobInfoCell(dynamic job) {
    final String dateStr = job['start_date'] != null
        ? DateFormat('MMM dd, yyyy').format(DateTime.parse(job['start_date']))
        : 'No Date';
    final String jobIdStr = '#${job['job_id']}';
    final double revenue = double.tryParse(job['total_revenue']?.toString() ?? '0') ?? 0.0;
    final String revenueStr = _currencyFormat.format(revenue);

    return SizedBox(
      width: 130,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            dateStr,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF0F172A)),
          ),
          const SizedBox(height: 3),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFFF1F5F9),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              jobIdStr,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF475569)),
            ),
          ),
          const SizedBox(height: 3),
          Text(
            revenueStr,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: Color(0xFF059669)),
          ),
        ],
      ),
    );
  }

  Widget _buildCustomerInfoCell(dynamic job) {
    final String customerName = job['customer_name'] ?? 'Unknown Customer';
    final String address = (job['location'] != null && job['location'].toString().trim().isNotEmpty)
        ? job['location'].toString().trim()
        : 'No Address Provided';
    final String? description = job['description'];

    return SizedBox(
      width: 320,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            customerName,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
          ),
          const SizedBox(height: 3),
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 2.0),
                child: Icon(Icons.location_on_outlined, size: 14, color: Color(0xFF64748B)),
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  address,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Color(0xFF64748B), fontWeight: FontWeight.w400),
                ),
              ),
            ],
          ),
          if (description != null && description.trim().isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              description.trim(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8), fontWeight: FontWeight.w400),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPaginationFooter() {
    final startItem = _totalFilteredJobs == 0 ? 0 : ((_currentPage - 1) * _pageSize) + 1;
    final endItem = (_currentPage * _pageSize) > _totalFilteredJobs ? _totalFilteredJobs : (_currentPage * _pageSize);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: const BoxDecoration(
        color: Color(0xFFF8FAFC),
        border: Border(top: BorderSide(color: Color(0xFFE2E8F0))),
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(16),
          bottomRight: Radius.circular(16),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              const Text('Rows per page: ', style: TextStyle(color: Color(0xFF64748B), fontSize: 13, fontWeight: FontWeight.w500)),
              const SizedBox(width: 8),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment<int>(value: 50, label: Text('50', style: TextStyle(fontSize: 12))),
                  ButtonSegment<int>(value: 100, label: Text('100', style: TextStyle(fontSize: 12))),
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
              const SizedBox(width: 16),
              Text(
                'Showing $startItem - $endItem of $_totalFilteredJobs',
                style: const TextStyle(color: Color(0xFF64748B), fontSize: 13, fontWeight: FontWeight.w500),
              ),
            ],
          ),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _currentPage > 1 ? () => _changePage(_currentPage - 1) : null,
                icon: const Icon(Icons.chevron_left, size: 16),
                label: const Text('Previous', style: TextStyle(fontSize: 13)),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  side: const BorderSide(color: Color(0xFFCBD5E1)),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                'Page $_currentPage of $_totalPages',
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: Color(0xFF0F172A)),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: _currentPage < _totalPages ? () => _changePage(_currentPage + 1) : null,
                icon: const Icon(Icons.chevron_right, size: 16),
                label: const Text('Next', style: TextStyle(fontSize: 13)),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  side: const BorderSide(color: Color(0xFFCBD5E1)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatusSidebar() {
    return Container(
      width: 260,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0F172A).withValues(alpha: 0.03),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text(
              "Filter by Status",
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
            ),
          ),
          const Divider(height: 1, color: Color(0xFFE2E8F0)),
          Expanded(
            child: isCountsLoading
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
                : ListView(
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                    children: [
                      _buildSidebarRow('All', _totalJobsCount),
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
    );
  }

  Widget _buildSidebarRow(String statusName, int count) {
    bool isSelected = _selectedStatus == statusName;
    Color statusColor = statusName == 'All' ? const Color(0xFF2563EB) : _getStatusColor(statusName);

    return Padding(
      padding: const EdgeInsets.only(bottom: 4.0),
      child: InkWell(
        onTap: () => _onStatusSelected(statusName),
        borderRadius: BorderRadius.circular(10),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: isSelected ? statusColor.withValues(alpha: 0.1) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected ? statusColor.withValues(alpha: 0.3) : Colors.transparent,
              width: 1,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  statusName,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                    color: isSelected ? statusColor : const Color(0xFF334155),
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: isSelected ? statusColor : const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  count.toString(),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: isSelected ? Colors.white : const Color(0xFF64748B),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusBadge(String status) {
    Color statusColor = _getStatusColor(status);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: statusColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: statusColor.withValues(alpha: 0.3), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: statusColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            status.toUpperCase(),
            style: TextStyle(
              color: statusColor,
              fontWeight: FontWeight.w800,
              fontSize: 10,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}