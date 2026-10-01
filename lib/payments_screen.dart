import 'package:flutter/material.dart';

const Color _brandRed = Color(0xFFCC0007);
const Color _inkColor = Color(0xFF181B1F);
const Color _slateColor = Color(0xFF5B6572);
const Color _strokeBorder = Color(0xFFE4E7EC);
const Color _fieldFill = Color(0xFFF6F7F9);

class PaymentsScreen extends StatefulWidget {
  const PaymentsScreen({super.key});
  @override State<PaymentsScreen> createState() => _PaymentsScreenState();
}

class _PaymentsScreenState extends State<PaymentsScreen> {
  final TextEditingController _searchController = TextEditingController();
  final List<Map<String, dynamic>> _mockPayments = [
    {'id': 'PAY-8922', 'customer': 'Sarah Jenkins', 'date': 'Oct 1, 2026', 'method': 'Credit Card', 'amount': 450.00, 'status': 'Succeeded'},
    {'id': 'PAY-8921', 'customer': 'Acme Corp', 'date': 'Oct 1, 2026', 'method': 'ACH', 'amount': 2100.00, 'status': 'Processing'},
  ];

  Widget _buildMetricCard(String title, String value, IconData icon) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: _strokeBorder)),
        child: Row(children: [
          Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: _fieldFill, borderRadius: BorderRadius.circular(8)), child: Icon(icon, color: _slateColor, size: 24)),
          const SizedBox(width: 16),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: 13, color: _slateColor, fontWeight: FontWeight.w500)),
            const SizedBox(height: 4),
            Text(value, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: _inkColor, letterSpacing: -0.5)),
          ]),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFAFAFA),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("Payments", style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: _inkColor, letterSpacing: -0.5)),
            const SizedBox(height: 24),
            Row(
              children: [
                _buildMetricCard("Collected Today", "\$2,550.00", Icons.payments_outlined),
                const SizedBox(width: 16),
                _buildMetricCard("Processing (ACH)", "\$2,100.00", Icons.sync_rounded),
                const SizedBox(width: 16),
                _buildMetricCard("Failed (7d)", "0", Icons.error_outline),
              ],
            ),
            const SizedBox(height: 32),
            Container(
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: _strokeBorder)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(padding: const EdgeInsets.all(16), child: TextField(controller: _searchController, decoration: InputDecoration(hintText: 'Search payments...', prefixIcon: const Icon(Icons.search, size: 18), filled: true, fillColor: _fieldFill, border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none), constraints: const BoxConstraints(maxWidth: 300, maxHeight: 40), contentPadding: EdgeInsets.zero))),
                  const Divider(height: 1, color: _strokeBorder),
                  DataTable(
                    headingTextStyle: const TextStyle(fontWeight: FontWeight.w600, color: _slateColor, fontSize: 12),
                    columns: const [DataColumn(label: Text('RECEIPT ID')), DataColumn(label: Text('CUSTOMER')), DataColumn(label: Text('METHOD')), DataColumn(label: Text('DATE')), DataColumn(label: Text('AMOUNT', textAlign: TextAlign.right)), DataColumn(label: Text('STATUS'))],
                    rows: _mockPayments.map((p) => DataRow(cells: [
                      DataCell(Text(p['id'], style: const TextStyle(fontWeight: FontWeight.w600))), DataCell(Text(p['customer'])), DataCell(Text(p['method'])), DataCell(Text(p['date'])), DataCell(Text('\$${p['amount'].toStringAsFixed(2)}')),
                      DataCell(Text(p['status'], style: TextStyle(color: p['status'] == 'Succeeded' ? Colors.green[700] : Colors.orange[700], fontWeight: FontWeight.w600))),
                    ])).toList(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}