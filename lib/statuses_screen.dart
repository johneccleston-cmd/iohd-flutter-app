import 'package:flutter/material.dart';

import 'widgets/dashboard_kit.dart';
import 'widgets/flat_page.dart';

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
            title: 'Estimate & Job Statuses',
            actions: [],
          ),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const FlatStats(
                    stats: [
                      FlatStat('Active Jobs', '12'),
                      FlatStat('Pending Estimates', '5', tone: DashUi.amber),
                      FlatStat('Parts Ordered', '3'),
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
                          decoration: flatSearchDecoration('Search ID or customer...'),
                        ),
                      ),
                    ),
                  ),
                  FlatTable(
                    columns: const [
                      FlatCol('ID', flex: 2),
                      FlatCol('Type', flex: 2),
                      FlatCol('Customer', flex: 4),
                      FlatCol('Tech', flex: 3),
                      FlatCol('Status', flex: 3),
                    ],
                    rows: [
                      for (final d in _mockData)
                        [
                          Text(d['id'], style: flatCellBold),
                          Text(d['type'], style: flatCellStyle),
                          Text(d['customer'], style: flatCellStyle),
                          Text(d['tech'], style: flatCellMuted),
                          FlatStatus(d['status'], d['status'] == 'In Progress' ? DashUi.emeraldDeep : DashUi.slate),
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
