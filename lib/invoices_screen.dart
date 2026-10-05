import 'package:flutter/material.dart';
import 'config/access.dart';
import 'config/auth_session.dart';

const Color _brandRed = Color(0xFFCC0007);
const Color _inkColor = Color(0xFF181B1F);
const Color _slateColor = Color(0xFF5B6572);
const Color _strokeBorder = Color(0xFFE4E7EC);
const Color _fieldFill = Color(0xFFF6F7F9);

class InvoicesScreen extends StatefulWidget {
  const InvoicesScreen({super.key});
  @override State<InvoicesScreen> createState() => _InvoicesScreenState();
}

class _InvoicesScreenState extends State<InvoicesScreen> {
  final TextEditingController _searchController = TextEditingController();
  final List<Map<String, dynamic>> _mockInvoices = [
    {'id': 'INV-4011', 'customer': 'Walton Logistics', 'date': 'Sep 15, 2026', 'due': 'Oct 15, 2026', 'amount': 8500.00, 'status': 'Sent'},
    {'id': 'INV-4010', 'customer': 'Bob Vance', 'date': 'Sep 1, 2026', 'due': 'Oct 1, 2026', 'amount': 1200.00, 'status': 'Overdue'},
  ];

  Widget _buildMetricCard(String title, String value, IconData icon, {bool alert = false}) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(20), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: alert ? _brandRed.withValues(alpha: 0.5) : _strokeBorder)),
        child: Row(children: [
          Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: alert ? _brandRed.withValues(alpha: 0.1) : _fieldFill, borderRadius: BorderRadius.circular(8)), child: Icon(icon, color: alert ? _brandRed : _slateColor, size: 24)),
          const SizedBox(width: 16),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: 13, color: _slateColor, fontWeight: FontWeight.w500)),
            const SizedBox(height: 4),
            Text(value, style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: alert ? _brandRed : _inkColor, letterSpacing: -0.5)),
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
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("Invoices", style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: _inkColor, letterSpacing: -0.5)),
                if (AuthSession.instance.can('invoices', AccessAction.create)) ElevatedButton.icon(onPressed: () {}, icon: const Icon(Icons.add, color: Colors.white, size: 18), label: const Text("Create Invoice", style: TextStyle(fontWeight: FontWeight.w600, color: Colors.white)), style: ElevatedButton.styleFrom(backgroundColor: _brandRed, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)))),
              ],
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                _buildMetricCard("Awaiting Payment", "\$8,500.00", Icons.hourglass_top_rounded),
                const SizedBox(width: 16),
                _buildMetricCard("Overdue", "\$1,200.00", Icons.warning_amber_rounded, alert: true),
                const SizedBox(width: 16),
                _buildMetricCard("Paid (30d)", "\$34,500.00", Icons.check_circle_outline),
              ],
            ),
            const SizedBox(height: 32),
            Container(
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: _strokeBorder)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(padding: const EdgeInsets.all(16), child: TextField(controller: _searchController, decoration: InputDecoration(hintText: 'Search invoices...', prefixIcon: const Icon(Icons.search, size: 18), filled: true, fillColor: _fieldFill, border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none), constraints: const BoxConstraints(maxWidth: 300, maxHeight: 40), contentPadding: EdgeInsets.zero))),
                  const Divider(height: 1, color: _strokeBorder),
                  DataTable(
                    headingTextStyle: const TextStyle(fontWeight: FontWeight.w600, color: _slateColor, fontSize: 12),
                    columns: const [DataColumn(label: Text('INVOICE')), DataColumn(label: Text('CUSTOMER')), DataColumn(label: Text('ISSUED')), DataColumn(label: Text('DUE')), DataColumn(label: Text('AMOUNT', textAlign: TextAlign.right)), DataColumn(label: Text('STATUS'))],
                    rows: _mockInvoices.map((i) => DataRow(cells: [
                      DataCell(Text(i['id'], style: const TextStyle(fontWeight: FontWeight.w600))), DataCell(Text(i['customer'])), DataCell(Text(i['date'])), DataCell(Text(i['due'], style: const TextStyle(color: _slateColor))), DataCell(Text('\$${i['amount'].toStringAsFixed(2)}')),
                      DataCell(Text(i['status'], style: TextStyle(color: i['status'] == 'Overdue' ? _brandRed : Colors.orange[700], fontWeight: FontWeight.w600))),
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