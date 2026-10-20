import 'package:flutter/material.dart';

import 'widgets/flat_page.dart';

class TakeoffsScreen extends StatelessWidget {
  const TakeoffsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageBanner(
            title: 'Takeoffs',
            actions: [PageBanner.button(icon: Icons.add_rounded, label: 'New Takeoff', onPressed: () {})],
          ),
          const Expanded(
            child: Center(
              child: FlatEmpty(
                icon: Icons.architecture_outlined,
                title: 'No takeoffs yet',
                message: 'Start building a new material and labor takeoff for a commercial bid.',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
