import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'config/auth_session.dart';

class TechRetainageScreen extends StatefulWidget {
  final String apiBaseUrl;
  final String authToken;
  final String techName; // The logged-in technician's name

  const TechRetainageScreen({
    super.key,
    required this.apiBaseUrl,
    required this.authToken,
    required this.techName,
  });

  @override
  _TechRetainageScreenState createState() => _TechRetainageScreenState();
}

class _TechRetainageScreenState extends State<TechRetainageScreen> {
  bool _isLoading = true;
  double _totalProjected = 0.0;
  List<dynamic> _ledgerItems = [];

  @override
  void initState() {
    super.initState();
    _fetchMyLedger();
  }

  Future<void> _fetchMyLedger() async {
    setState(() => _isLoading = true);
    try {
      final uri = Uri.parse('${widget.apiBaseUrl}/api/retainage/my-ledger?techName=${Uri.encodeComponent(widget.techName)}');
      final response = await http.get(uri, headers: AuthSession.instance.headers());

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        setState(() {
          _totalProjected = double.tryParse(data['totalProjected'].toString()) ?? 0.0;
          _ledgerItems = data['ledger'] ?? [];
          _isLoading = false;
        });
      } else {
        _showError('Failed to load your retainage data.');
      }
    } catch (e) {
      _showError('Network error: $e');
    }
  }

  void _showError(String message) {
    setState(() => _isLoading = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  String _formatDate(String? isoString) {
    if (isoString == null) return 'TBD';
    try {
      final date = DateTime.parse(isoString);
      return '${date.month}/${date.day}/${date.year}';
    } catch (e) {
      return isoString.split('T')[0];
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Commercial Bonus'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _fetchMyLedger),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Hero Banner
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Colors.blue[900],
                    boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2))],
                  ),
                  child: Column(
                    children: [
                      const Text(
                        'TOTAL PROJECTED PAYOUT',
                        style: TextStyle(color: Colors.white70, fontSize: 14, letterSpacing: 1.2),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '\$${_totalProjected.toStringAsFixed(2)}',
                        style: const TextStyle(color: Colors.white, fontSize: 40, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Unlocks quarterly. Subject to warranty callbacks.',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                // Ledger List
                Expanded(
                  child: _ledgerItems.isEmpty
                      ? const Center(child: Text('No pending commercial bonuses.', style: TextStyle(color: Colors.grey)))
                      : ListView.separated(
                          itemCount: _ledgerItems.length,
                          separatorBuilder: (context, index) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final item = _ledgerItems[index];
                            final isDeduction = item['transaction_type'] == 'callback_deduction';
                            final amount = double.tryParse(item['amount'].toString()) ?? 0.0;
                            final unlockDate = _formatDate(item['unlock_date']);

                            return ListTile(
                              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                              leading: CircleAvatar(
                                backgroundColor: isDeduction ? Colors.red[100] : Colors.green[100],
                                child: Icon(
                                  isDeduction ? Icons.warning_amber_rounded : Icons.check_circle_outline,
                                  color: isDeduction ? Colors.red[700] : Colors.green[700],
                                ),
                              ),
                              title: Text(
                                'Job #${item['job_id']}',
                                style: const TextStyle(fontWeight: FontWeight.bold),
                              ),
                              subtitle: Text(
                                isDeduction ? 'Warranty Callback Penalty' : 'Unlocks: $unlockDate',
                                style: TextStyle(color: isDeduction ? Colors.red[700] : Colors.grey[600]),
                              ),
                              trailing: Text(
                                '${isDeduction ? '-' : '+'}\$${amount.abs().toStringAsFixed(2)}',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: isDeduction ? Colors.red : Colors.green,
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}