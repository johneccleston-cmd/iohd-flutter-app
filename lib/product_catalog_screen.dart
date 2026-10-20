import 'package:flutter/material.dart';

import 'widgets/dashboard_kit.dart';
import 'widgets/flat_page.dart';

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

  Widget _money(num v) => Text(
    dashMoney(v.toDouble()),
    style: flatCellStyle.copyWith(fontFeatures: flatFigures),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageBanner(
            title: 'Product Catalog',
            actions: [
              PageBanner.button(
                icon: Icons.add_rounded,
                label: 'New Product',
                onPressed: () {
                  // TODO: Open Create Product Modal
                },
              ),
            ],
          ),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const FlatStats(
                    stats: [
                      FlatStat('Total Products', '4'),
                      FlatStat('Active Categories', '3'),
                      FlatStat('Recently Added', '1'),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        SizedBox(
                          width: 340,
                          child: TextField(
                            controller: _searchController,
                            style: const TextStyle(fontSize: 14),
                            decoration: flatSearchDecoration('Search products...'),
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: () {},
                          icon: const Icon(Icons.filter_list_rounded, size: 18),
                          label: const Text('Filter'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, 40),
                            foregroundColor: DashUi.ink,
                            side: const BorderSide(color: DashUi.line),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ),
                  ),
                  FlatTable(
                    columns: const [
                      FlatCol('Product Name', flex: 5),
                      FlatCol('SKU', flex: 3),
                      FlatCol('Category', flex: 3),
                      FlatCol('Unit Cost', flex: 3, right: true),
                      FlatCol('Retail Price', flex: 3, right: true),
                      FlatCol('Status', flex: 3),
                    ],
                    rows: [
                      for (final p in _mockProducts)
                        [
                          Text(p['name'], style: flatCellBold),
                          Text(p['sku'], style: flatCellMuted),
                          Text(p['category'], style: flatCellStyle),
                          _money(p['cost']),
                          _money(p['retail']),
                          (p['active'] as bool)
                              ? const FlatStatus('Active', DashUi.emeraldDeep)
                              : const FlatStatus('Archived', DashUi.slate),
                        ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
