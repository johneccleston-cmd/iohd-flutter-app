import 'package:flutter/material.dart';

// --- Shared Design Tokens ---
const Color _brandRed = Color(0xFFCC0007);
const Color _inkColor = Color(0xFF181B1F);
const Color _slateColor = Color(0xFF5B6572);
const Color _strokeBorder = Color(0xFFE4E7EC);
const Color _fieldFill = Color(0xFFF6F7F9);

class PurchaseOrdersScreen extends StatefulWidget {
  const PurchaseOrdersScreen({super.key});

  @override
  State<PurchaseOrdersScreen> createState() => _PurchaseOrdersScreenState();
}

class _PurchaseOrdersScreenState extends State<PurchaseOrdersScreen> {
  final TextEditingController _searchController = TextEditingController();
  
  // Dummy data
  final List<Map<String, dynamic>> _mockPOs = [
    {'poNumber': 'PO-2026-1045', 'vendor': 'Amarr Garage Doors', 'date': 'Oct 1, 2026', 'total': 4250.00, 'status': 'Pending'},
    {'poNumber': 'PO-2026-1044', 'vendor': 'Genie Company', 'date': 'Sep 28, 2026', 'total': 1850.00, 'status': 'Fulfilled'},
    {'poNumber': 'PO-2026-1043', 'vendor': 'Action Industries', 'date': 'Sep 25, 2026', 'total': 620.50, 'status': 'Fulfilled'},
    {'poNumber': 'PO-2026-1042', 'vendor': 'Local Fasteners Inc', 'date': 'Sep 22, 2026', 'total': 145.00, 'status': 'Canceled'},
  ];

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Widget _buildMetricCard(String title, String value, IconData icon, {bool alert = false}) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: alert ? Colors.orange.withValues(alpha: 0.5) : _strokeBorder),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.02),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: alert ? Colors.orange.withValues(alpha: 0.1) : _fieldFill,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: alert ? Colors.orange[800] : _slateColor, size: 24),
            ),
            const SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 13, color: _slateColor, fontWeight: FontWeight.w500)),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 24, 
                    fontWeight: FontWeight.w700, 
                    color: alert ? Colors.orange[900] : _inkColor,
                    letterSpacing: -0.5,
                  ),
                ),
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
            // --- Header Row ---
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  "Purchase Orders",
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: _inkColor, letterSpacing: -0.5),
                ),
                ElevatedButton.icon(
                  onPressed: () {},
                  icon: const Icon(Icons.add_rounded, size: 18, color: Colors.white),
                  label: const Text("Create PO", style: TextStyle(fontWeight: FontWeight.w600)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _brandRed,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // --- Metrics Row ---
            Row(
              children: [
                _buildMetricCard("Open Orders", "1", Icons.shopping_cart_outlined, alert: true),
                const SizedBox(width: 16),
                _buildMetricCard("Total Spend (30d)", "\$6,865.50", Icons.attach_money_rounded),
                const SizedBox(width: 16),
                _buildMetricCard("Vendors Used", "4", Icons.storefront_outlined),
              ],
            ),
            const SizedBox(height: 32),

            // --- Main Data Table Container ---
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _strokeBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 300,
                          height: 40,
                          child: TextField(
                            controller: _searchController,
                            style: const TextStyle(fontSize: 14),
                            decoration: InputDecoration(
                              hintText: 'Search PO number or vendor...',
                              hintStyle: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 13),
                              prefixIcon: const Icon(Icons.search, size: 18, color: _slateColor),
                              filled: true,
                              fillColor: _fieldFill,
                              contentPadding: EdgeInsets.zero,
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: _strokeBorder),
                  
                  DataTable(
                    headingTextStyle: const TextStyle(fontWeight: FontWeight.w600, color: _slateColor, fontSize: 12),
                    dataTextStyle: const TextStyle(color: _inkColor, fontSize: 14),
                    dividerThickness: 1,
                    horizontalMargin: 24,
                    columns: const [
                      DataColumn(label: Text('PO NUMBER')),
                      DataColumn(label: Text('VENDOR')),
                      DataColumn(label: Text('DATE CREATED')),
                      DataColumn(label: Text('TOTAL', textAlign: TextAlign.right)),
                      DataColumn(label: Text('STATUS')),
                    ],
                    rows: _mockPOs.map((po) {
                      final status = po['status'] as String;
                      Color statusColor;
                      if (status == 'Pending') statusColor = Colors.orange[700]!;
                      else if (status == 'Fulfilled') statusColor = Colors.green[700]!;
                      else statusColor = _brandRed;

                      return DataRow(
                        cells: [
                          DataCell(Text(po['poNumber'], style: const TextStyle(fontWeight: FontWeight.w600))),
                          DataCell(Text(po['vendor'])),
                          DataCell(Text(po['date'], style: const TextStyle(color: _slateColor))),
                          DataCell(Text('\$${po['total'].toStringAsFixed(2)}')),
                          DataCell(
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: statusColor.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                status,
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: statusColor),
                              ),
                            ),
                          ),
                        ],
                      );
                    }).toList(),
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