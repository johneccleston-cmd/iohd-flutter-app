import 'package:flutter/material.dart';

// --- Shared Design Tokens ---
const Color _brandRed = Color(0xFFCC0007);
const Color _inkColor = Color(0xFF181B1F);
const Color _slateColor = Color(0xFF5B6572);
const Color _strokeBorder = Color(0xFFE4E7EC);
const Color _fieldFill = Color(0xFFF6F7F9);

class VendorsScreen extends StatefulWidget {
  const VendorsScreen({super.key});

  @override
  State<VendorsScreen> createState() => _VendorsScreenState();
}

class _VendorsScreenState extends State<VendorsScreen> {
  final TextEditingController _searchController = TextEditingController();
  
  // Dummy data
  final List<Map<String, dynamic>> _mockVendors = [
    {'name': 'Amarr Garage Doors', 'contact': 'sales@amarr.com', 'phone': '(800) 503-3667', 'terms': 'Net 30', 'active': true},
    {'name': 'Genie Company', 'contact': 'orders@genie.com', 'phone': '(800) 843-4084', 'terms': 'Net 15', 'active': true},
    {'name': 'Action Industries', 'contact': 'j.smith@action.com', 'phone': '(800) 321-1130', 'terms': 'Due on Receipt', 'active': true},
    {'name': 'Local Fasteners Inc', 'contact': 'bob@localfasteners.com', 'phone': '(479) 555-0199', 'terms': 'COD', 'active': false},
  ];

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Widget _buildMetricCard(String title, String value, IconData icon) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _strokeBorder),
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
                color: _fieldFill,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: _slateColor, size: 24),
            ),
            const SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 13, color: _slateColor, fontWeight: FontWeight.w500)),
                const SizedBox(height: 4),
                Text(value, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: _inkColor, letterSpacing: -0.5)),
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
                  "Vendors",
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: _inkColor, letterSpacing: -0.5),
                ),
                ElevatedButton.icon(
                  onPressed: () {},
                  icon: const Icon(Icons.add_rounded, size: 18, color: Colors.white),
                  label: const Text("New Vendor", style: TextStyle(fontWeight: FontWeight.w600)),
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
                _buildMetricCard("Total Vendors", "4", Icons.storefront_outlined),
                const SizedBox(width: 16),
                _buildMetricCard("Active Suppliers", "3", Icons.handshake_outlined),
                const SizedBox(width: 16),
                _buildMetricCard("Net 30 Terms", "1", Icons.account_balance_wallet_outlined),
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
                              hintText: 'Search vendors...',
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
                      DataColumn(label: Text('VENDOR NAME')),
                      DataColumn(label: Text('EMAIL / CONTACT')),
                      DataColumn(label: Text('PHONE')),
                      DataColumn(label: Text('TERMS')),
                      DataColumn(label: Text('STATUS')),
                    ],
                    rows: _mockVendors.map((vendor) {
                      final isActive = vendor['active'] as bool;

                      return DataRow(
                        cells: [
                          DataCell(Text(vendor['name'], style: const TextStyle(fontWeight: FontWeight.w600))),
                          DataCell(Text(vendor['contact'])),
                          DataCell(Text(vendor['phone'], style: const TextStyle(color: _slateColor))),
                          DataCell(Text(vendor['terms'])),
                          DataCell(
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: isActive ? Colors.green.withValues(alpha: 0.1) : _slateColor.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                isActive ? 'Active' : 'Inactive',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: isActive ? Colors.green[700] : _slateColor,
                                ),
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