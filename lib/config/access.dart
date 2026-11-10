import 'package:flutter/material.dart';

/// What a person can do with one resource. Stored as `<resource>.<action>` keys in the backend's
/// `users.access_denied` (the keys they are switched OFF from). Must match ACCESS_RESOURCES in the
/// backend's admin_users.js (its test reads this file, so keep one `AccessResource(...)` per entry).
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
const Set<AccessAction> _record = {AccessAction.view, AccessAction.update, AccessAction.delete};
const Set<AccessAction> _payments = {AccessAction.view, AccessAction.create};
const Set<AccessAction> _payroll = {AccessAction.view, AccessAction.create, AccessAction.delete};
const Set<AccessAction> _viewUpdate = {AccessAction.view, AccessAction.update};
const Set<AccessAction> _team = {AccessAction.view, AccessAction.create, AccessAction.update};

/// Sent with every permissions save: this app knows every key, so the server takes the list as it is. (An older build
/// leaves it out, and the server keeps the saved value of the keys that build doesn't know.)
const int kAccessVersion = 2;

/// One row of the permissions grid: a page (or a part of pages) and the actions it really has. The server checks every
/// one of them, and an action only counts while View is on. Admin and Owner roles can do everything; for everyone else
/// the Team screen decides, nothing is held back. [help] says in plain words what each ticked box lets the person do;
/// the Team screen shows it under the row's name. [defaultOff] rows (pay, profit, Team, Jarvis) start switched off for
/// someone whose permissions were never saved; everything else starts on. Same list as accessKeys.js in the backend.
class AccessResource {
  final String key;
  final String label;
  final IconData icon;
  final String? route; // the page that "view" opens (null: a part of other pages, like calls and texts)
  final Set<AccessAction> actions;
  final String help;
  final bool defaultOff;
  const AccessResource(this.key, this.label, this.icon, {this.route, this.actions = _viewOnly, this.help = '', this.defaultOff = false});

  String keyFor(AccessAction a) => '$key.${a.name}';
}

class AccessGroup {
  final String title;
  final List<AccessResource> items;
  const AccessGroup(this.title, this.items);
}

const List<AccessGroup> kAccessGroups = [
  AccessGroup('Dashboards', [
    AccessResource('dash_financial', 'Financial', Icons.attach_money_rounded, route: '/dashboards/financial', defaultOff: true, help: 'Company revenue and profit.'),
    AccessResource('dash_commissions', 'Commissions', Icons.payments_outlined, route: '/dashboards/commissions', defaultOff: true, help: "Everyone's commission pay."),
    AccessResource('dash_technicians', 'Technicians', Icons.engineering_outlined, route: '/dashboards/technicians', defaultOff: true, help: 'Revenue and profit per technician.'),
    AccessResource('dash_inventory', 'Inventory', Icons.inventory_2_outlined, route: '/dashboards/inventory', help: 'Stock value, low stock and strikes.'),
    AccessResource('dash_jobs', 'Jobs', Icons.work_outline_rounded, route: '/dashboards/jobs', defaultOff: true, help: 'Job revenue and profit margin.'),
    AccessResource('dash_estimates', 'Estimates', Icons.request_quote_outlined, route: '/dashboards/estimates', help: 'Win rate, open and lost estimates.'),
    AccessResource('dash_sales', 'Sales', Icons.trending_up_rounded, route: '/dashboards/sales', help: 'Sales by person and door style.'),
    AccessResource('dash_collections', 'Collections', Icons.account_balance_wallet_outlined, route: '/dashboards/collections', help: 'Cash collected and what is still owed.'),
  ]),
  AccessGroup('HR', [
    AccessResource('hr_payroll', 'Payroll', Icons.payments_rounded, route: '/hr/payroll', actions: _payroll, defaultOff: true, help: 'View: weekly pay and past runs. Create: run payroll, lock commissions, release retainage. Delete: void a run.'),
    AccessResource('hr_kpis', "KPI's", Icons.speed_outlined, route: '/hr/kpis', defaultOff: true, help: "Everyone's KPI scorecards."),
    AccessResource('hr_corrections', 'Commission Corrections', Icons.rule_folder_outlined, route: '/hr/corrections', actions: _viewUpdate, defaultOff: true, help: 'View: work days and callbacks behind commission. Update: save a correction, unlock a job.'),
    AccessResource('team', 'Team', Icons.manage_accounts_rounded, route: '/hr/team', actions: _team, defaultOff: true, help: 'View: people and pay. Create: add a person. Update: edit people, PINs and permissions (not admins or themselves).'),
  ]),
  AccessGroup('My Office', [
    AccessResource('customers', 'Customers', Icons.groups_rounded, route: '/customers', help: 'Customer list and contact details.'),
    AccessResource('estimates', 'Estimates', Icons.request_quote_rounded, route: '/estimates', actions: _record, help: 'Update: notes, tasks, pictures and documents. Delete: remove one deleted in Service Fusion.'),
    AccessResource('jobs', 'Jobs', Icons.build_rounded, route: '/jobs', actions: _record, help: 'Update: notes, tasks, pictures and documents. Delete: remove one deleted in Service Fusion.'),
    AccessResource('line_items', 'Line Items & Costs', Icons.list_alt_rounded, actions: _viewUpdate, defaultOff: true, help: 'View: costs, profit and margin on jobs, estimates and the catalog. Update: edit line items and options, accept, send to job.'),
    AccessResource('communications', 'Calls & Texts', Icons.forum_rounded, actions: _crud, help: 'On job and customer pages. Create: send a text. Update: link a call, add call details. Delete: remove a call or text.'),
    AccessResource('statuses', 'Statuses', Icons.timeline_rounded, route: '/statuses', actions: _crud, help: 'Add, rename, recolor, reorder and remove job statuses.'),
    AccessResource('payments', 'Payments', Icons.payment_rounded, route: '/payments', actions: _payments, help: 'Payments from Service Fusion and Stripe. Create: send a card payment link.'),
    AccessResource('invoices', 'Invoices', Icons.receipt_long_rounded, route: '/invoices', help: 'Invoices synced from Service Fusion.'),
    AccessResource('documents', 'Documents', Icons.folder_shared_rounded, route: '/documents', help: 'Shared Google Drive documents.'),
    AccessResource('site_checks', 'Site Checks', Icons.assignment_turned_in_rounded, route: '/site-checks', help: 'Site check reports from the tech app.'),
    AccessResource('takeoffs', 'Takeoffs', Icons.architecture_rounded, route: '/takeoffs', help: 'Commercial takeoffs.'),
  ]),
  AccessGroup('Inventory', [
    AccessResource('stock', 'Stock Levels', Icons.stacked_bar_chart_rounded, route: '/inventory', help: 'What is on the shelves.'),
    AccessResource('catalog', 'Product Catalog', Icons.category_rounded, route: '/inventory/catalog', help: 'Products and prices.'),
    AccessResource('purchase_orders', 'Purchase Orders', Icons.shopping_cart_checkout_rounded, route: '/inventory/purchase-orders', actions: _crud, help: 'Add, change and remove purchase orders.'),
    AccessResource('vendors', 'Vendors', Icons.storefront_rounded, route: '/inventory/vendors', help: 'Vendor list.'),
  ]),
  AccessGroup('Other', [
    AccessResource('projects', 'Projects', Icons.folder_copy_rounded, route: '/projects', actions: _crud, help: 'Add (or import from the sheet), change and remove projects.'),
    AccessResource('calendar', 'Calendar', Icons.calendar_month_rounded, route: '/calendar', help: 'The schedule from Service Fusion.'),
    AccessResource('jarvis', 'Ask Jarvis', Icons.auto_awesome_rounded, defaultOff: true, help: 'The assistant. It can read every report, profit and pay included.'),
  ]),
];

/// Every `<resource>.<action>` key, in display order.
final List<String> kAllAccessKeys = [
  for (final g in kAccessGroups)
    for (final r in g.items)
      for (final a in AccessAction.values)
        if (r.actions.contains(a)) r.keyFor(a),
];

/// The keys someone whose permissions were never saved is switched off from (the [AccessResource.defaultOff] rows).
final List<String> kDefaultOffKeys = [
  for (final g in kAccessGroups)
    for (final r in g.items)
      if (r.defaultOff)
        for (final a in AccessAction.values)
          if (r.actions.contains(a)) r.keyFor(a),
];

/// The keys a person is switched off from: their saved list, or the defaults when nothing was saved (null).
Set<String> effectiveDenied(Object? saved) =>
    saved is List ? saved.map((e) => e.toString()).toSet() : kDefaultOffKeys.toSet();

/// Every resource, by key.
final Map<String, AccessResource> kAccessResources = {
  for (final g in kAccessGroups)
    for (final r in g.items) r.key: r,
};

/// Resource keys of one group (for "does this menu have anything left to show").
List<String> accessKeys(String group) => [for (final r in kAccessGroups.firstWhere((g) => g.title == group).items) r.key];

/// Pages in menu order, used to find where to send someone who opens a page they're switched off from.
final List<AccessResource> kAccessPages = [
  for (final g in kAccessGroups)
    for (final r in g.items)
      if (r.route != null) r,
];

/// The page a location belongs to: the longest page route it starts with, so `/jobs/123` needs the Jobs page and
/// `/inventory/catalog` the catalog (not Stock Levels). Null for places outside the grid (profile, team, login).
AccessResource? accessPageFor(String location) {
  AccessResource? best;
  for (final p in kAccessPages) {
    final r = p.route!;
    if ((location == r || location.startsWith('$r/')) && (best == null || r.length > best.route!.length)) best = p;
  }
  return best;
}

/// The icon the menus show for resource [key] (a dashboard's title bar shows the same one).
IconData accessIcon(String key) => kAccessPages.firstWhere((r) => r.key == key).icon;
