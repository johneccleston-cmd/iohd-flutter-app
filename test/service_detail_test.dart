// A service's own page: a row of the Services Catalog opens it; Service information (name, category, status, tax, description)
// and RATES (name, description, qty, regular rate and total, internal cost and total cost, and each rate's own
// commission: USER RULE 2026-11-19 late, reversing the service-level one), with
// a + button for a new rate. Save sends only what changed: the info as fields (a value put back to what the job lines
// say is sent as null) and the rates as a whole set. Pictures go to build/job_shots/service_detail_*.png for review.
//   flutter test test/service_detail_test.dart

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/config/auth_session.dart';
import 'package:iohd_desktop/service_detail_screen.dart';
import 'package:iohd_desktop/services/line_items_api.dart';
import 'package:iohd_desktop/services_catalog_screen.dart';
import 'package:iohd_desktop/widgets/leave_guard.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'dashboard_harness.dart';

const _plain = CatalogEntry(
  key: 'sf:service call',
  name: 'Scope of Work | Residential Overhead Door Service',
  kind: 'service',
  category: 'Residential Service',
  rate: 75,
  rateMin: 69,
  rateMax: 129,
  cost: 15,
  uses: 412,
  lastUsed: '2026-11-12',
  taxable: false,
  description: 'Repair or replacement of any mechanical or electrical component for a 3rd party warranty company.',
);

const _withRates = CatalogEntry(
  key: 'sf:service call',
  name: 'Scope of Work | Residential Overhead Door Service',
  kind: 'service',
  category: 'Service Packages',
  group: 'Service Packages',
  rate: 75,
  rateMin: 69,
  rateMax: 129,
  cost: 15,
  uses: 412,
  lastUsed: '2026-11-12',
  taxable: true,
  description: 'Repair or replacement of any mechanical or electrical component for a 3rd party warranty company.',
  editedFields: ['category', 'taxable', 'rates'],
  editedBy: 'Test Admin',
  editedAt: '2026-11-19T15:00:00Z',
  computed: {
    'name': 'Scope of Work | Residential Overhead Door Service',
    'category': 'Residential Service',
    'description': '',
    'rate': 75,
    'cost': 15,
    'taxable': false,
    'active': true,
  },
  rates: [
    ServiceRate(
      name: 'Residential Overhead Door Service',
      description: 'Weekday visit',
      qty: 1,
      rate: 75,
      cost: 15,
      paysCommission: true,
      commissionType: 'percent',
      commissionValue: 20,
    ),
    ServiceRate(name: 'After hours', qty: 2, rate: 120, cost: 30, paysCommission: true, commissionType: 'fixed', commissionValue: 10),
  ],
);

final _pageKey = GlobalKey();

Future<void> _open(
  WidgetTester t,
  CatalogEntry service, {
  Future<CatalogEntry> Function(String, Map<String, dynamic>)? save,
  Future<CatalogEntry> Function(String, List<ServiceRate>)? saveRates,
  bool canSeeCost = true,
  Size size = const Size(1366, 900),
  List<CatalogEntry> Function()? entries,
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
      home: RepaintBoundary(
        key: _pageKey,
        child: ServiceDetailScreen(
          key: UniqueKey(),
          serviceKey: service.key,
          loader: () async => (entries: entries?.call() ?? [service], canSeeCost: canSeeCost, historyDays: 540),
          saver: save,
          ratesSaver: saveRates,
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

Future<void> _edit(WidgetTester t) async {
  await t.tap(find.text('Edit'));
  await t.pumpAndSettle();
}

Finder _field(String key) => find.byKey(ValueKey('field:$key'));

Future<void> _save(WidgetTester t) async {
  await t.tap(find.text('Save'));
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await loadDashFonts();
    await dashSignIn();
  });

  _noRateTooltipsTests();

  testWidgets('reads: the service info table, the rates with totals and commission, the use on jobs', (t) async {
    for (final size in const [Size(1366, 900), Size(1920, 1000), Size(420, 900)]) {
      await _open(t, _withRates, size: size);
      await _shot(t, 'service_detail_${size.width.toInt()}');
      expect(t.takeException(), isNull, reason: '$size');
      // The product page's layout (redesign 2026-11-20): description on the left, price and tax in the rail, status and
      // category under the name in the header.
      expect(find.text('DESCRIPTION'), findsOneWidget);
      expect(find.text('PRICE'), findsOneWidget);
      expect(find.text('SALES TAX'), findsOneWidget);
      expect(find.text('Service name'), findsNothing, reason: 'the name is the title once, not repeated in a field');
      expect(find.text('Active'), findsOneWidget, reason: 'status once, in the header');
      expect(find.text('Service Packages'), findsWidgets);
      expect(find.textContaining('Service Fusion', findRichText: true), findsNothing);
      expect(find.text('Edited'), findsNothing, reason: 'no Edited pill');
      expect(find.text('RATES'), findsOneWidget);
      expect(find.text('After hours'), findsOneWidget);
      expect(find.text('\$240.00'), findsOneWidget, reason: 'total = 2 x 120');
      expect(find.text('\$60.00'), findsOneWidget, reason: 'total cost = 2 x 30');
      // Each rate's own commission, what kind, and what it pays on its line (PAYS, worked out like TOTAL).
      expect(find.text('20%'), findsOneWidget);
      expect(find.text(r'$15.00'), findsWidgets, reason: r'20% of $75.00');
      expect(find.text(r'$10.00 each'), findsOneWidget);
      expect(find.text(r'$20.00'), findsWidgets, reason: r'2 x $10.00');
      expect(find.text('20% of the price'), findsNothing, reason: 'no service-level commission any more');
      expect(find.text('ON JOBS AND ESTIMATES'), findsNothing);
      expect(find.text('Add rate'), findsNothing, reason: 'rates are added in edit mode only');
    }
  });

  testWidgets('no rates yet says so, with its usual price', (t) async {
    await _open(t, _plain);
    expect(find.textContaining('No rates yet   Usually billed at \$75.00. Add one with Edit.', findRichText: true), findsOneWidget);
    expect(find.text('Add rate'), findsNothing, reason: 'not until Edit');
    await t.tap(find.text('Edit'));
    await t.pumpAndSettle();
    expect(find.text('Add rate'), findsOneWidget);
    expect(find.textContaining('The first rate starts at its usual price, \$75.00.', findRichText: true), findsOneWidget);
  });

  testWidgets('+ Add rate: the first starts from the service; filled in and saved as a set', (t) async {
    List<ServiceRate>? sent;
    await _open(
      t,
      _plain,
      saveRates: (key, rates) async {
        sent = rates;
        return _withRates;
      },
    );
    await t.tap(find.text('Edit'));
    await t.pumpAndSettle();
    await t.tap(find.text('Add rate'));
    await t.pumpAndSettle();
    expect(_field('rate0.name'), findsOneWidget);
    expect(t.widget<TextField>(_field('rate0.name')).controller!.text, _plain.name);
    expect(t.widget<TextField>(_field('rate0.rate')).controller!.text, '75.00');
    // A second rate, blank: named, qty 2 at $120, cost $30.
    await t.ensureVisible(find.text('Add rate'));
    await t.tap(find.text('Add rate'));
    await t.pumpAndSettle();
    await t.enterText(_field('rate1.name'), 'After hours');
    await t.enterText(_field('rate1.qty'), '2');
    await t.enterText(_field('rate1.rate'), '120');
    await t.enterText(_field('rate1.cost'), '30');
    await t.pump();
    expect(find.text('\$240.00'), findsOneWidget, reason: 'the total follows what is typed');
    expect(find.text('\$60.00'), findsOneWidget);
    // Its own commission (USER RULE 2026-11-20: the % / $ toggle and the amount): an empty box is none.
    expect(_field('rate1.commissionType'), findsOneWidget);
    expect(t.widget<TextField>(_field('rate1.commission')).controller!.text, '', reason: 'a new rate pays none');
    expect(_pays(t, 1), '—', reason: 'pays nothing');
    await t.tap(find.byKey(const ValueKey('field:rate1.commissionType:percent')));
    await t.pump();
    await t.enterText(_field('rate1.commission'), '10');
    await t.pump();
    expect(_pays(t, 1), r'$24.00', reason: r'10% of $240.00');
    expect(find.bySemanticsLabel(RegExp(r'Rate 2 commission pays \$24\.00, 10% of \$240\.00')), findsOneWidget);
    await _shot(t, 'service_detail_editing');
    await _save(t);
    expect(sent!.map((r) => [r.name, r.qty, r.rate, r.cost, r.paysCommission, r.commissionType, r.commissionValue]).toList(), [
      [_plain.name, 1.0, 75.0, 15.0, false, null, null],
      ['After hours', 2.0, 120.0, 30.0, true, 'percent', 10.0],
    ]);
    expect(find.text('Save'), findsNothing, reason: 'back to reading');
  });

  // USER RULE 2026-11-20: a package's rates are separate lines, none of them "main"; on a job each starts at its own
  // quantity (the dispatch line 1, the others 0, raised when the job needs them).
  testWidgets('a package has no main rate: added rates start at 0, and its price is what its lines start at', (t) async {
    await _open(t, _withRates);
    expect(find.text('Main'), findsNothing);
    expect(find.text('Starts at'), findsOneWidget);
    expect(find.text(r'$315.00'), findsOneWidget, reason: r'1 x $75 + 2 x $120 at their starting quantities');
    expect(find.textContaining('first one', findRichText: true), findsNothing, reason: 'no rate sets the price');
    await _edit(t);
    await t.ensureVisible(find.text('Add rate'));
    await t.tap(find.text('Add rate'));
    await t.pumpAndSettle();
    expect(t.widget<TextField>(_field('rate2.qty')).controller!.text, '0', reason: 'a later line starts at 0');
    expect(find.text('Main'), findsNothing);
  });

  testWidgets('removing a rate and saving sends the rest; unchanged info is not sent', (t) async {
    List<ServiceRate>? sent;
    var infoSent = false;
    await _open(
      t,
      _withRates,
      save: (_, _) async {
        infoSent = true;
        return _withRates;
      },
      saveRates: (key, rates) async {
        sent = rates;
        return _withRates;
      },
    );
    await _edit(t);
    // The row's menu (the Products & Services table's ⋮), then Remove rate.
    await t.ensureVisible(find.byKey(const ValueKey('rate-menu:1')));
    await t.tap(find.byKey(const ValueKey('rate-menu:1')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('remove-rate:1')));
    await t.pumpAndSettle();
    await _save(t);
    expect(sent!.map((r) => r.name), ['Residential Overhead Door Service']);
    expect(infoSent, isFalse);
  });

  testWidgets('service info: category from the list, status and tax; only changes are sent', (t) async {
    Map<String, dynamic>? sent;
    var ratesSent = false;
    await _open(
      t,
      _plain,
      save: (key, fields) async {
        sent = fields;
        return _plain;
      },
      saveRates: (_, _) async {
        ratesSent = true;
        return _plain;
      },
    );
    await _edit(t);
    await t.tap(_field('category'));
    await t.pumpAndSettle();
    for (final c in kServiceCategories) {
      expect(find.text(c), findsWidgets, reason: c);
    }
    // The way out of a category is No category (the synced group's name is not shown).
    expect(find.text('No category'), findsWidgets);
    expect(find.text('Residential Service'), findsNothing);
    expect(find.text('None'), findsNothing);
    await t.tap(find.text('Operator Services').last);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('switch:active')));
    await t.tap(find.byKey(const ValueKey('switch:taxable')));
    await t.pump();
    expect(find.text('Unsaved changes'), findsOneWidget);
    await _save(t);
    expect(sent, {'category': 'Operator Services', 'active': false, 'taxable': true});
    expect(ratesSent, isFalse);
  });

  testWidgets('putting a field back to what the job lines say drops the edit (null)', (t) async {
    Map<String, dynamic>? sent;
    await _open(
      t,
      _withRates,
      save: (key, fields) async {
        sent = fields;
        return _plain;
      },
    );
    await _edit(t);
    await t.tap(find.byKey(const ValueKey('switch:taxable')));
    await t.pump();
    await _save(t);
    expect(sent, {'taxable': null});
  });

  testWidgets('bad input is explained and nothing is sent', (t) async {
    var called = false;
    await _open(
      t,
      _withRates,
      saveRates: (_, _) async {
        called = true;
        return _withRates;
      },
    );
    await _edit(t);
    await t.enterText(_field('name'), '   ');
    await t.enterText(_field('rate1.name'), '');
    await t.enterText(_field('rate1.rate'), '1.2.3');
    await t.enterText(_field('rate0.commission'), '150');
    await t.pump();
    await _save(t);
    expect(find.text('The name cannot be empty.'), findsOneWidget);
    expect(find.text('Give the rate a name.'), findsOneWidget);
    expect(find.text('Regular rate: Enter an amount.'), findsOneWidget);
    expect(find.text('Commission: A percentage is 100 at most.'), findsOneWidget);
    expect(_pays(t, 0), 'Over 100%', reason: 'said where the pay would be, too');
    expect(called, isFalse);
  });

  testWidgets('an emptied quantity is refused, not saved as 1 (only the dispatch line starts at 1)', (t) async {
    List<ServiceRate>? sent;
    await _open(
      t,
      _withRates,
      saveRates: (_, r) async {
        sent = r;
        return _withRates;
      },
    );
    await _edit(t);
    await t.enterText(_field('rate1.qty'), '');
    await t.pump();
    await _save(t);
    expect(find.textContaining('Enter a quantity (0 if a job adds it when needed).'), findsOneWidget);
    expect(sent, isNull, reason: 'nothing is saved');
    await t.enterText(_field('rate1.qty'), '0');
    await t.pump();
    await _save(t);
    expect(sent?[1].qty, 0, reason: 'typed 0 is kept as 0');
  });

  testWidgets('a server error stays on the page, still editing', (t) async {
    await _open(t, _withRates, saveRates: (_, _) async => throw const LineItemsException('Could not reach the server.'));
    await _edit(t);
    await t.enterText(_field('rate0.rate'), '80');
    await t.pump();
    await _save(t);
    expect(find.text('Could not reach the server.'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
  });

  testWidgets('no Restore action and no Service Fusion wording, read or edited (USER RULE 2026-11-19)', (t) async {
    for (final s in [_plain, _withRates]) {
      await _open(t, s);
      expect(find.text('More'), findsNothing, reason: 'the More menu only held Restore');
      expect(find.textContaining('Restore'), findsNothing);
      expect(find.textContaining('Service Fusion', findRichText: true), findsNothing);
      expect(find.textContaining('job lines', findRichText: true), findsNothing);
      await _edit(t);
      expect(find.textContaining('Service Fusion', findRichText: true), findsNothing);
      await t.tap(_field('category'));
      await t.pumpAndSettle();
      expect(find.textContaining('Service Fusion', findRichText: true), findsNothing, reason: 'nor in the category menu');
      await t.tap(find.text('Service Packages').last);
      await t.pumpAndSettle();
      // The name is edited in the header, so it is on the page once.
      expect(_field('name'), findsOneWidget);
    }
  });

  testWidgets('without the cost switch: no costs or commissions', (t) async {
    await _open(t, _withRates, canSeeCost: false);
    expect(find.text('INTERNAL COST'), findsNothing);
    expect(find.text('COMMISSION'), findsNothing);
    expect(find.text('20% of the total'), findsNothing);
    expect(find.text('Commission'), findsNothing);
    expect(find.text('TOTAL'), findsOneWidget);
  });

  testWidgets('a key not in the catalog says so', (t) async {
    t.view.physicalSize = const Size(1366, 768);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        home: ServiceDetailScreen(serviceKey: 'sf:gone', loader: () async => (entries: const [_plain], canSeeCost: true, historyDays: 540)),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('That service is not in the catalog'), findsOneWidget);
  });

  testWidgets('clicking a row on the Services Catalog opens its page', (t) async {
    t.view.physicalSize = const Size(1366, 768);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true),
        home: ServicesCatalogScreen(load: () async => (entries: const [_plain], canSeeCost: true, historyDays: 540)),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.textContaining('Residential Overhead Door Service', findRichText: true).first);
    await t.pumpAndSettle();
    expect(find.text('All services'), findsOneWidget);
    expect(find.text('DESCRIPTION'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  // Audit 2026-11-19: a rename could take another service's name (two identical rows in the add-line picker).
  testWidgets('a rename to a name another service has is refused, whatever its case and spacing', (t) async {
    const other = CatalogEntry(key: 'sf:commercial service', name: 'Commercial Service | Call', kind: 'service');
    var sent = false;
    await _open(
      t,
      _plain,
      entries: () => [_plain, other],
      save: (_, _) async {
        sent = true;
        return _plain;
      },
    );
    await _edit(t);
    await t.enterText(_field('name'), '  commercial service|call ');
    await t.pump();
    await _save(t);
    expect(find.text('Another service is already called "Commercial Service | Call".'), findsOneWidget);
    expect(sent, isFalse);
    // Its own name in another case is not a clash.
    await t.enterText(_field('name'), _plain.name.toUpperCase());
    await t.pump();
    await _save(t);
    expect(sent, isTrue);
  });

  // Audit 2026-11-19: two people editing one service: the second save used to overwrite the first unseen.
  testWidgets('someone else saved meanwhile: nothing is sent until the person picks theirs or mine', (t) async {
    const theirs = CatalogEntry(
      key: 'sf:service call',
      name: 'Scope of Work | Residential Overhead Door Service',
      kind: 'service',
      category: 'Residential Service',
      rate: 75,
      cost: 15,
      description: 'Changed by someone else',
      editedFields: ['description'],
      editedBy: 'Bella',
      editedAt: '2026-11-19T20:05:00Z',
      computed: {
        'name': 'Scope of Work | Residential Overhead Door Service',
        'category': 'Residential Service',
        'description': '',
        'rate': 75,
        'cost': 15,
        'taxable': false,
        'active': true,
      },
    );
    var reads = 0;
    final sent = <Map<String, dynamic>>[];
    await _open(
      t,
      _plain,
      entries: () => [if (reads++ == 0) _plain else theirs],
      save: (key, fields) async {
        sent.add(fields);
        return theirs;
      },
    );
    await _edit(t);
    await t.tap(find.byKey(const ValueKey('switch:active')));
    await t.pump();
    await _save(t);
    expect(find.byKey(const ValueKey('conflict-notice')), findsOneWidget);
    expect(find.textContaining('Someone else saved this service while you were editing (by Bella'), findsOneWidget);
    expect(sent, isEmpty, reason: 'nothing is sent while it is in doubt');
    await _shot(t, 'service_detail_conflict');
    // Mine over theirs: only my change goes, worked out against their version (their description stays).
    await t.tap(find.text('Save mine over it'));
    await t.pumpAndSettle();
    expect(sent, [
      {'active': false},
    ]);
    expect(find.byKey(const ValueKey('conflict-notice')), findsNothing);

    // Or theirs: what was typed is dropped and their version shows.
    reads = 0;
    sent.clear();
    await _open(t, _plain, entries: () => [if (reads++ == 0) _plain else theirs], save: (_, f) async => theirs);
    await _edit(t);
    await t.tap(find.byKey(const ValueKey('switch:active')));
    await t.pump();
    await _save(t);
    await t.tap(find.text('Use their version'));
    await t.pumpAndSettle();
    expect(find.text('Changed by someone else'), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget, reason: 'back to reading');
  });

  testWidgets('a service with only its own rates says it was changed by the office', (t) async {
    const ratesOnly = CatalogEntry(
      key: 'sf:service call',
      name: 'Scope of Work | Residential Overhead Door Service',
      kind: 'service',
      rate: 75,
      editedFields: ['rates'],
      rates: [ServiceRate(name: 'Visit', rate: 75)],
    );
    await _open(t, ratesOnly);
    expect(find.text('Changed by the office'), findsOneWidget);
    expect(find.text('Last changed'), findsNothing);
  });

  // ---- the redesign's audit (2026-11-19 evening) ----

  testWidgets('Esc leaves editing: at once with nothing changed; with changes it asks first', (t) async {
    await _open(t, _withRates);
    await _edit(t);
    expect(find.textContaining('Editing ', findRichText: true), findsOneWidget, reason: 'the header says it is being edited');
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(find.text('Edit'), findsOneWidget, reason: 'back to reading');
    expect(find.textContaining('Editing ', findRichText: true), findsNothing);
    await _edit(t);
    await t.enterText(_field('rate0.rate'), '80');
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(find.text('Discard your changes?'), findsOneWidget);
    await t.tap(find.text('Keep editing'));
    await t.pumpAndSettle();
    // Kept, and written as money once its box was left (the question took the keyboard).
    expect(t.widget<TextField>(_field('rate0.rate')).controller!.text, '80.00', reason: 'what was typed is kept');
  });

  // Bug 2026-11-20: Discard on the leave question kept the draft. The page stays alive behind other tabs (the shell's
  // indexed stack), so every later page change, from a dashboard or anywhere, asked about the same changes again.
  testWidgets('leaving with changes: Discard drops them, so the next page change does not ask again', (t) async {
    await _open(t, _withRates);
    await _edit(t);
    await t.enterText(_field('rate0.rate'), '80');
    await t.pump();

    final first = LeaveGuard.confirm(); // a nav bar tab, from this page
    await t.pumpAndSettle();
    expect(find.text('Discard your changes?'), findsOneWidget);
    await t.tap(find.text('Discard changes'));
    await t.pumpAndSettle();
    expect(await first, isTrue);

    expect(find.text('Edit'), findsOneWidget, reason: 'back to reading when the tab is opened again');
    expect(find.text('Unsaved changes'), findsNothing);

    final second = LeaveGuard.confirm(); // leaving the dashboard later; this page is still alive behind it
    await t.pumpAndSettle();
    expect(find.text('Discard your changes?'), findsNothing, reason: 'the changes were already discarded');
    expect(await second, isTrue);
  });

  testWidgets('an inactive service says it is kept on the jobs and estimates that have it', (t) async {
    const off = CatalogEntry(key: 'sf:service call', name: 'Old Service', kind: 'service', rate: 75, active: false);
    await _open(t, off);
    expect(find.text('Inactive'), findsWidgets);
    expect(find.text('Not offered on new lines. Jobs and estimates that have it keep it.'), findsOneWidget);
    await _edit(t);
    expect(find.text('Not offered on new lines. Jobs and estimates that have it keep it.'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('switch:active')));
    await t.pumpAndSettle(); // the note fades out
    // Active, its own caption shows; the inactive one is still laid out (so the row keeps its height and nothing under it
    // moves), but not shown.
    double shown(String text) => t.widget<AnimatedOpacity>(find.ancestor(of: find.text(text), matching: find.byType(AnimatedOpacity)).first).opacity;
    expect(shown('Not offered on new lines. Jobs and estimates that have it keep it.'), 0, reason: 'active needs no note');
    expect(shown('Offered when adding lines to jobs and estimates.'), 1);
  });

  testWidgets('editing a rate in place sends the set with only that figure changed', (t) async {
    List<ServiceRate>? sent;
    Map<String, dynamic>? info;
    await _open(
      t,
      _withRates,
      save: (key, fields) async {
        info = fields;
        return _withRates;
      },
      saveRates: (key, rates) async {
        sent = rates;
        return _withRates;
      },
    );
    await _edit(t);
    await t.enterText(_field('rate0.rate'), '82.5');
    await t.pump();
    expect(find.text('\$82.50'), findsOneWidget, reason: 'the total follows the edit');
    await _save(t);
    expect(sent!.map((r) => [r.name, r.qty, r.rate, r.cost]).toList(), [
      ['Residential Overhead Door Service', 1.0, 82.5, 15.0],
      ['After hours', 2.0, 120.0, 30.0],
    ]);
    expect(info, isNull, reason: 'nothing else changed');
  });

  testWidgets('commission is on each rate: chosen in words, worked out, saved with the rates; none in Service information', (t) async {
    List<ServiceRate>? rates;
    Map<String, dynamic>? info;
    await _open(
      t,
      _withRates,
      save: (key, fields) async {
        info = fields;
        return _withRates;
      },
      saveRates: (key, r) async {
        rates = r;
        return _withRates;
      },
    );
    expect(find.text('Commission'), findsNothing, reason: 'not a Service information row any more');
    expect(find.text('COMMISSION'), findsOneWidget, reason: 'a column of the rates');
    await _edit(t);
    expect(_field('commission'), findsNothing, reason: 'no service-level box');
    expect(t.widget<TextField>(_field('rate0.commission')).controller!.text, '20', reason: 'a whole percentage reads 20');
    expect(_pays(t, 0), r'$15.00', reason: r'20% of $75.00');
    expect(_pays(t, 1), r'$20.00', reason: r'2 x $10.00');
    // Rate 1: a fixed $5 for each one sold ($ on the toggle); rate 2: none (its box emptied).
    await t.tap(find.byKey(const ValueKey(r'field:rate0.commissionType:fixed')));
    await t.pump();
    await t.enterText(_field('rate0.commission'), '5');
    await t.pump();
    expect(_pays(t, 0), r'$5.00', reason: 'for each one sold');
    await t.enterText(_field('rate1.commission'), '');
    await t.pump();
    expect(_pays(t, 1), '—', reason: 'no commission');
    // Something that is not an amount is not saved: it says what to enter.
    await t.enterText(_field('rate0.commission'), '1.2.3');
    await t.pump();
    expect(_pays(t, 0), 'Not a number', reason: 'said as it is typed');
    await _save(t);
    expect(find.text('Commission: Enter a number, like 5 or 2.50.'), findsOneWidget);
    expect(rates, isNull);
    await t.enterText(_field('rate0.commission'), '5');
    await _save(t);
    expect(rates!.map((r) => [r.paysCommission, r.commissionType, r.commissionValue]).toList(), [
      [true, 'fixed', 5.0],
      [false, null, null],
    ]);
    expect(info, isNull, reason: 'no service-level commission is sent');
  });

  testWidgets('without Services Catalog > Update there is no Edit, only reading', (t) async {
    AuthSession.instance.logout();
    final payload = base64Url.encode(utf8.encode(json.encode({'exp': DateTime(2100).millisecondsSinceEpoch})));
    SharedPreferences.setMockInitialValues({
      'iohd_auth_session': json.encode({
        'token': '$payload.sig',
        'name': 'Office Viewer',
        'role': 'Office',
        'is_admin': false,
        'denied': ['services_catalog.update'], // Team screen > Services Catalog > Update (2026-11-19)
      }),
    });
    await AuthSession.instance.restore();
    addTearDown(dashSignIn);
    await _open(t, _plain);
    expect(find.text('Edit'), findsNothing);
    expect(find.textContaining('Click Edit'), findsNothing, reason: 'no hint about a button they do not have');
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    expect(find.text('DESCRIPTION'), findsOneWidget);
  });
}

/// USER RULE 2026-11-20: no unnecessary helper tooltips on a service's rates table (the qty arrows, the Main tag, the
/// % / $ toggle, the row's ⋮). Each spot is hovered past any tooltip wait and nothing pops up; screen readers still
/// hear each control's name.
/// What a rate's PAYS cell says while editing.
String _pays(WidgetTester t, int i) => t.widget<Text>(find.byKey(ValueKey('commission-pays:$i'))).data!;

void _noRateTooltipsTests() {
  const tips = ['One more', 'One less', 'Percent of the line total', 'Dollars for each one sold', 'More for this rate'];

  Future<void> hover(WidgetTester t, TestGesture mouse, Finder target) async {
    await mouse.moveTo(t.getCenter(target.first));
    await t.pump(const Duration(seconds: 2));
    for (final tip in tips) {
      expect(find.text(tip), findsNothing, reason: 'hovering shows "$tip"');
    }
    expect(find.textContaining('The main rate:'), findsNothing);
    expect(find.ancestor(of: target.first, matching: find.byType(Tooltip)), findsNothing);
    await mouse.moveTo(Offset.zero);
    await t.pump(const Duration(seconds: 2));
  }

  testWidgets('the rates table has no hover helper tooltips, read or edited (USER RULE 2026-11-20)', (t) async {
    await _open(t, _withRates);
    final mouse = await t.createGesture(kind: ui.PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    // No rate is the "main" one (USER RULE 2026-11-20): there is no Main mark to hover.
    expect(find.text('Main'), findsNothing);

    await _edit(t);
    expect(find.text('Main'), findsNothing);
    final semantics = t.ensureSemantics();
    await hover(t, mouse, find.byIcon(Icons.keyboard_arrow_up_rounded));
    await hover(t, mouse, find.byIcon(Icons.keyboard_arrow_down_rounded));
    await hover(t, mouse, find.byKey(const ValueKey('field:rate0.commissionType:percent')));
    await hover(t, mouse, find.byKey(const ValueKey('field:rate0.commissionType:fixed')));
    await hover(t, mouse, find.byKey(const ValueKey('rate-menu:0')));

    // Still named for a screen reader.
    expect(find.bySemanticsLabel('One more'), findsWidgets);
    expect(find.bySemanticsLabel('Rate 1 commission: Percent of the line total'), findsOneWidget);
    expect(find.bySemanticsLabel('More for rate 1'), findsOneWidget);
    semantics.dispose();
  });
}

Future<void> _shot(WidgetTester t, String name) async {
  final boundary = _pageKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await t.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory('build/job_shots')..createSync(recursive: true);
    File('${dir.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}
