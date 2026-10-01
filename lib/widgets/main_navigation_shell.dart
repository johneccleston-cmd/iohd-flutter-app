import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';


// --- Design tokens ---------------------------------------------------------
// A small, named palette instead of scattered hex literals. Keeping this at
// file scope (rather than duplicated static consts on two classes) means the
// nav items and the dropdown menu share one source of truth for color.
const Color _brandRed = Color(0xFFCC0007);
const Color _inkColor = Color(0xFF181B1F);
const Color _slateColor = Color(0xFF5B6572);
const Color _mutedIconColor = Color(0xFF9199A6);
const Color _strokeBorder = Color(0xFFE4E7EC);
const Color _activeTint = Color(0xFFFCEEEE);
const Color _fieldFill = Color(0xFFF6F7F9);

class MainNavigationShell extends StatefulWidget {
  final StatefulNavigationShell navigationShell;

  const MainNavigationShell({super.key, required this.navigationShell});

  @override
  State<MainNavigationShell> createState() => _MainNavigationShellState();
}

class _MainNavigationShellState extends State<MainNavigationShell> {
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _goBranch(int index) {
    widget.navigationShell.goBranch(
      index,
      initialLocation: index == widget.navigationShell.currentIndex,
    );
  }

  void _handleSearch(String rawQuery) {
    final query = rawQuery.trim();
    if (query.isEmpty) return;

    final looksLikeJobId = int.tryParse(query) != null;
    final path = looksLikeJobId ? '/jobs' : '/customers';

    context.go('$path?q=${Uri.encodeQueryComponent(query)}');
  }

  // A top-level destination that navigates directly on tap.
  Widget _navItem({
    required IconData icon,
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        height: 42,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isSelected ? _activeTint : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border(
            bottom: BorderSide(
              color: isSelected ? _brandRed : Colors.transparent,
              width: 2.5,
            ),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 17, color: isSelected ? _brandRed : _mutedIconColor),
            const SizedBox(width: 7),
            Text(
              label,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
                color: isSelected ? _inkColor : _slateColor,
                letterSpacing: -0.1,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // A top-level destination that opens a dropdown of sub-routes on tap/hover.
  Widget _navDropdown({
    required IconData icon,
    required String label,
    required bool isSelected,
    required List<Widget> Function(MenuController controller) items,
  }) {
    return _HoverMenu(
      items: items,
      trigger: (controller, isOpen) {
        final bool highlighted = isSelected || isOpen;
        return InkWell(
          onTap: () => controller.isOpen ? controller.close() : controller.open(),
          borderRadius: BorderRadius.circular(8),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            height: 42,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: highlighted ? _activeTint : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: Border(
                bottom: BorderSide(
                  color: isSelected ? _brandRed : Colors.transparent,
                  width: 2.5,
                ),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 17, color: highlighted ? _brandRed : _mutedIconColor),
                const SizedBox(width: 7),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
                    color: highlighted ? _inkColor : _slateColor,
                    letterSpacing: -0.1,
                  ),
                ),
                const SizedBox(width: 2),
                AnimatedRotation(
                  turns: isOpen ? 0.5 : 0,
                  duration: const Duration(milliseconds: 140),
                  child: Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 16,
                    color: highlighted ? _brandRed : _mutedIconColor,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _dropdownMenuItem({
    required IconData icon,
    required String label,
    required String route,
    required MenuController controller,
  }) {
    return MenuItemButton(
      style: MenuItemButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      leadingIcon: Icon(icon, size: 18, color: _mutedIconColor),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: _inkColor,
        ),
      ),
      onPressed: () {
        controller.close();
        context.go(route);
      },
    );
  }
  Widget _menuSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 14, right: 14, top: 12, bottom: 4),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w800,
          color: _slateColor,
          letterSpacing: 0.8,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final int current = widget.navigationShell.currentIndex;

    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(72),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            border: const Border(bottom: BorderSide(color: _strokeBorder, width: 1)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  // --- Brand lockup ---
                  Container(
                    width: 36,
                    height: 36,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: _brandRed,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.garage_rounded, size: 19, color: Colors.white),
                  ),
                  const SizedBox(width: 10),
                  const Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "IOHD",
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: _inkColor,
                          letterSpacing: -0.2,
                          height: 1.15,
                        ),
                      ),
                      Text(
                        "Operations Hub",
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w500,
                          color: _slateColor,
                          height: 1.15,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 24),
                  Container(width: 1, height: 28, color: _strokeBorder),
                  const SizedBox(width: 12),

                // --- Primary nav ---
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          // 🔥 UPDATED: My Office Mega-Dropdown
                          _navDropdown(
                            icon: Icons.home_work_rounded,
                            label: "My Office",
                            isSelected: [1, 3, 4].contains(current),
                            items: (controller) => [
                              _menuSectionHeader("Operations"),
                              _dropdownMenuItem(icon: Icons.groups_rounded, label: 'Customers', route: '/customers', controller: controller),
                              _dropdownMenuItem(icon: Icons.request_quote_rounded, label: 'Estimates', route: '/estimates', controller: controller),
                              _dropdownMenuItem(icon: Icons.build_rounded, label: 'Jobs', route: '/jobs', controller: controller),
                              _dropdownMenuItem(icon: Icons.timeline_rounded, label: 'Estimate & Job Statuses', route: '/statuses', controller: controller),
                              
                              const Padding(padding: EdgeInsets.symmetric(vertical: 4), child: Divider(height: 1, color: _strokeBorder)),
                              
                              _menuSectionHeader("Financial"),
                              _dropdownMenuItem(icon: Icons.payment_rounded, label: 'Payments', route: '/payments', controller: controller),
                              _dropdownMenuItem(icon: Icons.receipt_long_rounded, label: 'Invoices', route: '/invoices', controller: controller),
                              
                              const Padding(padding: EdgeInsets.symmetric(vertical: 4), child: Divider(height: 1, color: _strokeBorder)),
                              
                              _menuSectionHeader("Commercial"),
                              _dropdownMenuItem(icon: Icons.assignment_turned_in_rounded, label: 'Site Checks', route: '/site-checks', controller: controller),
                              _dropdownMenuItem(icon: Icons.architecture_rounded, label: 'Takeoffs', route: '/takeoffs', controller: controller),
                            ],
                          ),
                          const SizedBox(width: 4),
                          
                          // Projects remains standalone
                          _navItem(
                            icon: Icons.folder_copy_rounded,
                            label: "Projects",
                            isSelected: current == 2,
                            onTap: () => _goBranch(2),
                          ),
                          const SizedBox(width: 4),
                          
                          _navItem(
                            icon: Icons.calendar_month_rounded,
                            label: "Calendar",
                            isSelected: current == 5,
                            onTap: () => _goBranch(5),
                          ),
                          const SizedBox(width: 4),
                          
                          _navDropdown(
                            icon: Icons.inventory_2_rounded,
                            label: "Inventory",
                            isSelected: current == 6, 
                            items: (controller) => [
                              _dropdownMenuItem(
                                icon: Icons.stacked_bar_chart_rounded,
                                label: 'Stock Levels',
                                route: '/inventory', // Routes to your new InventoryScreen
                                controller: controller,
                              ),
                              _dropdownMenuItem(
                                icon: Icons.category_rounded,
                                label: 'Product Catalog', // 🔥 Renamed
                                route: '/inventory/catalog', // Updated route
                                controller: controller,
                              ),
                              
                              const Padding(padding: EdgeInsets.symmetric(vertical: 4), child: Divider(height: 1, color: _strokeBorder)),
                              
                              _menuSectionHeader("Purchasing"),
                              _dropdownMenuItem(
                                icon: Icons.shopping_cart_checkout_rounded,
                                label: 'Purchase Orders',
                                route: '/inventory/purchase-orders',
                                controller: controller,
                              ),
                              _dropdownMenuItem(
                                icon: Icons.storefront_rounded,
                                label: 'Vendors',
                                route: '/inventory/vendors',
                                controller: controller,
                              ),
                            ],
                          ),
                          const SizedBox(width: 4),
                          
                          _navDropdown(
                            icon: Icons.badge_rounded,
                            label: "HR",
                            isSelected: current == 7,
                            items: (controller) => [
                              _dropdownMenuItem(
                                icon: Icons.payments_rounded,
                                label: 'Payroll',
                                route: '/hr',
                                controller: controller,
                              ),
                              _dropdownMenuItem(
                                icon: Icons.speed_outlined,
                                label: "KPI's",
                                route: '/hr/kpis',
                                controller: controller,
                              ),
                              _dropdownMenuItem(
                                icon: Icons.calculate_outlined,
                                label: 'Commission Simulator',
                                route: '/hr/simulator',
                                controller: controller,
                              ),
                            ],
                          ),
                          const SizedBox(width: 4),
                          
                          _navDropdown(
                            icon: Icons.insights_rounded,
                            label: "Dashboards",
                            isSelected: current == 8, // Shifted from 7 to 8
                            items: (controller) => [
                              _dropdownMenuItem(
                                icon: Icons.attach_money_rounded,
                                label: 'Financial',
                                route: '/dashboards/financial',
                                controller: controller,
                              ),
                              _dropdownMenuItem(
                                icon: Icons.payments_outlined,
                                label: 'Commissions',
                                route: '/dashboards/commissions',
                                controller: controller,
                              ),
                              _dropdownMenuItem(
                                icon: Icons.engineering_outlined,
                                label: 'Technicians',
                                route: '/dashboards/technicians',
                                controller: controller,
                              ),
                              _dropdownMenuItem(
                                icon: Icons.inventory_2_outlined,
                                label: 'Inventory',
                                route: '/dashboards/inventory',
                                controller: controller,
                              ),
                              _dropdownMenuItem(
                                icon: Icons.work_outline_rounded,
                                label: 'Jobs',
                                route: '/dashboards/jobs',
                                controller: controller,
                              ),
                              _dropdownMenuItem(
                                icon: Icons.request_quote_outlined,
                                label: 'Estimates',
                                route: '/dashboards/estimates',
                                controller: controller,
                              ),
                              _dropdownMenuItem(
                                icon: Icons.trending_up_rounded,
                                label: 'Sales',
                                route: '/dashboards/sales',
                                controller: controller,
                              ),
                              _dropdownMenuItem(
                                icon: Icons.account_balance_wallet_outlined,
                                label: 'Collections',
                                route: '/dashboards/collections',
                                controller: controller,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(width: 16),
                  Container(width: 1, height: 28, color: _strokeBorder),
                  const SizedBox(width: 16),

                  // --- Search ---
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 240, minWidth: 170),
                    child: SizedBox(
                      height: 38,
                      child: TextField(
                        controller: _searchController,
                        onSubmitted: _handleSearch,
                        textInputAction: TextInputAction.search,
                        style: const TextStyle(fontSize: 13, color: _inkColor),
                        decoration: InputDecoration(
                          hintText: 'Search jobs or customers',
                          hintStyle: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
                          prefixIcon: const Icon(Icons.search_rounded, size: 18, color: _slateColor),
                          filled: true,
                          fillColor: _fieldFill,
                          contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(9),
                            borderSide: BorderSide.none,
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(9),
                            borderSide: BorderSide.none,
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(9),
                            borderSide: const BorderSide(color: _brandRed, width: 1.5),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      body: widget.navigationShell,
    );
  }
}

/// Reusable hover/tap dropdown menu. Replaces two near-identical MenuAnchor
/// blocks (previously HR and Dashboards each had their own MenuController
/// field and hover-timer methods on the parent State) with one widget that
/// owns its own controller and hover state, so adding a third dropdown later
/// is a one-call addition instead of another ~90-line copy-paste block.
class _HoverMenu extends StatefulWidget {
  final Widget Function(MenuController controller, bool isOpen) trigger;
  final List<Widget> Function(MenuController controller) items;

  const _HoverMenu({required this.trigger, required this.items});

  @override
  State<_HoverMenu> createState() => _HoverMenuState();
}

class _HoverMenuState extends State<_HoverMenu> {
  final MenuController _controller = MenuController();
  bool _isHovering = false;
  bool _isOpen = false;
  

  void _onEnter() {
    _isHovering = true;
    if (!_controller.isOpen) _controller.open();
  }

  void _onExit() {
    _isHovering = false;
    Future.delayed(const Duration(milliseconds: 180), () {
      if (!_isHovering && _controller.isOpen && mounted) _controller.close();
    });
  }

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      controller: _controller,
      onOpen: () => setState(() => _isOpen = true),
      onClose: () => setState(() => _isOpen = false),
      style: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll(Colors.white),
        elevation: const WidgetStatePropertyAll(8),
        shadowColor: WidgetStatePropertyAll(Colors.black.withValues(alpha: 0.12)),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.white),
        minimumSize: const WidgetStatePropertyAll(Size(220, 0)),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(6)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: _strokeBorder, width: 1),
          ),
        ),
      ),
      menuChildren: [
        MouseRegion(
          onEnter: (_) => _onEnter(),
          onExit: (_) => _onExit(),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: widget.items(_controller),
          ),
        ),
      ],
      child: MouseRegion(
        onEnter: (_) => _onEnter(),
        onExit: (_) => _onExit(),
        child: widget.trigger(_controller, _isOpen),
      ),
    );
  }
}