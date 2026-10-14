import 'package:flutter/material.dart';

import 'widgets/record_list_view.dart';

/// The Estimates list. The list itself lives in [RecordListView], shared with the Jobs list so the two behave the same.
class EstimatesScreen extends StatelessWidget {
  /// A search handed in by the route (`/estimates?q=`).
  final String? initialQuery;
  const EstimatesScreen({super.key, this.initialQuery});

  @override
  Widget build(BuildContext context) => RecordListView(config: RecordListConfig.estimates, initialQuery: initialQuery);
}
