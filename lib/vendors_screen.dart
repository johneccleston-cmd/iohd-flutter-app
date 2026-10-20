import 'package:flutter/material.dart';

import 'widgets/dashboard_kit.dart';
import 'widgets/flat_page.dart';

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageBanner(
            title: 'Vendors',
            actions: [PageBanner.button(icon: Icons.add_rounded, label: 'New Vendor', onPressed: () {})],
          ),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const FlatStats(
                    stats: [
                      FlatStat('Total Vendors', '4'),
                      FlatStat('Active Suppliers', '3'),
                      FlatStat('Net 30 Terms', '1'),
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
                          decoration: flatSearchDecoration('Search vendors...'),
                        ),
                      ),
                    ),
                  ),
                  FlatTable(
                    columns: const [
                      FlatCol('Vendor Name', flex: 4),
                      FlatCol('Email / Contact', flex: 4),
                      FlatCol('Phone', flex: 3),
                      FlatCol('Terms', flex: 3),
                      FlatCol('Status', flex: 3),
                    ],
                    rows: [
                      for (final v in _mockVendors)
                        [
                          Text(v['name'], style: flatCellBold),
                          Text(v['contact'], style: flatCellStyle),
                          Text(v['phone'], style: flatCellMuted),
                          Text(v['terms'], style: flatCellStyle),
                          (v['active'] as bool)
                              ? const FlatStatus('Active', DashUi.emeraldDeep)
                              : const FlatStatus('Inactive', DashUi.slate),
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
