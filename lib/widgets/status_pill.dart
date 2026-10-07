import 'package:flutter/material.dart';

import '../utils/status_colors.dart';

/// A job/estimate status as a small pill in that status's own colour (see utils/status_colors.dart).
class StatusPill extends StatelessWidget {
  final String text;
  final double fontSize;
  const StatusPill(this.text, {super.key, this.fontSize = 12});

  @override
  Widget build(BuildContext context) {
    final color = statusColor(text);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w700, color: color)),
    );
  }
}
