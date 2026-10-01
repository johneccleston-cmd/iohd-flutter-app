import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class AdminRetainageScreen extends StatefulWidget {
  final String apiBaseUrl; // e.g., 'http://localhost:3000'
  final String authToken;

  const AdminRetainageScreen({
    Key? key,
    required this.apiBaseUrl,
    required this.authToken,
  }) : super(key: key);

  @override
  _AdminRetainageScreenState createState() => _AdminRetainageScreenState();
}

class _AdminRetainageScreenState extends State<AdminRetainageScreen> {
  bool _isLoading = true;
  List<dynamic> _retainageData = [];

  @override
  void initState() {
    super.initState();
    _fetchRetainageData();
  }

  Future<void> _fetchRetainageData() async {
    setState(() => _isLoading = true);
    try {
      final response = await http.get(
        Uri.parse('${widget.apiBaseUrl}/api/retainage/ready-for-release'),
        headers: {'Authorization': 'Bearer ${widget.authToken}'},
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        setState(() {
          _retainageData = data['data'] ?? [];
          _isLoading = false;
        });
      } else {
        _showError('Failed to load retainage data.');
      }
    } catch (e) {
      _showError('Network error: $e');
    }
  }

  Future<void> _confirmAndRelease(String techName) async {
    // 1. Show confirmation dialog before moving money
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm Release'),
        content: Text('Are you sure you want to release quarterly funds for $techName? This will add the bonus to their current payroll report.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CANCEL'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('CONFIRM & RELEASE'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    // 2. Execute the POST request
    try {
      final response = await http.post(
        Uri.parse('${widget.apiBaseUrl}/api/retainage/confirm-release'),
        headers: {
          'Authorization': 'Bearer ${widget.authToken}',
          'Content-Type': 'application/json',
        },
        body: json.encode({'techName': techName}),
      );

      final result = json.decode(response.body);

      if (response.statusCode == 200 && result['success']) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result['message']),
            backgroundColor: Colors.green,
          ),
        );
        _fetchRetainageData(); // Refresh the list to remove the paid tech
      } else {
        _showError(result['error'] ?? 'Failed to release funds.');
      }
    } catch (e) {
      _showError('Network error: $e');
    }
  }

  void _showDetailsDialog(String techName, List<dynamic> details) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('$techName - Qtr Breakdown'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: details.length,
            separatorBuilder: (_, __) => const Divider(),
            itemBuilder: (context, index) {
              final item = details[index];
              final isDeduction = item['type'] == 'callback_deduction';
              final amount = double.tryParse(item['amount'].toString()) ?? 0.0;
              
              return ListTile(
                title: Text('Job #${item['job_id']}'),
                subtitle: Text(isDeduction ? 'Warranty Callback' : 'Initial Deposit'),
                trailing: Text(
                  '${isDeduction ? '-' : ''}\$${amount.abs().toStringAsFixed(2)}',
                  style: TextStyle(
                    color: isDeduction ? Colors.red : Colors.green,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CLOSE'),
          ),
        ],
      ),
    );
  }

  void _showError(String message) {
    setState(() => _isLoading = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Quarterly Retainage Release'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchRetainageData,
          )
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _retainageData.isEmpty
              ? const Center(child: Text('No eligible funds ready for release.'))
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _retainageData.length,
                  itemBuilder: (context, index) {
                    final row = _retainageData[index];
                    final techName = row['tech_name'];
                    final netPayout = double.tryParse(row['net_payout'].toString()) ?? 0.0;
                    final totalWithheld = double.tryParse(row['total_withheld'].toString()) ?? 0.0;
                    final totalDeducted = double.tryParse(row['total_deducted'].toString()) ?? 0.0;

                    return Card(
                      elevation: 3,
                      margin: const EdgeInsets.only(bottom: 16),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Header Row
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  techName,
                                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                                ),
                                Text(
                                  '\$${netPayout.toStringAsFixed(2)}',
                                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Colors.green),
                                ),
                              ],
                            ),
                            const Divider(height: 24),
                            // Stats Row
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('Eligible Jobs: ${row['eligible_jobs']}'),
                                Text('Deposits: \$${totalWithheld.toStringAsFixed(2)}'),
                                Text('Callbacks: -\$${totalDeducted.abs().toStringAsFixed(2)}', style: const TextStyle(color: Colors.red)),
                              ],
                            ),
                            const SizedBox(height: 16),
                            // Action Buttons
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                OutlinedButton(
                                  onPressed: () => _showDetailsDialog(techName, row['details']),
                                  child: const Text('VIEW DETAILS'),
                                ),
                                const SizedBox(width: 12),
                                ElevatedButton(
                                  style: ElevatedButton.styleFrom(backgroundColor: Colors.blue[900]),
                                  onPressed: () => _confirmAndRelease(techName),
                                  child: const Text('CONFIRM & RELEASE', style: TextStyle(color: Colors.white)),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}