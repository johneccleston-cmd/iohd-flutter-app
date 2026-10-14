import 'package:flutter/material.dart';

import 'widgets/record_list_view.dart';

/// The Jobs list. The list itself lives in [RecordListView], shared with the Estimates list so the two behave the same.
class JobsScreen extends StatelessWidget {
  /// A search handed in by the route (the nav bar search sends `/jobs?q=`).
  final String? initialQuery;
  const JobsScreen({super.key, this.initialQuery});

  @override
  Widget build(BuildContext context) => RecordListView(config: RecordListConfig.jobs, initialQuery: initialQuery);
}
