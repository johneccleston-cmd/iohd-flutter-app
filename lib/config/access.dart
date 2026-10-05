import 'package:flutter/material.dart';

/// What a person can do with one resource. Stored as `<resource>.<action>` keys in the backend's
/// `users.access_denied` (the keys they are switched OFF from). Must match ACCESS_RESOURCES in the
/// backend's admin_users.js.
enum AccessAction {
  view('View'),
  create('Create'),
  update('Update'),
  delete('Delete');

  final String label;
  const AccessAction(this.label);
}

const Set<AccessAction> _viewOnly = {AccessAction.view};
const Set<AccessAction> _crud = {AccessAction.view, AccessAction.create, AccessAction.update, AccessAction.delete};

/// One row of the permissions matrix: a page or record type, and which actions apply to it.
class AccessResource {
  final String key;
  final String label;
  final IconData icon;
  final String? route; // the page that "view" opens
  final Set<AccessAction> actions;
  const AccessResource(this.key, this.label, this.icon, {this.route, this.actions = _viewOnly});

  String keyFor(AccessAction a) => '$key.${a.name}';
}

class AccessGroup {
  final String title;
  final List<AccessResource> items;
  const AccessGroup(this.title, this.items);
}

const List<AccessGroup> kAccessGroups = [
  AccessGroup('Dashboards', [
    AccessResource('dash_financial', 'Financial', Icons.attach_money_rounded, route: '/dashboards/financial'),
    AccessResource('dash_commissions', 'Commissions', Icons.payments_outlined, route: '/dashboards/commissions'),
    AccessResource('dash_technicians', 'Technicians', Icons.engineering_outlined, route: '/dashboards/technicians'),
    AccessResource('dash_inventory', 'Inventory', Icons.inventory_2_outlined, route: '/dashboards/inventory'),
    AccessResource('dash_jobs', 'Jobs', Icons.work_outline_rounded, route: '/dashboards/jobs'),
    AccessResource('dash_estimates', 'Estimates', Icons.request_quote_outlined, route: '/dashboards/estimates'),
    AccessResource('dash_sales', 'Sales', Icons.trending_up_rounded, route: '/dashboards/sales'),
    AccessResource('dash_collections', 'Collections', Icons.account_balance_wallet_outlined, route: '/dashboards/collections'),
  ]),
  AccessGroup('HR', [
    AccessResource('hr_payroll', 'Payroll', Icons.payments_rounded, route: '/hr'),
    AccessResource('hr_kpis', "KPI's", Icons.speed_outlined, route: '/hr/kpis'),
    AccessResource('hr_corrections', 'Commission Corrections', Icons.rule_folder_outlined, route: '/hr/corrections'),
  ]),
  AccessGroup('My Office', [
    AccessResource('customers', 'Customers', Icons.groups_rounded, route: '/customers', actions: _crud),
    AccessResource('estimates', 'Estimates', Icons.request_quote_rounded, route: '/estimates', actions: _crud),
    AccessResource('jobs', 'Jobs', Icons.build_rounded, route: '/jobs', actions: _crud),
    AccessResource('statuses', 'Statuses', Icons.timeline_rounded, route: '/statuses'),
    AccessResource('payments', 'Payments', Icons.payment_rounded, route: '/payments', actions: _crud),
    AccessResource('invoices', 'Invoices', Icons.receipt_long_rounded, route: '/invoices', actions: _crud),
    AccessResource('site_checks', 'Site Checks', Icons.assignment_turned_in_rounded, route: '/site-checks', actions: _crud),
    AccessResource('takeoffs', 'Takeoffs', Icons.architecture_rounded, route: '/takeoffs', actions: _crud),
  ]),
  AccessGroup('Inventory', [
    AccessResource('stock', 'Stock Levels', Icons.stacked_bar_chart_rounded, route: '/inventory'),
    AccessResource('catalog', 'Product Catalog', Icons.category_rounded, route: '/inventory/catalog', actions: _crud),
    AccessResource('purchase_orders', 'Purchase Orders', Icons.shopping_cart_checkout_rounded,
        route: '/inventory/purchase-orders', actions: _crud),
    AccessResource('vendors', 'Vendors', Icons.storefront_rounded, route: '/inventory/vendors', actions: _crud),
  ]),
  AccessGroup('Other', [
    AccessResource('projects', 'Projects', Icons.folder_copy_rounded, route: '/projects', actions: _crud),
    AccessResource('calendar', 'Calendar', Icons.calendar_month_rounded, route: '/calendar', actions: _crud),
  ]),
];

/// Every `<resource>.<action>` key, in display order.
final List<String> kAllAccessKeys = [
  for (final g in kAccessGroups)
    for (final r in g.items)
      for (final a in AccessAction.values)
        if (r.actions.contains(a)) r.keyFor(a),
];

/// Resource keys of one group (for "does this menu have anything left to show").
List<String> accessKeys(String group) => [for (final r in kAccessGroups.firstWhere((g) => g.title == group).items) r.key];

/// Pages in menu order, used to find where to send someone who opens a page they're switched off from.
final List<AccessResource> kAccessPages = [
  for (final g in kAccessGroups)
    for (final r in g.items)
      if (r.route != null) r,
];
