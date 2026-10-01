import 'package:flutter/material.dart';
import 'dashboard_layout.dart';

class GenericDashboardScreen extends StatelessWidget {
  final String title;

  const GenericDashboardScreen({
    super.key,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    return DashboardLayout(
      title: title,
      builder: (context, selectedYear) {
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFFE5E7EB)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.04),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Icon(
                  Icons.dashboard_customize_rounded,
                  size: 48,
                  color: Colors.grey[400],
                ),
              ),
              const SizedBox(height: 20),
              Text(
                '$title Dashboard',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1A1C1E),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '$title metrics layout ready for implementation ($selectedYear)',
                style: const TextStyle(
                  color: Color(0xFF9CA3AF),
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}