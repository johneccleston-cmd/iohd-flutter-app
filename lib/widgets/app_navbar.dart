import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class AppNavBar extends StatelessWidget {
  final String currentPath;

  const AppNavBar({
    super.key,
    required this.currentPath,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 240,
      color: const Color(0xFF0F172A),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Logo
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 20.0),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Color(0xFF1E293B), width: 1),
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF3B82F6),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.build_rounded, color: Colors.white, size: 20),
                ),
                const SizedBox(width: 12),
                const Text(
                  'IOHD DESKTOP',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: 1.2,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // Navigation Links
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 12.0),
              children: [
                _buildNavItem(context, title: 'Financial', icon: Icons.dashboard_rounded, route: '/dashboards/financial'),
                _buildNavItem(context, title: 'Technicians', icon: Icons.engineering_rounded, route: '/dashboards/technicians'),
                _buildNavItem(context, title: 'Commissions', icon: Icons.payments_rounded, route: '/dashboards/commissions'),
                _buildNavItem(context, title: 'Inventory', icon: Icons.inventory_2_rounded, route: '/dashboards/inventory'),
                _buildNavItem(context, title: 'Jobs', icon: Icons.work_rounded, route: '/dashboards/jobs'),
                _buildNavItem(context, title: 'Estimates', icon: Icons.request_quote_rounded, route: '/dashboards/estimates'),
                _buildNavItem(context, title: 'KPI\'s', icon: Icons.speed_rounded, route: '/dashboards/kpis'),
                _buildNavItem(context, title: 'Sales', icon: Icons.trending_up_rounded, route: '/dashboards/sales'),
                _buildNavItem(context, title: 'Collections', icon: Icons.account_balance_wallet_rounded, route: '/dashboards/collections'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavItem(
    BuildContext context, {
    required String title,
    required IconData icon,
    required String route,
  }) {
    final bool isActive = currentPath == route;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.0),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            if (!isActive) {
              context.go(route);
            }
          },
          borderRadius: BorderRadius.circular(8),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 10.0),
            decoration: BoxDecoration(
              color: isActive ? const Color(0xFF1E293B) : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: isActive
                  ? Border.all(color: const Color(0xFF38BDF8).withValues(alpha: 0.3), width: 1)
                  : Border.all(color: Colors.transparent),
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: isActive ? const Color(0xFF38BDF8) : const Color(0xFF94A3B8),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                      color: isActive ? Colors.white : const Color(0xFF94A3B8),
                    ),
                  ),
                ),
                if (isActive)
                  Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: Color(0xFF38BDF8),
                      shape: BoxShape.circle,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}