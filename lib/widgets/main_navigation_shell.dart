import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../config/access.dart';
import '../config/auth_session.dart';
import 'app_dialog.dart';
import 'assistant_panel.dart';

// --- Design tokens ---------------------------------------------------------
// Dropdown panels and rows stay light (white cards, like the dashboards' pop-ups).
const Color _brandRed = Color(0xFFCC0007);
const Color _inkColor = Color(0xFF181B1F);
const Color _slateColor = Color(0xFF5B6572);
const Color _mutedIconColor = Color(0xFF9199A6);
const Color _strokeBorder = Color(0xFFE4E7EC);
const Color _activeTint = Color(0xFFFCEEEE);
const Color _fieldFill = Color(0xFFF6F7F9);

// The bar itself. true = dark slate like the dashboard headers, false = the old white bar.
const bool _darkBar = false;

class _Bar {
  _Bar._();

  static const bg = _darkBar ? Color(0xFF0F172A) : Colors.white;
  static const border = _darkBar ? Color(0xFF1E293B) : Color(0xFFE4E7EC);
  static const divider = _darkBar ? Color(0xFF334155) : Color(0xFFE4E7EC);

  static const text = _darkBar ? Color(0xFFCBD5E1) : Color(0xFF5B6572);
  static const textActive = _darkBar ? Colors.white : Color(0xFF181B1F);
  static const icon = _darkBar ? Color(0xFF94A3B8) : Color(0xFF9199A6);
  static const iconActive = _darkBar ? Colors.white : _brandRed;

  static const activeFill = _darkBar ? Color(0x1AFFFFFF) : Color(0xFFFCEEEE); // white at 10%
  static const hoverFill = _darkBar ? Color(0x0FFFFFFF) : Color(0xFFF3F4F6); // white at 6%

  static const brandSub = _darkBar ? Color(0xFF94A3B8) : Color(0xFF5B6572);

  static const field = _darkBar ? Color(0xFF1E293B) : Color(0xFFF6F7F9);
  static const fieldBorder = _darkBar ? Color(0xFF334155) : Colors.transparent;
  static const fieldText = _darkBar ? Colors.white : Color(0xFF181B1F);
  static const fieldHint = _darkBar ? Color(0xFF64748B) : Color(0xFF9CA3AF);
  static const fieldIcon = _darkBar ? Color(0xFF94A3B8) : Color(0xFF5B6572);
  static const keyHintBg = _darkBar ? Color(0xFF0F172A) : Colors.white;
  static const keyHintBorder = _darkBar ? Color(0xFF334155) : Color(0xFFE4E7EC);
  static const keyHintText = _darkBar ? Color(0xFF64748B) : Color(0xFF9199A6);

  static const avatarBg = _darkBar ? Color(0xFF1E293B) : Color(0xFFFCEEEE);
  static const avatarText = _darkBar ? Colors.white : _brandRed;
}

const double _barHeight = 60;

// Below these widths the bar trims itself instead of overflowing.
const double _compactWidth = 1320;
const double _tightWidth = 1040;
const double _iconOnlyWidth = 900;

class MainNavigationShell extends StatefulWidget {
  final StatefulNavigationShell navigationShell;

  const MainNavigationShell({super.key, required this.navigationShell});

  @override
  State<MainNavigationShell> createState() => _MainNavigationShellState();
}

class _MainNavigationShellState extends State<MainNavigationShell> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  bool _tight = false;

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
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

  // Ctrl+K (Cmd+K on Mac) jumps to search. On a narrow window the field is hidden, so it opens a dialog.
  void _focusSearch() {
    if (_tight) {
      _showSearchDialog();
      return;
    }
    _searchFocus.requestFocus();
    _searchController.selection = TextSelection(baseOffset: 0, extentOffset: _searchController.text.length);
  }

  Future<void> _showSearchDialog() async {
    final controller = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AppDialog(
        title: 'Search',
        subtitle: 'A job number opens Jobs. Anything else searches Customers.',
        icon: Icons.search_rounded,
        width: 440,
        body: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: appFieldDecoration(hint: 'Search jobs or customers'),
          onSubmitted: (v) {
            Navigator.pop(ctx);
            _handleSearch(v);
          },
        ),
        actions: [
          AppButton.ghost('Cancel', () => Navigator.pop(ctx)),
          AppButton.ink('Search', () {
            Navigator.pop(ctx);
            _handleSearch(controller.text);
          }, icon: Icons.search_rounded),
        ],
      ),
    );
    controller.dispose();
  }

  // A top-level destination that navigates directly on tap.
  Widget _navItem({
    required IconData icon,
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
    required bool compact,
    required bool iconOnly,
  }) {
    final item = _NavPill(
      icon: icon,
      label: label,
      active: isSelected,
      compact: compact,
      iconOnly: iconOnly,
      onTap: onTap,
    );
    return iconOnly ? Tooltip(message: label, child: item) : item;
  }

  // A top-level destination that opens a dropdown of sub-routes on tap/hover.
  Widget _navDropdown({
    required IconData icon,
    required String label,
    required bool isSelected,
    required bool compact,
    required bool iconOnly,
    required List<Widget> Function(MenuController controller) items,
  }) {
    return _HoverMenu(
      items: items,
      trigger: (controller, isOpen) {
        final trigger = _NavPill(
          icon: icon,
          label: label,
          active: isSelected,
          open: isOpen,
          chevron: true,
          compact: compact,
          iconOnly: iconOnly,
          onTap: () => controller.isOpen ? controller.close() : controller.open(),
        );
        // With the labels hidden, the tooltip is the only name the button has.
        return iconOnly ? Tooltip(message: label, child: trigger) : trigger;
      },
    );
  }

  // One row in a dropdown. The page you are on is tinted and carries a check, so the menu answers
  // "where am I" at a glance. Built on MenuItemButton so keyboard navigation still works.
  Widget _dropdownMenuItem({
    required IconData icon,
    required String label,
    required String route,
    required MenuController controller,
    required String location,
  }) {
    final bool here = location == route || (route == '/dashboards/financial' && location == '/dashboards');
    return MenuItemButton(
      style: MenuItemButton.styleFrom(
        backgroundColor: here ? _activeTint : Colors.transparent,
        overlayColor: _inkColor,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        minimumSize: const Size(0, 42),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      leadingIcon: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: here ? Colors.white : _fieldFill,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, size: 16, color: here ? _brandRed : _mutedIconColor),
      ),
      trailingIcon: SizedBox(
        width: 16,
        child: here ? const Icon(Icons.check_rounded, size: 16, color: _brandRed) : null,
      ),
      onPressed: () {
        controller.close();
        context.go(route);
      },
      child: SizedBox(
        width: 188,
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13,
            fontWeight: here ? FontWeight.w700 : FontWeight.w600,
            color: _inkColor,
          ),
        ),
      ),
    );
  }

  Widget _menuSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 10, right: 10, top: 12, bottom: 4),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w800,
          color: _mutedIconColor,
          letterSpacing: 0.8,
        ),
      ),
    );
  }

  Widget _menuDivider() => const Padding(
        padding: EdgeInsets.symmetric(vertical: 4, horizontal: 4),
        child: Divider(height: 1, color: _strokeBorder),
      );

  Widget _searchField(double maxWidth, {required bool compact}) {
    OutlineInputBorder border(Color c, [double w = 1]) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: c == Colors.transparent ? BorderSide.none : BorderSide(color: c, width: w),
        );

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth, minWidth: 150),
      child: SizedBox(
        height: 38,
        child: TextField(
          controller: _searchController,
          focusNode: _searchFocus,
          onSubmitted: _handleSearch,
          textInputAction: TextInputAction.search,
          cursorColor: _Bar.fieldText,
          style: const TextStyle(fontSize: 13, color: _Bar.fieldText),
          decoration: InputDecoration(
            hintText: compact ? 'Search…' : 'Search jobs or customers',
            hintStyle: const TextStyle(fontSize: 12.5, color: _Bar.fieldHint),
            prefixIcon: const Icon(Icons.search_rounded, size: 18, color: _Bar.fieldIcon),
            suffixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
            suffixIcon: ListenableBuilder(
              listenable: _searchController,
              builder: (context, _) {
                if (_searchController.text.isEmpty) {
                  return const Padding(padding: EdgeInsets.only(right: 8), child: _KeyHint('Ctrl K'));
                }
                return IconButton(
                  tooltip: 'Clear',
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints.tightFor(width: 30, height: 30),
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.close_rounded, size: 16, color: _Bar.fieldIcon),
                  onPressed: _searchController.clear,
                );
              },
            ),
            filled: true,
            fillColor: _Bar.field,
            contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
            border: border(_Bar.fieldBorder),
            enabledBorder: border(_Bar.fieldBorder),
            focusedBorder: border(_brandRed, 1.5),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final int current = widget.navigationShell.currentIndex;
    final String location = GoRouterState.of(context).uri.path;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): _focusSearch,
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): _focusSearch,
      },
      child: Focus(
        autofocus: true,
        skipTraversal: true,
        child: Scaffold(
          appBar: PreferredSize(
            preferredSize: const Size.fromHeight(_barHeight),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final double w = constraints.maxWidth;
                final bool compact = w < _compactWidth;
                _tight = w < _tightWidth;
                return _buildBar(current, location, compact: compact, tight: _tight, iconOnly: w < _iconOnlyWidth);
              },
            ),
          ),
          body: widget.navigationShell,
        ),
      ),
    );
  }

  Widget _buildBar(int current, String location, {required bool compact, required bool tight, required bool iconOnly}) {
    Widget item(IconData icon, String label, String route, MenuController c) =>
        _dropdownMenuItem(icon: icon, label: label, route: route, controller: c, location: location);

    final session = AuthSession.instance;
    final can = _Can(session.canView);

    // The rows of one menu section the user may open, under an optional header.
    List<Widget> section(MenuController c, String? header, List<(String, IconData, String, String)> rows) {
      final shown = [for (final r in rows) if (can(r.$1)) r];
      if (shown.isEmpty) return const [];
      return [
        if (header != null) _menuSectionHeader(header),
        for (final r in shown) item(r.$2, r.$3, r.$4, c),
      ];
    }

    // Joins the non-empty sections with dividers.
    List<Widget> joined(List<List<Widget>> parts) {
      final out = <Widget>[];
      for (final p in parts.where((p) => p.isNotEmpty)) {
        if (out.isNotEmpty) out.add(_menuDivider());
        out.addAll(p);
      }
      return out;
    }

    return Container(
      // Explicit height: Scaffold gives the app bar loose constraints, so without this the bar
      // shrinks to the height of its contents.
      height: _barHeight,
      decoration: BoxDecoration(
        color: _Bar.bg,
        border: const Border(bottom: BorderSide(color: _Bar.border, width: 1)),
        // The dark bar stays flat, like the dashboard headers; only the light bar casts a shadow.
        boxShadow: _darkBar
            ? null
            : [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 6, offset: const Offset(0, 2))],
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: compact ? 14 : 20),
          child: Row(
            children: [
              // --- Brand lockup ---
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _brandRed,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.garage_rounded, size: 18, color: Colors.white),
              ),
              const SizedBox(width: 10),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'IOHD',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: _Bar.textActive,
                      letterSpacing: 0.4,
                      height: 1.15,
                    ),
                  ),
                  if (!compact)
                    const Text(
                      'IOHD Desktop',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w500,
                        color: _Bar.brandSub,
                        height: 1.15,
                      ),
                    ),
                ],
              ),
              SizedBox(width: compact ? 14 : 22),
              Container(width: 1, height: 26, color: _Bar.divider),
              const SizedBox(width: 10),

              // --- Primary nav ---
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      if (can.any(_officeKeys))
                        _navDropdown(
                          icon: Icons.home_work_rounded,
                          label: 'My Office',
                          compact: compact,
                          iconOnly: iconOnly,
                          // Branch 0 holds Statuses, Payments and Invoices.
                          isSelected: [0, 1, 3, 4].contains(current),
                          items: (c) => joined([
                            section(c, 'Operations', [
                              ('customers', Icons.groups_rounded, 'Customers', '/customers'),
                              ('estimates', Icons.request_quote_rounded, 'Estimates', '/estimates'),
                              ('jobs', Icons.build_rounded, 'Jobs', '/jobs'),
                              ('statuses', Icons.timeline_rounded, 'Estimate & Job Statuses', '/statuses'),
                              ('documents', Icons.folder_shared_rounded, 'Documents', '/documents'),
                            ]),
                            section(c, 'Financial', [
                              ('payments', Icons.payment_rounded, 'Payments', '/payments'),
                              ('invoices', Icons.receipt_long_rounded, 'Invoices', '/invoices'),
                            ]),
                            section(c, 'Commercial', [
                              ('site_checks', Icons.assignment_turned_in_rounded, 'Site Checks', '/site-checks'),
                              ('takeoffs', Icons.architecture_rounded, 'Takeoffs', '/takeoffs'),
                            ]),
                          ]),
                        ),
                      if (can('projects')) ...[
                        const SizedBox(width: 2),
                        _navItem(
                          icon: Icons.folder_copy_rounded,
                          label: 'Projects',
                          compact: compact,
                          iconOnly: iconOnly,
                          isSelected: current == 2,
                          onTap: () => _goBranch(2),
                        ),
                      ],
                      if (can('calendar')) ...[
                        const SizedBox(width: 2),
                        _navItem(
                          icon: Icons.calendar_month_rounded,
                          label: 'Calendar',
                          compact: compact,
                          iconOnly: iconOnly,
                          isSelected: current == 5,
                          onTap: () => _goBranch(5),
                        ),
                      ],
                      if (can.any(_inventoryKeys)) ...[
                        const SizedBox(width: 2),
                        _navDropdown(
                          icon: Icons.inventory_2_rounded,
                          label: 'Inventory',
                          compact: compact,
                          iconOnly: iconOnly,
                          isSelected: current == 6,
                          items: (c) => joined([
                            section(c, null, [
                              ('stock', Icons.stacked_bar_chart_rounded, 'Stock Levels', '/inventory'),
                              ('catalog', Icons.category_rounded, 'Product Catalog', '/inventory/catalog'),
                            ]),
                            section(c, 'Purchasing', [
                              ('purchase_orders', Icons.shopping_cart_checkout_rounded, 'Purchase Orders', '/inventory/purchase-orders'),
                              ('vendors', Icons.storefront_rounded, 'Vendors', '/inventory/vendors'),
                            ]),
                          ]),
                        ),
                      ],
                      if (session.isAdmin || can.any(accessKeys('HR'))) ...[
                        const SizedBox(width: 2),
                        _navDropdown(
                          icon: Icons.badge_rounded,
                          label: 'HR',
                          compact: compact,
                          iconOnly: iconOnly,
                          isSelected: current == 7,
                          items: (c) => joined([
                            [
                              ...section(c, null, [
                                ('hr_payroll', Icons.payments_rounded, 'Payroll', '/hr'),
                                ('hr_kpis', Icons.speed_outlined, "KPI's", '/hr/kpis'),
                              ]),
                              if (session.isAdmin) item(Icons.manage_accounts_rounded, 'Team', '/hr/team', c),
                            ],
                            section(c, null, [
                              ('hr_corrections', Icons.rule_folder_outlined, 'Commission Corrections', '/hr/corrections'),
                            ]),
                          ]),
                        ),
                      ],
                      // Only the dashboards this user may view; the whole menu goes if none are allowed.
                      if (can.any(accessKeys('Dashboards'))) ...[
                        const SizedBox(width: 2),
                        _navDropdown(
                          icon: Icons.insights_rounded,
                          label: 'Dashboards',
                          compact: compact,
                          iconOnly: iconOnly,
                          isSelected: current == 8,
                          items: (c) => [
                            for (final d in kAccessGroups.first.items)
                              if (can(d.key)) item(d.icon, d.label, d.route!, c),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),

              const SizedBox(width: 12),
              Container(width: 1, height: 26, color: _Bar.divider),
              const SizedBox(width: 14),

              // --- Search ---
              if (tight)
                IconButton(
                  tooltip: 'Search (Ctrl K)',
                  icon: const Icon(Icons.search_rounded, size: 20, color: _Bar.fieldIcon),
                  onPressed: _showSearchDialog,
                )
              else
                _searchField(compact ? 200 : 290, compact: compact),

              const SizedBox(width: 10),
              _AskButton(iconOnly: tight),
              const SizedBox(width: 12),
              const _AccountMenu(),
            ],
          ),
        ),
      ),
    );
  }
}

/// One destination in the bar: icon, label and (for dropdowns) a chevron. The page you are in gets a
/// soft pill and a short red bar underneath, the bar's single bold element.
class _NavPill extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool active;
  final bool open;
  final bool chevron;
  final bool compact;
  final bool iconOnly;
  final VoidCallback onTap;

  const _NavPill({
    required this.icon,
    required this.label,
    required this.active,
    required this.compact,
    required this.iconOnly,
    required this.onTap,
    this.open = false,
    this.chevron = false,
  });

  @override
  State<_NavPill> createState() => _NavPillState();
}

class _NavPillState extends State<_NavPill> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final bool lit = widget.active || widget.open;
    final Color fill = lit ? _Bar.activeFill : (_hover ? _Bar.hoverFill : Colors.transparent);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          height: 40,
          padding: EdgeInsets.symmetric(horizontal: widget.compact ? 10 : 13),
          decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(10)),
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(widget.icon, size: 17, color: lit || _hover ? _Bar.iconActive : _Bar.icon),
                  if (!widget.iconOnly) ...[
                    const SizedBox(width: 8),
                    Text(
                      widget.label,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: widget.active ? FontWeight.w700 : FontWeight.w600,
                        color: lit || _hover ? _Bar.textActive : _Bar.text,
                        letterSpacing: -0.1,
                      ),
                    ),
                  ],
                  if (widget.chevron) ...[
                    const SizedBox(width: 2),
                    AnimatedRotation(
                      turns: widget.open ? 0.5 : 0,
                      duration: const Duration(milliseconds: 140),
                      child: Icon(Icons.keyboard_arrow_down_rounded, size: 16, color: lit || _hover ? _Bar.iconActive : _Bar.icon),
                    ),
                  ],
                ],
              ),
              // Sits on the bottom edge of the bar (the pill is centered in it), like a tab underline.
              Positioned(
                bottom: -10,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOut,
                  width: widget.active ? 22 : 0,
                  height: 3,
                  decoration: const BoxDecoration(
                    color: _brandRed,
                    borderRadius: BorderRadius.vertical(top: Radius.circular(3)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Opens the read-only AI assistant panel.
class _AskButton extends StatelessWidget {
  final bool iconOnly;
  const _AskButton({required this.iconOnly});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Ask Jarvis',
      child: InkWell(
        onTap: () => showAssistantPanel(context),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          height: 38,
          padding: EdgeInsets.symmetric(horizontal: iconOnly ? 10 : 13),
          decoration: BoxDecoration(color: _activeTint, borderRadius: BorderRadius.circular(10)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.auto_awesome_rounded, size: 16, color: _brandRed),
              if (!iconOnly) ...[
                const SizedBox(width: 7),
                const Text('Ask Jarvis',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _brandRed)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Small keyboard hint shown inside the empty search field.
class _KeyHint extends StatelessWidget {
  final String text;
  const _KeyHint(this.text);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: _Bar.keyHintBg,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: _Bar.keyHintBorder),
      ),
      child: Text(text, style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: _Bar.keyHintText)),
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
    // A short grace period lets the pointer cross the gap between the button and the menu.
    Future.delayed(const Duration(milliseconds: 220), () {
      if (!_isHovering && _controller.isOpen && mounted) _controller.close();
    });
  }

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      controller: _controller,
      alignmentOffset: const Offset(0, 6),
      onOpen: () => setState(() => _isOpen = true),
      onClose: () => setState(() => _isOpen = false),
      style: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll(Colors.white),
        elevation: const WidgetStatePropertyAll(10),
        shadowColor: WidgetStatePropertyAll(Colors.black.withValues(alpha: 0.18)),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.white),
        minimumSize: const WidgetStatePropertyAll(Size(260, 0)),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(8)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
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
            crossAxisAlignment: CrossAxisAlignment.stretch,
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

/// The signed-in user, with a sign-out action. Signing out sends the router back to /login.
class _AccountMenu extends StatelessWidget {
  const _AccountMenu();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AuthSession.instance,
      builder: (context, _) {
        final session = AuthSession.instance;
        final parts = session.name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
        final initials = parts.isEmpty
            ? '?'
            : (parts.length == 1 ? parts.first[0] : parts.first[0] + parts.last[0]).toUpperCase();

        return PopupMenuButton<String>(
          tooltip: session.name.isEmpty ? 'Account' : session.name,
          offset: const Offset(0, 46),
          onSelected: (value) {
            if (value == 'signout') session.logout();
          },
          itemBuilder: (context) => [
            PopupMenuItem<String>(
              enabled: false,
              height: 0,
              padding: EdgeInsets.zero,
              child: Container(
                width: 220,
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                child: Row(
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(color: _activeTint, shape: BoxShape.circle),
                      child: Text(initials,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: _brandRed)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(session.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: _inkColor)),
                          if (session.role.isNotEmpty)
                            Text(session.role,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12, color: _slateColor)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const PopupMenuDivider(height: 1),
            PopupMenuItem<String>(
              value: 'signout',
              height: 42,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(color: const Color(0xFFFEF2F2), borderRadius: BorderRadius.circular(8)),
                    child: const Icon(Icons.logout_rounded, size: 16, color: Color(0xFFB91C1C)),
                  ),
                  const SizedBox(width: 10),
                  const Text('Sign out',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFFB91C1C))),
                ],
              ),
            ),
          ],
          child: Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _Bar.avatarBg,
              shape: BoxShape.circle,
              border: _darkBar ? Border.all(color: _Bar.divider) : null,
            ),
            child: Text(initials, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: _Bar.avatarText)),
          ),
        );
      },
    );
  }
}

/// `can('key')` for one page or action, `can.any(keys)` for "at least one of these".
class _Can {
  final bool Function(String key) _check;
  const _Can(this._check);
  bool call(String key) => _check(key);
  bool any(Iterable<String> keys) => keys.any(_check);
}

final List<String> _officeKeys = accessKeys('My Office');
final List<String> _inventoryKeys = accessKeys('Inventory');
