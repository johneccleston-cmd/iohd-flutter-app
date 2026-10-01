import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Card container matching MaterialCardView style
class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;

  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18.0),
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: padding,
        child: child,
      ),
    );
  }
}

/// All-caps uppercase section header (e.g., CUSTOMER, LOCATION)
class AppSectionLabel extends StatelessWidget {
  final String text;

  const AppSectionLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: Theme.of(context).textTheme.labelSmall,
    );
  }
}

/// Specialized Amber Warning Card for Notes
class AppNotesCard extends StatelessWidget {
  final String title;
  final String body;

  const AppNotesCard({
    super.key,
    this.title = "NOTES FOR TECHS",
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    if (body.trim().isEmpty) return const SizedBox.shrink();

    return Card(
      color: AppTheme.notesBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppTheme.notesStroke, width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title.toUpperCase(),
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: AppTheme.notesHeader,
                letterSpacing: 0.8,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              body,
              style: const TextStyle(
                fontSize: 14,
                color: AppTheme.notesText,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Standardized Divider line
class AppDivider extends StatelessWidget {
  const AppDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 14.0),
      child: Divider(height: 1),
    );
  }
}