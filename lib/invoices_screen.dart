import 'package:flutter/material.dart';

import 'config/access.dart';
import 'config/auth_session.dart';
import 'widgets/dashboard_kit.dart';
import 'widgets/flat_page.dart';

class InvoicesScreen extends StatefulWidget {
  const InvoicesScreen({super.key});

  @override
  State<InvoicesScreen> createState() => _InvoicesScreenState();
}

class _InvoicesScreenState extends State<InvoicesScreen> {
  final TextEditingController _searchController = TextEditingController();

  final List<Map<String, dynamic>> _mockInvoices = [
    {'id': 'INV-4011', 'customer': 'Walton Logistics', 'date': 'Sep 15, 2026', 'due': 'Oct 15, 2026', 'amount': 8500.00, 'status': 'Sent'},
    {'id': 'INV-4010', 'customer': 'Bob Vance', 'date': 'Sep 1, 2026', 'due': 'Oct 1, 2026', 'amount': 1200.00, 'status': 'Overdue'},
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
            title: 'Invoices',
            actions: [if (AuthSession.instance.can('invoices', AccessAction.create)) PageBanner.button(icon: Icons.add_rounded, label: 'Create Invoice', onPressed: () {})],
          ),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const FlatStats(
                    stats: [
                      FlatStat('Awaiting Payment', '\$8,500.00'),
                      FlatStat('Overdue', '\$1,200.00', tone: DashUi.red),
                      FlatStat('Paid (30d)', '\$34,500.00'),
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
                          decoration: flatSearchDecoration('Search invoices...'),
                        ),
                      ),
                    ),
                  ),
                  FlatTable(
                    columns: const [
                      FlatCol('Invoice', flex: 2),
                      FlatCol('Customer', flex: 4),
                      FlatCol('Issued', flex: 3),
                      FlatCol('Due', flex: 3),
                      FlatCol('Amount', flex: 3, right: true),
                      FlatCol('Status', flex: 3),
                    ],
                    rows: [
                      for (final i in _mockInvoices)
                        [
                          Text(i['id'], style: flatCellBold),
                          Text(i['customer'], style: flatCellStyle),
                          Text(i['date'], style: flatCellStyle),
                          Text(i['due'], style: flatCellMuted),
                          Text(dashMoney((i['amount'] as num).toDouble()), style: flatCellStyle.copyWith(fontFeatures: flatFigures)),
                          FlatStatus(i['status'], i['status'] == 'Overdue' ? DashUi.red : DashUi.amber),
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
