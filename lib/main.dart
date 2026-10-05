import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'product_catalog_screen.dart';
import 'purchase_orders_screen.dart';
import 'vendors_screen.dart';
import 'jobs_screen.dart'; 
import 'payroll_screen.dart'; 
import 'estimates_screen.dart'; 
import 'calendar_screen.dart';
import 'customers_screen.dart';
import 'reports_screen.dart';
import 'commission_dashboard_screen.dart';
import 'technicians_dashboard_screen.dart';
import 'inventory_dashboard_screen.dart';
import 'widgets/generic_dashboard_screen.dart';
import 'widgets/main_navigation_shell.dart';
import 'jobs_dashboard_screen.dart';
import 'estimates_dashboard_screen.dart';
import 'sales_dashboard_screen.dart';
import 'kpi_dashboard_screen.dart';
import 'commission_tester_page.dart'; // 🔥 Added import
import 'inventory_screen.dart';
import 'statuses_screen.dart';
import 'payments_screen.dart';
import 'invoices_screen.dart';
import 'team_admin_screen.dart';
import 'login_screen.dart';
import 'commission_corrections_screen.dart';
import 'config/auth_session.dart';
import 'widgets/smooth_wheel_scroll.dart';




// --- ROUTER CONFIGURATION ---
final GoRouter _router = GoRouter(
  initialLocation: '/calendar',
  // Everything except /login needs a signed-in office user. The router re-checks whenever the
  // session changes (sign-in, sign-out, or the token expiring).
  refreshListenable: AuthSession.instance,
  redirect: (context, state) {
    final signedIn = AuthSession.instance.isLoggedIn;
    final atLogin = state.matchedLocation == '/login';
    if (!signedIn && !atLogin) return '/login';
    if (signedIn && atLogin) return '/calendar';
    return null;
  },
  routes: [
    GoRoute(path: '/login', builder: (context, state) => const LoginScreen()),
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) {
        return MainNavigationShell(navigationShell: navigationShell);
      },
      branches: [
       // OFFICE BRANCH (Index 0)
        StatefulShellBranch(routes: [
          GoRoute(path: '/office', builder: (context, state) => const _PlaceholderScreen(title: "My Office")),
          // Add the new routes here so they live inside the same indexed shell
          GoRoute(path: '/statuses', builder: (context, state) => const StatusesScreen()),
          GoRoute(path: '/payments', builder: (context, state) => const PaymentsScreen()),
          GoRoute(path: '/invoices', builder: (context, state) => const InvoicesScreen()),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(path: '/customers', builder: (context, state) => const CustomersScreen()),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(path: '/projects', builder: (context, state) => const _PlaceholderScreen(title: "Projects")),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(path: '/estimates', builder: (context, state) => const EstimatesScreen()),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(path: '/jobs', builder: (context, state) => const JobsScreen()),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(path: '/calendar', builder: (context, state) => const CalendarScreen()),
        ]),
       // INVENTORY BRANCH (Index 6)
        StatefulShellBranch(routes: [
          GoRoute(
            path: '/inventory', 
            builder: (context, state) => const InventoryScreen(), // "Stock Levels"
            routes: [
              GoRoute(
                path: 'catalog', 
                builder: (context, state) => const ProductCatalogScreen(), 
              ),
              // 🔥 UPDATED: Live Purchase Orders Screen
              GoRoute(
                path: 'purchase-orders', 
                builder: (context, state) => const PurchaseOrdersScreen(),
              ),
              // 🔥 UPDATED: Live Vendors Screen
              GoRoute(
                path: 'vendors', 
                builder: (context, state) => const VendorsScreen(),
              ),
            ],
          ),
        ]),
        
        // HR BRANCH
        StatefulShellBranch(routes: [
          GoRoute(
            path: '/hr', 
            builder: (context, state) => const PayrollScreen(),
            routes: [
              GoRoute(path: 'kpis', builder: (context, state) => const KPIDashboardScreen()),
              // 🔥 FIX: Relative path matches 'kpis' pattern
              GoRoute(path: 'simulator', builder: (context, state) => const CommissionTesterPage()),
              GoRoute(path: 'team', builder: (context, state) => const TeamAdminScreen()),
              GoRoute(path: 'corrections', builder: (context, state) => const CommissionCorrectionsScreen()),
            ],
          ),
        ]),

        // DASHBOARDS BRANCH
        StatefulShellBranch(routes: [
          GoRoute(
            path: '/dashboards',
            builder: (context, state) => const ReportsScreen(),
            routes: [
              GoRoute(path: 'financial', builder: (context, state) => const ReportsScreen()),
              GoRoute(path: 'commissions', builder: (context, state) => const CommissionDashboardScreen()),
              GoRoute(path: 'technicians', builder: (context, state) => const TechniciansDashboardScreen()),
              GoRoute(path: 'inventory', builder: (context, state) => const InventoryDashboardScreen()),
              GoRoute(path: 'jobs', builder: (context, state) => const JobsDashboardScreen()),
              GoRoute(path: 'estimates', builder: (context, state) => const EstimatesDashboardScreen()),
              GoRoute(path: 'sales', builder: (context, state) => const SalesDashboardScreen()),
              GoRoute(path: 'collections', builder: (context, state) => const GenericDashboardScreen(title: "Collections")),
            ],
          ),
        ]),
      ],
    ),
  ],
);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SmoothWheelScroll.install();
  runApp(const IohdHubApp());
}

class IohdHubApp extends StatelessWidget {
  const IohdHubApp({super.key});

  static const Color bgColor = Color(0xFFF8F9FB);
  static const Color brandRed = Color(0xFFCC0007);
  static const Color primaryText = Color(0xFF1A1C1E);
  static const Color strokeBorder = Color(0xFFE5E7EB);

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'IOHD',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.light,
      routerConfig: _router,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: bgColor,
        typography: Typography.material2021(platform: defaultTargetPlatform),
        textTheme: const TextTheme().apply(displayColor: primaryText, bodyColor: primaryText),
        colorScheme: ColorScheme.fromSeed(
          seedColor: brandRed,
          primary: brandRed,
          surface: bgColor,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
        ),
        cardTheme: CardThemeData(
          color: Colors.white,
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: strokeBorder, width: 1),
          ),
        ),

        // ---- Pop-ups: one look everywhere (dialogs, menus, dropdowns, tooltips, snackbars) ----
        dialogTheme: DialogThemeData(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          elevation: 12,
          shadowColor: Colors.black.withValues(alpha: 0.18),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: Color(0xFFE2E8F0)),
          ),
          titleTextStyle: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: Color(0xFF0F172A),
            letterSpacing: -0.3,
          ),
          contentTextStyle: const TextStyle(fontSize: 14, color: Color(0xFF475569), height: 1.45),
          actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 18),
        ),
        popupMenuTheme: PopupMenuThemeData(
          color: Colors.white,
          surfaceTintColor: Colors.transparent,
          elevation: 8,
          shadowColor: Colors.black.withValues(alpha: 0.14),
          menuPadding: const EdgeInsets.all(6),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: Color(0xFFE2E8F0)),
          ),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF0F172A)),
        ),
        menuTheme: MenuThemeData(
          style: MenuStyle(
            backgroundColor: const WidgetStatePropertyAll(Colors.white),
            surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
            elevation: const WidgetStatePropertyAll(8),
            shadowColor: WidgetStatePropertyAll(Colors.black.withValues(alpha: 0.14)),
            padding: const WidgetStatePropertyAll(EdgeInsets.all(6)),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: const BorderSide(color: Color(0xFFE2E8F0)),
              ),
            ),
          ),
        ),
        dropdownMenuTheme: DropdownMenuThemeData(
          menuStyle: MenuStyle(
            backgroundColor: const WidgetStatePropertyAll(Colors.white),
            surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
            elevation: const WidgetStatePropertyAll(8),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: const BorderSide(color: Color(0xFFE2E8F0)),
              ),
            ),
          ),
        ),
        tooltipTheme: TooltipThemeData(
          waitDuration: const Duration(milliseconds: 450),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(color: const Color(0xFF0F172A), borderRadius: BorderRadius.circular(8)),
          textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white),
        ),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xFF0F172A),
          contentTextStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: Colors.white),
          actionTextColor: const Color(0xFF93C5FD),
          elevation: 6,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          insetPadding: const EdgeInsets.all(20),
        ),
      ),
    );
  }
}

class _PlaceholderScreen extends StatelessWidget {
  final String title;
  const _PlaceholderScreen({super.key, required this.title});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.construction_rounded, size: 70, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text(
            "$title Screen",
            style: const TextStyle(fontSize: 22, color: Color(0xFF1A1C1E), fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          const Text("Under Construction", style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 14)),
        ],
      ),
    );
  }
}