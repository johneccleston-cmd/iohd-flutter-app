import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;

import '../config/access.dart';
import '../config/api_config.dart';
import '../config/auth_session.dart';
import '../theme/app_theme.dart';
import 'app_dialog.dart';
import 'assistant_panel.dart';
import 'dashboard_kit.dart';

// --- Design tokens ---------------------------------------------------------
// The bar is white and its menus are white panels, like the dashboards' pop-ups. Red marks the page you are on
// (and Ask Jarvis, the one branded action); everything else is ink and slate, so that mark is easy to find.
const Color _brandRed = AppTheme.brandRed;
const Color _activeTint = Color(0xFFFCEEEE); // the current page's row in a menu
const Color _focusRing = DashUi.blue; // keyboard focus, the same ring the payroll screen uses

// The bar itself. true = dark slate like the dashboard headers, false = the white bar.
const bool _darkBar = false;


class _Bar {
  _Bar._();

  static const bg = _darkBar ? Color(0xFF0F172A) : Colors.white;
  static const border = _darkBar ? Color(0xFF1E293B) : AppTheme.strokeBorder;
  static const divider = _darkBar ? Color(0xFF334155) : AppTheme.strokeBorder;

  static const text = _darkBar ? Color(0xFFCBD5E1) : DashUi.slate;
  static const textActive = _darkBar ? Colors.white : DashUi.ink;
  static const icon = _darkBar ? Color(0xFF94A3B8) : DashUi.subtle;
  static const iconActive = _darkBar ? Colors.white : _brandRed;
  static const hoverFill = _darkBar ? Color(0x0FFFFFFF) : AppTheme.subtleFill; // white at 6%

  static const field = _darkBar ? Color(0xFF1E293B) : Colors.white;
  static const fieldBorder = _darkBar ? Color(0xFF334155) : DashUi.line;
  static const fieldText = _darkBar ? Colors.white : DashUi.ink;
  static const fieldHint = _darkBar ? Color(0xFF94A3B8) : DashUi.subtle;
  static const fieldIcon = _darkBar ? Color(0xFF94A3B8) : DashUi.slate;

  static const avatarBg = _darkBar ? Color(0xFF1E293B) : DashUi.faint;
  static const avatarText = _darkBar ? Colors.white : DashUi.slate;
}

/// Sizes shared by the widgets and by [_fitBar], which measures with them, so the two can't drift apart.
class _M {
  _M._();

  static const double bar = 60;
  static const double pill = 40;
  static const double control = 38; // search, Ask Jarvis and the account circle share one height
  static const double tabPad = 12;
  static const double tabPadCompact = 9;
  static const double tabGap = 2;
  static const double icon = 18;
  static const double iconGap = 8;
  static const double chevronSize = 16;
  static const double chevronGap = 2;
  static const double logoWidth = 84; // the 600x330 logo at 46 high
  static const double askPad = 13;

  static const tabText = TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, letterSpacing: -0.1);
  static const askText = TextStyle(fontSize: 13, fontWeight: FontWeight.w700);

  static double tab(double labelWidth, {required bool chevron, bool compact = false, bool showLabel = true}) =>
      (compact ? tabPadCompact : tabPad) * 2 +
      icon +
      (showLabel ? iconGap + labelWidth : 0) +
      (chevron ? chevronGap + chevronSize : 0);
}

// Hover waits this long before opening a menu, so sweeping the pointer across the bar doesn't flash every menu open.
const Duration _hoverIntent = Duration(milliseconds: 120);
// And this long after the pointer leaves before closing one, so it can cross the gap between button and menu.
const Duration _hoverGrace = Duration(milliseconds: 220);

// --- Structure ---------------------------------------------------------------

/// One page in a menu.
class _NavLink {
  final IconData icon;
  final String label;
  final String route;
  const _NavLink(this.icon, this.label, this.route);
}

/// A run of pages in a menu, under an optional heading.
class _NavGroup {
  final String? title;
  final List<_NavLink> links;
  const _NavGroup(this.title, this.links);
}

/// A top-level entry: a page of its own ([branch]), or a menu of [groups].
class _NavModule {
  final String label;
  final IconData icon;
  final List<int> branches; // the shell branches that count as being in this module
  final int? branch;
  final List<_NavGroup> groups;

  _NavModule.page(this.label, this.icon, int this.branch) : branches = [branch], groups = const [];

  _NavModule.menu(this.label, this.icon, this.branches, List<_NavGroup> groups)
      : branch = null,
        groups = [for (final g in groups) if (g.links.isNotEmpty) g];

  bool get isMenu => branch == null;
  Iterable<_NavLink> get links => groups.expand((g) => g.links);
}

/// The bar for whoever is signed in: only the pages they may open, and no menu that would open empty.
List<_NavModule> _navFor(AuthSession session) {
  final can = session.canView;
  _NavGroup group(String? title, List<(String, IconData, String, String)> rows) =>
      _NavGroup(title, [for (final r in rows) if (can(r.$1)) _NavLink(r.$2, r.$3, r.$4)]);

  final modules = [
    // Branch 0 holds Statuses, Payments, Invoices, Documents, Site Checks and Takeoffs.
    _NavModule.menu('My Office', Icons.home_work_rounded, const [0, 1, 3, 4], [
      group('Operations', [
        ('customers', Icons.groups_rounded, 'Customers', '/customers'),
        ('estimates', Icons.request_quote_rounded, 'Estimates', '/estimates'),
        ('jobs', Icons.build_rounded, 'Jobs', '/jobs'),
        ('statuses', Icons.timeline_rounded, 'Estimate & Job Statuses', '/statuses'),
        ('documents', Icons.folder_shared_rounded, 'Documents', '/documents'),
      ]),
      group('Financial', [
        ('payments', Icons.payment_rounded, 'Payments', '/payments'),
        ('invoices', Icons.receipt_long_rounded, 'Invoices', '/invoices'),
      ]),
      group('Commercial', [
        ('site_checks', Icons.assignment_turned_in_rounded, 'Site Checks', '/site-checks'),
        ('takeoffs', Icons.architecture_rounded, 'Takeoffs', '/takeoffs'),
      ]),
    ]),
    if (can('projects')) _NavModule.page('Projects', Icons.folder_copy_rounded, 2),
    if (can('calendar')) _NavModule.page('Calendar', Icons.calendar_month_rounded, 5),
    _NavModule.menu('Inventory', Icons.inventory_2_rounded, const [6], [
      group(null, [
        ('stock', Icons.stacked_bar_chart_rounded, 'Stock Levels', '/inventory'),
        ('catalog', Icons.category_rounded, 'Product Catalog', '/inventory/catalog'),
      ]),
      group('Purchasing', [
        ('purchase_orders', Icons.shopping_cart_checkout_rounded, 'Purchase Orders', '/inventory/purchase-orders'),
        ('vendors', Icons.storefront_rounded, 'Vendors', '/inventory/vendors'),
      ]),
    ]),
    // Commission corrections is a button on the Payroll screen, not a menu entry.
    _NavModule.menu('HR', Icons.badge_rounded, const [7], [
      _NavGroup(null, [
        ...group(null, [
          ('hr_payroll', Icons.payments_rounded, 'Payroll', '/hr/payroll'),
          ('hr_kpis', Icons.speed_outlined, "KPI's", '/hr/kpis'),
        ]).links,
        if (session.isAdmin) const _NavLink(Icons.manage_accounts_rounded, 'Team', '/hr/team'),
      ]),
    ]),
    _NavModule.menu('Dashboards', Icons.insights_rounded, const [8], [
      _NavGroup(null, [
        for (final d in kAccessGroups.firstWhere((g) => g.title == 'Dashboards').items)
          if (can(d.key)) _NavLink(d.icon, d.label, d.route!),
      ]),
    ]),
  ];
  return [for (final m in modules) if (!m.isMenu || m.groups.isNotEmpty) m];
}

// Pages that have no menu row of their own, and the row that stands for them.
const Map<String, String> _routeAliases = {
  '/dashboards': '/dashboards/financial',
  '/hr/corrections': '/hr/payroll', // opened from the Payroll screen
};

/// The menu row for [location]: the longest route it is or sits under, so /jobs/123 is Jobs and /inventory/catalog
/// is Product Catalog rather than Stock Levels.
String? _hereRoute(String location, Iterable<_NavModule> modules) {
  final loc = _routeAliases[location] ?? location;
  String? best;
  for (final l in modules.expand((m) => m.links)) {
    final r = l.route;
    if ((loc == r || loc.startsWith('$r/')) && (best == null || r.length > best.length)) best = r;
  }
  return best;
}

// --- Fitting the bar to the window -----------------------------------------

/// What the bar shows at the current width and text size.
class _Fit {
  final bool collapsed; // the modules sit behind one menu button that opens the drawer
  final bool menuLabel; // that button names the module you are in
  final bool compact; // tighter module buttons
  final double? search; // the field's width; null = an icon that opens a search box
  final bool askLabel;
  final bool dense; // no rules beside the logo and before the utilities, tighter gaps

  const _Fit({
    this.collapsed = false,
    this.menuLabel = true,
    this.compact = false,
    this.search,
    this.askLabel = false,
    this.dense = false,
  });
}

// In order of preference: every module labelled while the search field shrinks to an icon, then the modules behind
// the menu button (which leaves room for the field again).
const List<_Fit> _fits = [
  _Fit(search: 300, askLabel: true),
  _Fit(search: 240, askLabel: true),
  _Fit(search: 200, askLabel: true),
  _Fit(search: 180),
  _Fit(),
  _Fit(compact: true, dense: true),
  _Fit(collapsed: true, search: 240, askLabel: true),
  _Fit(collapsed: true, search: 180),
  _Fit(collapsed: true),
  _Fit(collapsed: true, dense: true),
  _Fit(collapsed: true, menuLabel: false, dense: true),
];

double _barPad(_Fit f, double width) => f.dense ? 14 : (width < 600 ? 16 : 20);

double _textWidth(BuildContext context, String text, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: DefaultTextStyle.of(context).style.merge(style)),
    textDirection: TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final w = painter.width.ceilToDouble();
  painter.dispose();
  return w;
}

/// Picks the first [_fits] entry that fits [width], measured from the real labels at the real text size, so larger
/// text or a longer label folds the bar sooner instead of clipping it.
_Fit _fitBar(
  BuildContext context,
  double width, {
  required List<_NavModule> modules,
  required Map<String, double> labels,
  required String menuText,
  required bool search,
}) {
  double tabs({required bool compact}) =>
      modules.fold<double>(0, (s, m) => s + _M.tab(labels[m.label]!, chevron: m.isMenu, compact: compact)) +
      _M.tabGap * math.max(0, modules.length - 1);
  final full = tabs(compact: false);
  final compact = tabs(compact: true);
  final ask = _M.askPad * 2 + 16 + 7 + _textWidth(context, 'Ask Jarvis', _M.askText);

  double needed(_Fit f) {
    final gap = f.dense ? 8.0 : 10.0;
    final nav = f.collapsed
        ? _M.tab(labels[menuText]!, chevron: false, showLabel: f.menuLabel)
        : (f.compact ? compact : full);
    return _barPad(f, width) * 2 +
        _M.logoWidth +
        (f.dense ? 8 : 14 + 1 + 10) +
        nav +
        (f.dense ? 8 : 12 + 1 + 14) +
        (search ? (f.search ?? _M.control) + gap : 0) +
        (f.askLabel ? ask : _M.control) +
        (f.dense ? 8 : 12) +
        _M.control +
        4; // slack for rounding
  }

  return _fits.firstWhere((f) => needed(f) <= width, orElse: () => _fits.last);
}

// --- The shell ----------------------------------------------------------------

class MainNavigationShell extends StatefulWidget {
  final StatefulNavigationShell navigationShell;

  const MainNavigationShell({super.key, required this.navigationShell});

  @override
  State<MainNavigationShell> createState() => _MainNavigationShellState();
}

class _MainNavigationShellState extends State<MainNavigationShell> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final FocusNode _menuButtonFocus = FocusNode(debugLabel: 'All pages');
  final GlobalKey<ScaffoldState> _scaffold = GlobalKey<ScaffoldState>();

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    _menuButtonFocus.dispose();
    super.dispose();
  }

  void _goBranch(int index) {
    widget.navigationShell.goBranch(
      index,
      initialLocation: index == widget.navigationShell.currentIndex,
    );
  }

  /// Where a search goes: a number is a job, anything else a customer. When the account can't open that list it
  /// searches the other one; null when it can open neither (and the search control is left out).
  String? _searchPath(String query) {
    final session = AuthSession.instance;
    final lists = int.tryParse(query) != null ? ['jobs', 'customers'] : ['customers', 'jobs'];
    for (final key in lists) {
      if (session.canView(key)) return '/$key';
    }
    return null;
  }

  bool get _canSearch => _searchPath('') != null;

  void _handleSearch(String rawQuery) {
    final query = rawQuery.trim();
    if (query.isEmpty) return;
    final path = _searchPath(query);
    if (path == null) return;
    context.go('$path?q=${Uri.encodeQueryComponent(query)}');
  }

  Future<void> _showSearchDialog() async {
    final session = AuthSession.instance;
    final subtitle = session.canView('jobs') && session.canView('customers')
        ? 'A job number opens Jobs. Anything else searches Customers.'
        : session.canView('jobs')
            ? 'Searches Jobs.'
            : 'Searches Customers.';
    final query = await showDialog<String>(context: context, builder: (_) => _SearchDialog(subtitle: subtitle));
    if (query != null && mounted) _handleSearch(query);
  }

  bool _assistantOpen = false;

  /// Ctrl+J / Cmd+J and the Ask Jarvis button. Ignored while the panel is already open.
  void _openAssistant() {
    if (_assistantOpen) return;
    _assistantOpen = true;
    showAssistantPanel(context).whenComplete(() => _assistantOpen = false);
  }

  @override
  Widget build(BuildContext context) {
    final session = AuthSession.instance;
    final modules = _navFor(session);
    final current = widget.navigationShell.currentIndex;
    final here = _hereRoute(GoRouterState.of(context).uri.path, modules);
    final active = modules.where((m) => m.branches.contains(current)).firstOrNull;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyJ, control: true): _openAssistant,
        const SingleActivator(LogicalKeyboardKey.keyJ, meta: true): _openAssistant,
      },
      child: Focus(
        autofocus: true,
        skipTraversal: true,
        // Escape closes a menu that hover opened (one opened from the keyboard handles Escape itself).
        onKeyEvent: (node, event) =>
            event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape && _NavMenuState.dismissShown()
                ? KeyEventResult.handled
                : KeyEventResult.ignored,
        child: Scaffold(
          key: _scaffold,
          drawerEnableOpenDragGesture: false,
          onDrawerChanged: (open) {
            if (!open) _menuButtonFocus.requestFocus();
          },
          drawer: _NavDrawer(
            modules: modules,
            active: active,
            here: here,
            onGo: (route) => context.go(route),
            onGoBranch: _goBranch,
          ),
          appBar: PreferredSize(
            preferredSize: const Size.fromHeight(_M.bar),
            child: SelectionContainer.disabled(
              child: LayoutBuilder(
                builder: (context, constraints) => _buildBar(context, constraints.maxWidth, modules, active, here),
              ),
            ),
          ),
          body: widget.navigationShell,
        ),
      ),
    );
  }

  Widget _buildBar(BuildContext context, double width, List<_NavModule> modules, _NavModule? active, String? here) {
    final menuText = active?.label ?? 'Menu';
    final labels = {for (final t in {...modules.map((m) => m.label), menuText}) t: _textWidth(context, t, _M.tabText)};
    final canSearch = _canSearch;
    final fit = _fitBar(context, width, modules: modules, labels: labels, menuText: menuText, search: canSearch);
    final gap = fit.dense ? 8.0 : 10.0;

    return Container(
      // Explicit height: Scaffold gives the app bar loose constraints, so without this the bar
      // shrinks to the height of its contents.
      height: _M.bar,
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
          padding: EdgeInsets.symmetric(horizontal: _barPad(fit, width)),
          child: Row(
            children: [
              // --- Brand lockup ---
              Semantics(
                label: 'Integrity Overhead Door',
                image: true,
                child: Image.asset(
                  'assets/images/iohd_logo.png',
                  height: 46,
                  width: _M.logoWidth,
                  filterQuality: FilterQuality.medium,
                ),
              ),
              if (fit.dense) const SizedBox(width: 8) else ...[
                const SizedBox(width: 14),
                Container(width: 1, height: 26, color: _Bar.divider),
                const SizedBox(width: 10),
              ],

              // --- Modules ---
              if (fit.collapsed)
                _NavTab(
                  icon: Icons.menu_rounded,
                  label: menuText,
                  labelWidth: labels[menuText]!,
                  showLabel: fit.menuLabel,
                  current: true,
                  semanticLabel: 'Menu: $menuText',
                  tooltip: 'All pages',
                  focusNode: _menuButtonFocus,
                  onTap: () => _scaffold.currentState?.openDrawer(),
                )
              else
                for (final (i, m) in modules.indexed) ...[
                  if (i > 0) const SizedBox(width: _M.tabGap),
                  if (m.isMenu)
                    _NavMenu(
                      key: ValueKey(m.label),
                      module: m,
                      active: m == active,
                      here: here,
                      labelWidth: labels[m.label]!,
                      compact: fit.compact,
                      onGo: (route) => context.go(route),
                    )
                  else
                    _NavTab(
                      key: ValueKey(m.label),
                      icon: m.icon,
                      label: m.label,
                      labelWidth: labels[m.label]!,
                      active: m == active,
                      compact: fit.compact,
                      onTap: () => _goBranch(m.branch!),
                    ),
                ],
              SizedBox(width: fit.dense ? 8 : 12),
              const Spacer(),
              if (!fit.dense) ...[
                Container(width: 1, height: 26, color: _Bar.divider),
                const SizedBox(width: 14),
              ],

              // --- Utilities ---
              if (canSearch) ...[
                if (fit.search == null)
                  _Tap(
                    label: 'Search',
                    tooltip: 'Search',
                    onTap: _showSearchDialog,
                    builder: (hover, focus) => _squareIcon(Icons.search_rounded, hover: hover, focus: focus),
                  )
                else
                  _searchField(context, fit.search!),
                SizedBox(width: gap),
              ],
              _AskButton(showLabel: fit.askLabel, onTap: _openAssistant),
              SizedBox(width: fit.dense ? 8 : 12),
              const _AccountMenu(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _searchField(BuildContext context, double width) {
    OutlineInputBorder border(Color c, [double w = 1]) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: c, width: w),
        );

    // The long hint shows only when it fits at this text size.
    const longHint = 'Search jobs or customers';
    const shortHint = 'Search…';
    final inner = width - 36 - 12 - 8; // icon, left padding, right padding
    final hint = _textWidth(context, longHint, _searchText) <= inner ? longHint : shortHint;

    return SizedBox(
      width: width,
      height: _M.control,
      child: TextField(
        controller: _searchController,
        focusNode: _searchFocus,
        onSubmitted: _handleSearch,
        textInputAction: TextInputAction.search,
        cursorColor: _Bar.fieldText,
        style: _searchText.copyWith(color: _Bar.fieldText),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: _searchText.copyWith(color: _Bar.fieldHint),
          prefixIcon: const Icon(Icons.search_rounded, size: 18, color: _Bar.fieldIcon),
          prefixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: _M.control),
          suffixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
          suffixIcon: ListenableBuilder(
            listenable: _searchController,
            builder: (context, _) {
              if (_searchController.text.isEmpty) return const SizedBox.shrink();
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
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          border: border(_Bar.fieldBorder),
          enabledBorder: border(_Bar.fieldBorder),
          focusedBorder: border(_brandRed, 1.5),
        ),
      ),
    );
  }
}

const TextStyle _searchText = TextStyle(fontSize: 13);

/// The search box the search icon opens when the bar has no room for the field.
class _SearchDialog extends StatefulWidget {
  final String subtitle;
  const _SearchDialog({required this.subtitle});

  @override
  State<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<_SearchDialog> {
  // Owned here rather than by the caller, so it lives until the dialog has finished animating away.
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppDialog(
      title: 'Search',
      subtitle: widget.subtitle,
      icon: Icons.search_rounded,
      width: 440,
      body: TextField(
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.search,
        decoration: appFieldDecoration(hint: 'Search jobs or customers'),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        AppButton.ghost('Cancel', () => Navigator.pop(context)),
        AppButton.ink('Search', () => Navigator.pop(context, _controller.text), icon: Icons.search_rounded),
      ],
    );
  }
}

// --- Building blocks ------------------------------------------------------------

class _OpenMenuIntent extends Intent {
  const _OpenMenuIntent();
}

class _MenuEdgeIntent extends Intent {
  final bool first;
  const _MenuEdgeIntent({required this.first});
}

/// Something you can click, reach with Tab and press with Enter or Space, which a screen reader hears as a button:
/// every control in the bar and the drawer. The blue ring shows for keyboard focus only, as on the payroll screen.
class _Tap extends StatefulWidget {
  final String label;
  final bool? selected;
  final bool? expanded;
  final String? tooltip;
  final FocusNode? focusNode;
  final VoidCallback onTap; // pointer
  final VoidCallback? onActivate; // Enter, Space or a screen reader; defaults to onTap
  final VoidCallback? onArrowDown;
  final Widget Function(bool hover, bool focus) builder;

  const _Tap({
    required this.label,
    required this.onTap,
    required this.builder,
    this.selected,
    this.expanded,
    this.tooltip,
    this.focusNode,
    this.onActivate,
    this.onArrowDown,
  });

  @override
  State<_Tap> createState() => _TapState();
}

class _TapState extends State<_Tap> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final activate = widget.onActivate ?? widget.onTap;
    final arrowDown = widget.onArrowDown;
    Widget tile = FocusableActionDetector(
      focusNode: widget.focusNode,
      mouseCursor: SystemMouseCursors.click,
      shortcuts: arrowDown == null ? null : const {SingleActivator(LogicalKeyboardKey.arrowDown): _OpenMenuIntent()},
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          activate();
          return null;
        }),
        if (arrowDown != null)
          _OpenMenuIntent: CallbackAction<_OpenMenuIntent>(onInvoke: (_) {
            arrowDown();
            return null;
          }),
      },
      onShowFocusHighlight: (v) => setState(() => _focus = v),
      // Hover follows the pointer itself: onShowHoverHighlight stays off in touch highlight mode, which is the
      // default on a phone or tablet even with a mouse attached.
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // The Semantics below carries the tap. A second one here would split the focus state off into an
          // unlabelled node of its own.
          excludeFromSemantics: true,
          onTap: widget.onTap,
          child: ExcludeSemantics(child: widget.builder(_hover, _focus)),
        ),
      ),
    );
    final tip = widget.tooltip;
    // Inside the button node, so a screen reader hears the tooltip as this button's hint.
    if (tip != null) tile = Tooltip(message: tip, child: tile);
    return Semantics(
      container: true,
      button: true,
      selected: widget.selected,
      expanded: widget.expanded,
      label: widget.label,
      onTap: activate,
      child: tile,
    );
  }
}

BoxDecoration? _ring(bool focus, {BorderRadius? radius, BoxShape shape = BoxShape.rectangle}) => focus
    ? BoxDecoration(
        borderRadius: radius,
        shape: shape,
        border: Border.all(color: _focusRing, width: 2),
      )
    : null;

Duration _motion(BuildContext context, int ms) =>
    MediaQuery.disableAnimationsOf(context) ? Duration.zero : Duration(milliseconds: ms);

Widget _squareIcon(IconData icon, {required bool hover, required bool focus}) => Container(
      width: _M.control,
      height: _M.control,
      decoration: BoxDecoration(
        color: hover ? _Bar.hoverFill : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
      ),
      foregroundDecoration: _ring(focus, radius: BorderRadius.circular(10)),
      child: Icon(icon, size: 20, color: _Bar.fieldIcon),
    );

/// One module in the bar: icon, label and (for a menu) a chevron. The module you are in gets a red rule on the bar's
/// bottom edge, like a tab, with a red icon and a bold label; hover and an open menu get a quiet grey pill.
class _NavTab extends StatelessWidget {
  final IconData icon;
  final String label;
  final double labelWidth; // the label's bold width, so turning bold never shifts the bar
  final bool showLabel;
  final bool active;
  final bool current; // the label names where you are (the menu button), so it reads in ink and bold
  final bool open;
  final bool chevron;
  final bool compact;
  final bool? expanded;
  final String? semanticLabel;
  final String? tooltip;
  final FocusNode? focusNode;
  final VoidCallback onTap;
  final VoidCallback? onActivate;
  final VoidCallback? onArrowDown;

  const _NavTab({
    super.key,
    required this.icon,
    required this.label,
    required this.labelWidth,
    required this.onTap,
    this.showLabel = true,
    this.active = false,
    this.current = false,
    this.open = false,
    this.chevron = false,
    this.compact = false,
    this.expanded,
    this.semanticLabel,
    this.tooltip,
    this.focusNode,
    this.onActivate,
    this.onArrowDown,
  });

  @override
  Widget build(BuildContext context) {
    final motion = _motion(context, 140);
    return _Tap(
      label: semanticLabel ?? label,
      selected: active ? true : null,
      expanded: expanded,
      tooltip: tooltip,
      focusNode: focusNode,
      onTap: onTap,
      onActivate: onActivate,
      onArrowDown: onArrowDown,
      builder: (hover, focus) {
        final lit = active || open || hover;
        final radius = BorderRadius.circular(10);
        return SizedBox(
          height: _M.bar,
          child: Stack(
            alignment: Alignment.center,
            children: [
              AnimatedContainer(
                duration: motion,
                height: _M.pill,
                padding: EdgeInsets.symmetric(horizontal: compact ? _M.tabPadCompact : _M.tabPad),
                decoration: BoxDecoration(
                  color: open || hover ? _Bar.hoverFill : _Bar.hoverFill.withValues(alpha: 0),
                  borderRadius: radius,
                ),
                foregroundDecoration: _ring(focus, radius: radius),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: _M.icon, color: active ? _Bar.iconActive : (lit ? _Bar.textActive : _Bar.icon)),
                    if (showLabel) ...[
                      const SizedBox(width: _M.iconGap),
                      SizedBox(
                        width: labelWidth,
                        child: Text(
                          label,
                          maxLines: 1,
                          softWrap: false,
                          textAlign: TextAlign.center,
                          style: _M.tabText.copyWith(
                            fontWeight: active || current ? FontWeight.w700 : FontWeight.w600,
                            color: lit || current ? _Bar.textActive : _Bar.text,
                          ),
                        ),
                      ),
                    ],
                    if (chevron) ...[
                      const SizedBox(width: _M.chevronGap),
                      AnimatedRotation(
                        turns: open ? 0.5 : 0,
                        duration: motion,
                        child: Icon(
                          Icons.keyboard_arrow_down_rounded,
                          size: _M.chevronSize,
                          color: open || hover ? _Bar.textActive : _Bar.icon,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Positioned(
                left: 8,
                right: 8,
                bottom: 0,
                child: AnimatedContainer(
                  duration: motion,
                  curve: Curves.easeOut,
                  height: 3,
                  decoration: BoxDecoration(
                    color: active ? _brandRed : _brandRed.withValues(alpha: 0),
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

final MenuStyle _menuStyle = MenuStyle(
  backgroundColor: const WidgetStatePropertyAll(Colors.white),
  surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
  elevation: const WidgetStatePropertyAll(8),
  shadowColor: WidgetStatePropertyAll(Colors.black.withValues(alpha: 0.14)),
  minimumSize: const WidgetStatePropertyAll(Size(232, 0)),
  padding: const WidgetStatePropertyAll(EdgeInsets.all(6)),
  shape: WidgetStatePropertyAll(
    RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: DashUi.line)),
  ),
);

/// [_menuStyle], no taller than the room under the bar: in a short window the menu scrolls instead of sliding up
/// over the bar and its own button.
MenuStyle _menuStyleFor(BuildContext context, {double? width}) => _menuStyle.copyWith(
      minimumSize: width == null ? null : WidgetStatePropertyAll(Size(width, 0)),
      maximumSize: WidgetStatePropertyAll(
        Size(width ?? double.infinity, math.max(160, MediaQuery.sizeOf(context).height - _M.bar - 16)),
      ),
    );

ButtonStyle _menuRowStyle({required bool here}) => ButtonStyle(
      backgroundColor: WidgetStatePropertyAll(here ? _activeTint : Colors.transparent),
      overlayColor: WidgetStateProperty.resolveWith((s) {
        if (s.contains(WidgetState.pressed)) return DashUi.ink.withValues(alpha: 0.08);
        if (s.contains(WidgetState.hovered)) return DashUi.ink.withValues(alpha: 0.05);
        return Colors.transparent;
      }),
      side: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.focused) ? const BorderSide(color: _focusRing, width: 2) : null,
      ),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)),
      minimumSize: const WidgetStatePropertyAll(Size(0, 40)),
      shape: const WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(8)))),
      mouseCursor: const WidgetStatePropertyAll(SystemMouseCursors.click),
    );

/// One page in a menu. The page you are on is tinted, carries a check and reads as selected, so the menu answers
/// "where am I" at a glance.
Widget _menuRow(_NavLink link, {required bool here, required VoidCallback onPressed, FocusNode? focusNode}) {
  return MergeSemantics(
    child: Semantics(
      selected: here ? true : null,
      child: MenuItemButton(
        focusNode: focusNode,
        // Hovering must not pull focus out of a field you are typing in.
        requestFocusOnHover: false,
        onPressed: onPressed,
        style: _menuRowStyle(here: here),
        leadingIcon: Icon(link.icon, size: 18, color: here ? _brandRed : DashUi.subtle),
        trailingIcon: here
            ? const Icon(Icons.check_rounded, size: 18, color: _brandRed)
            : const SizedBox(width: 18),
        child: Text(
          link.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 13.5, fontWeight: here ? FontWeight.w700 : FontWeight.w600, color: DashUi.ink),
        ),
      ),
    ),
  );
}

Widget _menuHeader(String title, {double left = 10}) => Padding(
      padding: EdgeInsets.only(left: left, right: 10, top: 10, bottom: 4),
      child: Semantics(
        header: true,
        child: Text(
          title.toUpperCase(),
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: DashUi.subtle, letterSpacing: 0.6),
        ),
      ),
    );

Widget _menuDivider() => const Padding(
      padding: EdgeInsets.symmetric(vertical: 4, horizontal: 4),
      child: Divider(height: 1, color: DashUi.line),
    );

/// Keyboard behaviour shared by the bar's menus: the panel keeps arrow keys to itself (Up/Down wrap, Home/End jump),
/// Tab leaves the menu for the next control, and closing it from inside puts focus back on its button.
mixin _MenuKeys<T extends StatefulWidget> on State<T> {
  final MenuController menu = MenuController();
  final FocusNode buttonFocus = FocusNode(debugLabel: 'menu button');
  final FocusNode entryFocus = FocusNode(debugLabel: 'menu entry');
  final FocusNode _panelFocus = FocusNode(debugLabel: 'menu panel', canRequestFocus: false, skipTraversal: true);

  void disposeMenuKeys() {
    buttonFocus.dispose();
    entryFocus.dispose();
    _panelFocus.dispose();
  }

  void focusEntrySoon() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && menu.isOpen) entryFocus.requestFocus();
      });

  /// Call from MenuAnchor.onClose.
  void returnFocusIfInside() {
    if (_panelFocus.hasFocus) buttonFocus.requestFocus();
  }

  void _step(int by) {
    final nodes = _panelFocus.traversalDescendants.toList();
    if (nodes.isEmpty) return;
    final at = nodes.indexWhere((n) => n.hasPrimaryFocus);
    final next = at < 0 ? (by > 0 ? 0 : nodes.length - 1) : (at + by) % nodes.length;
    nodes[next].requestFocus();
  }

  void _leave({required bool forward}) {
    menu.close();
    WidgetsBinding.instance.addPostFrameCallback((_) => forward ? buttonFocus.nextFocus() : buttonFocus.previousFocus());
  }

  Widget menuPanel(List<Widget> rows) => Focus(
        focusNode: _panelFocus,
        child: Shortcuts(
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.home): _MenuEdgeIntent(first: true),
            SingleActivator(LogicalKeyboardKey.end): _MenuEdgeIntent(first: false),
          },
          child: Actions(
            actions: {
              DirectionalFocusIntent: CallbackAction<DirectionalFocusIntent>(onInvoke: (i) {
                if (i.direction == TraversalDirection.down) _step(1);
                if (i.direction == TraversalDirection.up) _step(-1);
                return null; // left and right stay put
              }),
              NextFocusIntent: CallbackAction<NextFocusIntent>(onInvoke: (_) {
                _leave(forward: true);
                return null;
              }),
              PreviousFocusIntent: CallbackAction<PreviousFocusIntent>(onInvoke: (_) {
                _leave(forward: false);
                return null;
              }),
              _MenuEdgeIntent: CallbackAction<_MenuEdgeIntent>(onInvoke: (i) {
                final nodes = _panelFocus.traversalDescendants.toList();
                if (nodes.isNotEmpty) (i.first ? nodes.first : nodes.last).requestFocus();
                return null;
              }),
            },
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
          ),
        ),
      );
}

/// A module's menu. Opens on hover (after a short pause), on click, or from the keyboard (Enter, Space or Down,
/// with focus on the page you are on, else the first). Only one is open at a time.
class _NavMenu extends StatefulWidget {
  final _NavModule module;
  final bool active;
  final String? here;
  final double labelWidth;
  final bool compact;
  final ValueChanged<String> onGo;

  const _NavMenu({
    super.key,
    required this.module,
    required this.active,
    required this.here,
    required this.labelWidth,
    required this.compact,
    required this.onGo,
  });

  @override
  State<_NavMenu> createState() => _NavMenuState();
}

class _NavMenuState extends State<_NavMenu> with _MenuKeys {
  static _NavMenuState? _shown;

  /// Closes the menu that is showing, if any. True when there was one.
  static bool dismissShown() {
    final account = _AccountMenuState._shown;
    if (account != null && account.menu.isOpen) {
      account.menu.close();
      return true;
    }
    final shown = _shown;
    if (shown == null || !shown.menu.isOpen) return false;
    shown._hide();
    return true;
  }

  Timer? _openTimer;
  Timer? _closeTimer;
  bool _open = false;
  bool _byHover = false; // opened by hovering: it closes when the pointer leaves, and a click keeps it open
  bool _pointerIn = false;

  @override
  void dispose() {
    _openTimer?.cancel();
    _closeTimer?.cancel();
    if (_shown == this) _shown = null;
    disposeMenuKeys();
    super.dispose();
  }

  void _show({required bool hover, bool focusEntry = false}) {
    _openTimer?.cancel();
    _closeTimer?.cancel();
    final other = _shown;
    if (other != null && other != this) other._hide();
    final account = _AccountMenuState._shown;
    if (account != null && account.menu.isOpen) account.menu.close();
    _byHover = hover;
    if (!menu.isOpen) menu.open();
    if (focusEntry) focusEntrySoon();
  }

  void _hide() {
    _openTimer?.cancel();
    _closeTimer?.cancel();
    if (menu.isOpen) menu.close();
  }

  void _enter() {
    _pointerIn = true;
    _closeTimer?.cancel();
    if (menu.isOpen) return;
    final other = _shown;
    if (other != null && other.menu.isOpen && other._byHover) {
      _show(hover: true); // already browsing the menus: follow the pointer at once
      return;
    }
    _openTimer?.cancel();
    _openTimer = Timer(_hoverIntent, () {
      if (mounted && _pointerIn) _show(hover: true);
    });
  }

  void _exit() {
    _pointerIn = false;
    _openTimer?.cancel();
    // Only a menu that hover opened closes when the pointer leaves; one opened by a click or the keyboard stays.
    if (!menu.isOpen || !_byHover) return;
    _closeTimer?.cancel();
    _closeTimer = Timer(_hoverGrace, () {
      if (mounted && !_pointerIn) _hide();
    });
  }

  void _click() {
    if (!menu.isOpen) {
      _show(hover: false);
    } else if (_byHover) {
      _byHover = false; // the pointer opened it a moment ago; the click means "keep it"
    } else {
      _hide();
    }
  }

  void _keyOpen() => _show(hover: false, focusEntry: true);

  List<Widget> _rows() {
    final links = widget.module.links;
    final entry = links.any((l) => l.route == widget.here) ? widget.here : links.first.route;
    final rows = <Widget>[];
    for (final g in widget.module.groups) {
      if (rows.isNotEmpty) rows.add(_menuDivider());
      if (g.title != null) rows.add(_menuHeader(g.title!));
      for (final l in g.links) {
        rows.add(_menuRow(
          l,
          here: l.route == widget.here,
          focusNode: l.route == entry ? entryFocus : null,
          onPressed: () => widget.onGo(l.route),
        ));
      }
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.module;
    return MenuAnchor(
      controller: menu,
      alignmentOffset: const Offset(0, 2),
      style: _menuStyleFor(context),
      onOpen: () {
        _shown = this;
        if (mounted) setState(() => _open = true);
      },
      onClose: () {
        if (_shown == this) _shown = null;
        returnFocusIfInside();
        if (mounted) setState(() => _open = false);
      },
      menuChildren: [
        MouseRegion(onEnter: (_) => _enter(), onExit: (_) => _exit(), child: menuPanel(_rows())),
      ],
      child: MouseRegion(
        onEnter: (_) => _enter(),
        onExit: (_) => _exit(),
        child: _NavTab(
          icon: m.icon,
          label: m.label,
          labelWidth: widget.labelWidth,
          active: widget.active,
          open: _open,
          chevron: true,
          compact: widget.compact,
          expanded: _open,
          focusNode: buttonFocus,
          onTap: _click,
          onActivate: _keyOpen,
          onArrowDown: _keyOpen,
        ),
      ),
    );
  }
}

/// Every module and page in one panel, for windows too narrow for the bar to show them. The module you are in starts
/// open; the others open and close in place.
class _NavDrawer extends StatefulWidget {
  final List<_NavModule> modules;
  final _NavModule? active;
  final String? here;
  final ValueChanged<String> onGo;
  final ValueChanged<int> onGoBranch;

  const _NavDrawer({
    required this.modules,
    required this.active,
    required this.here,
    required this.onGo,
    required this.onGoBranch,
  });

  @override
  State<_NavDrawer> createState() => _NavDrawerState();
}

class _NavDrawerState extends State<_NavDrawer> {
  late final Set<String> _expanded = {if (widget.active?.isMenu ?? false) widget.active!.label};

  void _go(VoidCallback navigate) {
    Scaffold.of(context).closeDrawer();
    navigate();
  }

  Widget _row({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool top = false,
    bool here = false,
    bool redIcon = false,
    bool? expanded,
  }) {
    final motion = _motion(context, 160);
    return _Tap(
      label: label,
      selected: here ? true : null,
      expanded: expanded,
      onTap: onTap,
      builder: (hover, focus) {
        final radius = BorderRadius.circular(8);
        return Container(
          constraints: BoxConstraints(minHeight: top ? 44 : 40),
          padding: EdgeInsets.only(left: top ? 12 : 40, right: 10),
          decoration: BoxDecoration(
            color: here ? _activeTint : (hover ? _Bar.hoverFill : Colors.transparent),
            borderRadius: radius,
          ),
          foregroundDecoration: _ring(focus, radius: radius),
          child: Row(
            children: [
              Icon(icon, size: top ? 20 : 18, color: here || redIcon ? _brandRed : DashUi.subtle),
              SizedBox(width: top ? 12 : 10),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: top ? 14 : 13.5,
                    fontWeight: top || here ? FontWeight.w700 : FontWeight.w600,
                    color: DashUi.ink,
                  ),
                ),
              ),
              if (expanded != null)
                AnimatedRotation(
                  turns: expanded ? 0.5 : 0,
                  duration: motion,
                  child: const Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: DashUi.subtle),
                )
              else if (here)
                const Icon(Icons.check_rounded, size: 18, color: _brandRed)

            ],
          ),
        );
      },
    );
  }

  List<Widget> _module(_NavModule m) {
    final active = m == widget.active;
    if (!m.isMenu) {
      return [
        _row(icon: m.icon, label: m.label, top: true, here: active, onTap: () => _go(() => widget.onGoBranch(m.branch!))),
      ];
    }
    final open = _expanded.contains(m.label);
    return [
      _row(
        icon: m.icon,
        label: m.label,
        top: true,
        redIcon: active,
        expanded: open,
        onTap: () => setState(() => open ? _expanded.remove(m.label) : _expanded.add(m.label)),
      ),
      AnimatedSize(
        duration: _motion(context, 180),
        curve: Curves.easeOut,
        alignment: Alignment.topCenter,
        child: !open
            ? const SizedBox(width: double.infinity)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final g in m.groups) ...[
                    if (g.title != null) _menuHeader(g.title!, left: 40),
                    for (final l in g.links)
                      _row(
                        icon: l.icon,
                        label: l.label,
                        here: l.route == widget.here,
                                      onTap: () => _go(() => widget.onGo(l.route)),
                      ),
                  ],
                  const SizedBox(height: 4),
                ],
              ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final width = math.min(320.0, MediaQuery.sizeOf(context).width - 48);
    return Drawer(
      width: width,
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.horizontal(right: Radius.circular(16))),
      semanticLabel: 'All pages',
      child: SafeArea(
        child: SelectionContainer.disabled(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
                child: Row(
                  children: [
                    Semantics(
                      label: 'Integrity Overhead Door',
                      image: true,
                      child: Image.asset('assets/images/iohd_logo.png', height: 40, filterQuality: FilterQuality.medium),
                    ),
                    const Spacer(),
                    _Tap(
                      label: 'Close',
                      tooltip: 'Close',
                      onTap: () => Scaffold.of(context).closeDrawer(),
                      builder: (hover, focus) => _squareIcon(Icons.close_rounded, hover: hover, focus: focus),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: DashUi.line),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(8),
                  children: [for (final m in widget.modules) ..._module(m)],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Opens the read-only AI assistant panel. The bar's one branded action, so it keeps the red tint.
class _AskButton extends StatelessWidget {
  final bool showLabel;
  final VoidCallback onTap;
  const _AskButton({required this.showLabel, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final motion = _motion(context, 120);
    // No hover tooltip, but screen readers still name the icon-only button.
    return _Tap(
      label: 'Ask Jarvis',
      onTap: onTap,
      builder: (hover, focus) {
        final radius = BorderRadius.circular(10);
        return AnimatedContainer(
          duration: motion,
          height: _M.control,
          padding: EdgeInsets.symmetric(horizontal: showLabel ? _M.askPad : 11),
          decoration: BoxDecoration(color: _brandRed.withValues(alpha: hover ? 0.12 : 0.07), borderRadius: radius),
          foregroundDecoration: _ring(focus, radius: radius),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.auto_awesome_rounded, size: 16, color: _brandRed),
              if (showLabel) ...[
                const SizedBox(width: 7),
                Text('Ask Jarvis', style: _M.askText.copyWith(color: _brandRed)),
              ],
            ],
          ),
        );
      },
    );
  }
}

const double _accountMenuWidth = 244;

/// The signed-in user, with a sign-out action. Signing out sends the router back to /login.
class _AccountMenu extends StatefulWidget {
  const _AccountMenu();

  @override
  State<_AccountMenu> createState() => _AccountMenuState();
}

class _AccountMenuState extends State<_AccountMenu> with _MenuKeys {
  // While open, so a module menu opening (or Escape) can close it: one bar menu at a time.
  static _AccountMenuState? _shown;

  String _photoName = ''; // whose photo _photoUrl is (or is being fetched for)
  String? _photoUrl; // null: no photo, show initials
  bool _open = false;

  @override
  void dispose() {
    if (_shown == this) _shown = null;
    disposeMenuKeys();
    super.dispose();
  }

  /// The sign-in answer carries no photo, so look the person up in the users list the KPI page uses (by name). Anyone
  /// not in that list (the owner login) or without a photo keeps the initials circle.
  Future<void> _loadPhoto(String name) async {
    _photoName = name;
    _photoUrl = null;
    if (name.isEmpty) return;
    try {
      final res = await http
          .get(Uri.parse('$kApiBaseUrl/users'), headers: AuthSession.instance.headers())
          .timeout(const Duration(seconds: 20));
      if (!mounted || _photoName != name || res.statusCode != 200) return;
      final body = json.decode(res.body);
      final list = body is List ? body : (body is Map && body['users'] is List ? body['users'] as List : const []);
      for (final u in list) {
        if (u is! Map || (u['name'] ?? '').toString().trim().toLowerCase() != name.trim().toLowerCase()) continue;
        final url = (u['avatarUrl'] ?? u['avatar_url'] ?? '').toString().trim();
        // The users list invents an initials image for people with no photo; that is not a photo.
        if (url.isNotEmpty && !url.contains('ui-avatars.com')) setState(() => _photoUrl = url);
        return;
      }
    } catch (_) {
      // No photo is fine: the initials circle stays.
    }
  }

  /// The photo in a circle of [size], or [initials] when there is none (or it fails to load).
  Widget _avatar(double size, String initials, {required Color bg, required Color fg, required double fontSize, Border? border}) {
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle, border: border),
      child: Text(initials, style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w800, color: fg)),
    );
    final url = _photoUrl;
    if (url == null) return fallback;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, border: border),
      child: ClipOval(
        child: Image.network(
          url,
          width: size,
          height: size,
          fit: BoxFit.cover,
          alignment: const Alignment(0, -0.4), // keeps the face in frame
          errorBuilder: (context, error, stackTrace) => fallback,
          loadingBuilder: (context, child, progress) => progress == null ? child : fallback,
        ),
      ),
    );
  }

  void _click() {
    if (menu.isOpen) {
      menu.close();
    } else {
      _NavMenuState.dismissShown();
      menu.open();
    }
  }

  void _keyOpen() {
    _NavMenuState.dismissShown();
    if (!menu.isOpen) menu.open();
    focusEntrySoon();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AuthSession.instance,
      builder: (context, _) {
        final session = AuthSession.instance;
        if (session.name != _photoName) {
          // A different person signed in (or the first build): fetch their photo after this frame.
          final name = session.name;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && name == AuthSession.instance.name && name != _photoName) _loadPhoto(name);
          });
        }
        final parts = session.name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
        final initials = parts.isEmpty
            ? '?'
            : (parts.length == 1 ? parts.first[0] : parts.first[0] + parts.last[0]).toUpperCase();

        return MenuAnchor(
          controller: menu,
          // Right edges line up with the avatar's, and the top sits just under the bar like the module menus.
          alignmentOffset: const Offset(-_accountMenuWidth, 13),
          style: _menuStyleFor(context, width: _accountMenuWidth).copyWith(alignment: AlignmentDirectional.bottomEnd),
          onOpen: () {
            _shown = this;
            setState(() => _open = true);
          },
          onClose: () {
            if (_shown == this) _shown = null;
            returnFocusIfInside();
            if (mounted) setState(() => _open = false);
          },
          menuChildren: [
            menuPanel([
              Container(
                width: _accountMenuWidth - 12, // inside the panel's padding
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
                child: Row(
                  children: [
                    _avatar(40, initials, bg: _Bar.avatarBg, fg: _Bar.avatarText, fontSize: 15),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(session.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: DashUi.ink)),
                          if (session.role.isNotEmpty)
                            Text(session.role,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12, color: DashUi.slate)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              _menuDivider(),
              MenuItemButton(
                focusNode: entryFocus,
                requestFocusOnHover: false,
                onPressed: () => context.go('/profile'),
                style: _menuRowStyle(here: GoRouterState.of(context).uri.path == '/profile'),
                leadingIcon: const Icon(Icons.person_outline_rounded, size: 18, color: DashUi.slate),
                child: const Text('My Profile',
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: DashUi.ink)),
              ),
              MenuItemButton(
                requestFocusOnHover: false,
                onPressed: session.logout,
                style: _menuRowStyle(here: false),
                leadingIcon: const Icon(Icons.logout_rounded, size: 18, color: DashUi.redText),
                child: const Text('Sign out',
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: DashUi.redText)),
              ),
            ]),
          ],
          child: _Tap(
            label: 'Account',
            tooltip: session.name.isEmpty ? 'Account' : session.name,
            expanded: _open,
            focusNode: buttonFocus,
            onTap: _click,
            onActivate: _keyOpen,
            onArrowDown: _keyOpen,
            builder: (hover, focus) => Container(
              padding: const EdgeInsets.all(2),
              foregroundDecoration: _ring(focus, shape: BoxShape.circle),
              child: _avatar(
                _M.control - 4,
                initials,
                bg: _Bar.avatarBg,
                fg: _Bar.avatarText,
                fontSize: 13.5,
                border: Border.all(color: hover || _open ? DashUi.muted : (_darkBar ? _Bar.divider : DashUi.line)),
              ),
            ),
          ),
        );
      },
    );
  }
}
