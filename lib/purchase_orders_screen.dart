import 'package:flutter/material.dart';

import 'config/access.dart';
import 'config/auth_session.dart';
import 'widgets/dashboard_kit.dart';
import 'widgets/flat_page.dart';

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

  Color _statusColor(String status) => switch (status) {
    'Pending' => DashUi.amber,
    'Fulfilled' => DashUi.emeraldDeep,
    _ => DashUi.red,
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageBanner(
            title: 'Purchase Orders',
            actions: [
              if (AuthSession.instance.can('purchase_orders', AccessAction.create))
                PageBanner.button(icon: Icons.add_rounded, label: 'Create PO', onPressed: () {}),
            ],
          ),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const FlatStats(
                    stats: [
                      FlatStat('Open Orders', '1', tone: DashUi.amber),
                      FlatStat('Total Spend (30d)', '\$6,865.50'),
                      FlatStat('Vendors Used', '4'),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: SizedBox(
                        width: 340,
                        child: TextField(
                          controller: _searchController,
                          style: const TextStyle(fontSize: 14),
                          decoration: flatSearchDecoration('Search PO number or vendor...'),
                        ),
                      ),
                    ),
                  ),
                  FlatTable(
                    columns: const [
                      FlatCol('PO Number', flex: 3),
                      FlatCol('Vendor', flex: 4),
                      FlatCol('Date Created', flex: 3),
                      FlatCol('Total', flex: 3, right: true),
                      FlatCol('Status', flex: 3),
                    ],
                    rows: [
                      for (final po in _mockPOs)
                        [
                          Text(po['poNumber'], style: flatCellBold),
                          Text(po['vendor'], style: flatCellStyle),
                          Text(po['date'], style: flatCellMuted),
                          Text(dashMoney((po['total'] as num).toDouble()), style: flatCellStyle.copyWith(fontFeatures: flatFigures)),
                          FlatStatus(po['status'], _statusColor(po['status'])),
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
