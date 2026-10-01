import 'package:flutter/material.dart';

const Color _brandRed = Color(0xFFCC0007);
const Color _inkColor = Color(0xFF181B1F);
const Color _slateColor = Color(0xFF5B6572);
const Color _strokeBorder = Color(0xFFE4E7EC);
const Color _fieldFill = Color(0xFFF6F7F9);

class StatusesScreen extends StatefulWidget {
  const StatusesScreen({super.key});

  @override
  State<StatusesScreen> createState() => _StatusesScreenState();
}

class _StatusesScreenState extends State<StatusesScreen> {
  final TextEditingController _searchController = TextEditingController();
  
  final List<Map<String, dynamic>> _mockData = [
    {'id': 'JOB-1042', 'type': 'Job', 'customer': 'Sarah Jenkins', 'tech': 'Ryan M.', 'status': 'In Progress'},
    {'id': 'EST-2099', 'type': 'Estimate', 'customer': 'Bob Vance', 'tech': 'Unassigned', 'status': 'Pending Approval'},
    {'id': 'JOB-1041', 'type': 'Job', 'customer': 'Acme Corp', 'tech': 'Alex T.', 'status': 'Part Ordered'},
  ];

  Widget _buildMetricCard(String title, String value, IconData icon, {bool alert = false}) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white, borderRadius: BorderRadius.circular(12),
          border: Border.all(color: alert ? Colors.orange.withValues(alpha: 0.5) : _strokeBorder),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: alert ? Colors.orange.withValues(alpha: 0.1) : _fieldFill, borderRadius: BorderRadius.circular(8)),
              child: Icon(icon, color: alert ? Colors.orange[800] : _slateColor, size: 24),
            ),
            const SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 13, color: _slateColor, fontWeight: FontWeight.w500)),
                const SizedBox(height: 4),
                Text(value, style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: alert ? Colors.orange[900] : _inkColor, letterSpacing: -0.5)),
              ],
            ),
          ],
        ),
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
            const Text("Estimate & Job Statuses", style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: _inkColor, letterSpacing: -0.5)),
            const SizedBox(height: 24),
            Row(
              children: [
                _buildMetricCard("Active Jobs", "12", Icons.build_outlined),
                const SizedBox(width: 16),
                _buildMetricCard("Pending Estimates", "5", Icons.hourglass_empty_rounded, alert: true),
                const SizedBox(width: 16),
                _buildMetricCard("Parts Ordered", "3", Icons.local_shipping_outlined),
              ],
            ),
            const SizedBox(height: 32),
            Container(
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: _strokeBorder)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: 'Search ID or Customer...', prefixIcon: const Icon(Icons.search, size: 18),
                        filled: true, fillColor: _fieldFill, border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                        constraints: const BoxConstraints(maxWidth: 300, maxHeight: 40), contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                  const Divider(height: 1, color: _strokeBorder),
                  DataTable(
                    headingTextStyle: const TextStyle(fontWeight: FontWeight.w600, color: _slateColor, fontSize: 12),
                    columns: const [DataColumn(label: Text('ID')), DataColumn(label: Text('TYPE')), DataColumn(label: Text('CUSTOMER')), DataColumn(label: Text('TECH')), DataColumn(label: Text('STATUS'))],
                    rows: _mockData.map((d) => DataRow(cells: [
                      DataCell(Text(d['id'], style: const TextStyle(fontWeight: FontWeight.w600))),
                      DataCell(Text(d['type'])), DataCell(Text(d['customer'])), DataCell(Text(d['tech'])),
                      DataCell(Text(d['status'], style: TextStyle(color: d['status'] == 'In Progress' ? Colors.green[700] : _slateColor, fontWeight: FontWeight.w600))),
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