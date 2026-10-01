import 'package:flutter/material.dart';

// --- Shared Design Tokens ---
const Color _brandRed = Color(0xFFCC0007);
const Color _inkColor = Color(0xFF181B1F);
const Color _slateColor = Color(0xFF5B6572);
const Color _strokeBorder = Color(0xFFE4E7EC);
const Color _fieldFill = Color(0xFFF6F7F9);

class ProductCatalogScreen extends StatefulWidget {
  const ProductCatalogScreen({super.key});

  @override
  State<ProductCatalogScreen> createState() => _ProductCatalogScreenState();
}

class _ProductCatalogScreenState extends State<ProductCatalogScreen> {
  final TextEditingController _searchController = TextEditingController();
  
  // Dummy data - replace with your actual API fetch logic later
  final List<Map<String, dynamic>> _mockProducts = [
    {'name': 'Gallery Steel 16x7 White', 'sku': 'GS-167-WH', 'category': 'Doors', 'cost': 485.00, 'retail': 850.00, 'active': true},
    {'name': '7\' Opener 2128 Chain', 'sku': 'GEN-2128-7', 'category': 'Operators', 'cost': 145.00, 'retail': 350.00, 'active': true},
    {'name': 'Nylon Rollers (10pk)', 'sku': 'HW-NRL-10', 'category': 'Hardware', 'cost': 8.50, 'retail': 25.00, 'active': true},
    {'name': 'Legacy Wood 16x7 Custom', 'sku': 'LW-167-CUS', 'category': 'Doors', 'cost': 1200.00, 'retail': 2400.00, 'active': false},
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
                Text(
                  title,
                  style: const TextStyle(fontSize: 13, color: _slateColor, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 24, 
                    fontWeight: FontWeight.w700, 
                    color: _inkColor,
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
                  "Product Catalog",
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: _inkColor, letterSpacing: -0.5),
                ),
                ElevatedButton.icon(
                  onPressed: () {
                    // TODO: Open Create Product Modal
                  },
                  icon: const Icon(Icons.add_rounded, size: 18, color: Colors.white),
                  label: const Text("New Product", style: TextStyle(fontWeight: FontWeight.w600)),
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
                _buildMetricCard("Total Products", "4", Icons.category_outlined),
                const SizedBox(width: 16),
                _buildMetricCard("Active Categories", "3", Icons.layers_outlined),
                const SizedBox(width: 16),
                _buildMetricCard("Recently Added", "1", Icons.new_releases_outlined),
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
                  // Table Toolbar
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
                              hintText: 'Search products...',
                              hintStyle: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 13),
                              prefixIcon: const Icon(Icons.search, size: 18, color: _slateColor),
                              filled: true,
                              fillColor: _fieldFill,
                              contentPadding: EdgeInsets.zero,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                        ),
                        const Spacer(),
                        OutlinedButton.icon(
                          onPressed: () {},
                          icon: const Icon(Icons.filter_list_rounded, size: 16, color: _inkColor),
                          label: const Text("Filter", style: TextStyle(color: _inkColor)),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: _strokeBorder),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: _strokeBorder),
                  
                  // Data Table
                  DataTable(
                    headingTextStyle: const TextStyle(fontWeight: FontWeight.w600, color: _slateColor, fontSize: 12),
                    dataTextStyle: const TextStyle(color: _inkColor, fontSize: 14),
                    dividerThickness: 1,
                    horizontalMargin: 24,
                    columns: const [
                      DataColumn(label: Text('PRODUCT NAME')),
                      DataColumn(label: Text('SKU')),
                      DataColumn(label: Text('CATEGORY')),
                      DataColumn(label: Text('UNIT COST', textAlign: TextAlign.right)),
                      DataColumn(label: Text('RETAIL PRICE', textAlign: TextAlign.right)),
                      DataColumn(label: Text('STATUS')),
                    ],
                    rows: _mockProducts.map((item) {
                      final isActive = item['active'] as bool;

                      return DataRow(
                        cells: [
                          DataCell(Text(item['name'], style: const TextStyle(fontWeight: FontWeight.w500))),
                          DataCell(Text(item['sku'], style: const TextStyle(color: _slateColor))),
                          DataCell(Text(item['category'])),
                          DataCell(Text('\$${item['cost'].toStringAsFixed(2)}')),
                          DataCell(Text('\$${item['retail'].toStringAsFixed(2)}')),
                          DataCell(
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: isActive ? Colors.green.withValues(alpha: 0.1) : _slateColor.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                isActive ? 'Active' : 'Archived',
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