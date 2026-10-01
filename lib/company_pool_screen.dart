// Change line 1 of lib/company_pool_screen.dart:
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class CompanyPoolScreen extends StatefulWidget {
  final String apiBaseUrl;
  final String authToken;

  const CompanyPoolScreen({
    Key? key,
    required this.apiBaseUrl,
    required this.authToken,
  }) : super(key: key);

  @override
  _CompanyPoolScreenState createState() => _CompanyPoolScreenState();
}

class _CompanyPoolScreenState extends State<CompanyPoolScreen> {
  bool _isLoading = true;
  double _totalBalance = 0.0;
  List<dynamic> _ledgerItems = [];

  @override
  void initState() {
    super.initState();
    _fetchCompanyPool();
  }

  Future<void> _fetchCompanyPool() async {
    setState(() => _isLoading = true);
    try {
      final response = await http.get(
        Uri.parse('${widget.apiBaseUrl}/api/retainage/company-pool'),
        headers: {'Authorization': 'Bearer ${widget.authToken}'},
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        setState(() {
          _totalBalance = double.tryParse(data['balance'].toString()) ?? 0.0;
          _ledgerItems = data['ledger'] ?? [];
          _isLoading = false;
        });
      } else {
        _showError('Failed to load company pool data.');
      }
    } catch (e) {
      _showError('Network error: $e');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() => _isLoading = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  String _formatCurrency(double amount) {
    final reg = RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))');
    final mathFunc = (Match match) => '${match[1]},';
    return '\$' + amount.toStringAsFixed(2).replaceAllMapped(reg, mathFunc);
  }

  String _formatDate(String? isoString) {
    if (isoString == null) return 'Unknown Date';
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
        title: const Text('1% Company Warranty Pool'),
        backgroundColor: Colors.blueGrey[900],
        foregroundColor: Colors.white,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _fetchCompanyPool),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Hero Balance Card
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
                  decoration: BoxDecoration(
                    color: Colors.blueGrey[800],
                    boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2))],
                  ),
                  child: Column(
                    children: [
                      const Text(
                        'TOTAL AVAILABLE FUNDS',
                        style: TextStyle(color: Colors.white70, fontSize: 14, letterSpacing: 1.5),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _formatCurrency(_totalBalance),
                        style: const TextStyle(color: Colors.white, fontSize: 48, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Virtual reserve for general callbacks & warranties.',
                        style: TextStyle(color: Colors.white54, fontSize: 13),
                      ),
                    ],
                  ),
                ),
                // Transaction Ledger
                Container(
                  padding: const EdgeInsets.all(16),
                  alignment: Alignment.centerLeft,
                  child: const Text(
                    'RECENT TRANSACTIONS',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.grey),
                  ),
                ),
                Expanded(
                  child: _ledgerItems.isEmpty
                      ? const Center(child: Text('No transactions found.'))
                      : ListView.separated(
                          itemCount: _ledgerItems.length,
                          separatorBuilder: (context, index) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final item = _ledgerItems[index];
                            final isDeduction = item['transaction_type'] == 'callback_deduction';
                            final amount = double.tryParse(item['amount'].toString()) ?? 0.0;
                            final date = _formatDate(item['created_at']);

                            return ListTile(
                              leading: CircleAvatar(
                                backgroundColor: isDeduction ? Colors.red[50] : Colors.blueGrey[50],
                                child: Icon(
                                  isDeduction ? Icons.money_off : Icons.account_balance_wallet,
                                  color: isDeduction ? Colors.red[700] : Colors.blueGrey[700],
                                ),
                              ),
                              title: Text(
                                'Job #${item['job_id']}',
                                style: const TextStyle(fontWeight: FontWeight.bold),
                              ),
                              subtitle: Text(date),
                              trailing: Text(
                                '${isDeduction ? '' : '+'}${_formatCurrency(amount)}',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: isDeduction ? Colors.red : Colors.green[700],
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