import 'package:flutter/material.dart';

import 'widgets/flat_page.dart';

class SiteChecksScreen extends StatelessWidget {
  const SiteChecksScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageBanner(
            title: 'Site Checks',
            actions: [PageBanner.button(icon: Icons.add_rounded, label: 'New Site Check', onPressed: () {})],
          ),
          const Expanded(
            child: Center(
              child: FlatEmpty(
                icon: Icons.assignment_turned_in_outlined,
                title: 'No site checks yet',
                message: 'Create a new site check to document commercial site conditions.',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
