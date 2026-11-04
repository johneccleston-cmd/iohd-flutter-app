// What the job and estimate pages do, driven through the real screen against the fake backend in
// job_page_fixture.dart (which keeps the line-item server's rules). Covers adding from the catalog, editing, totals,
// reordering and removing, estimate options (independent, duplicated, accepted, sent to a job once), permissions for
// costs, persistence after a reload, and the balance wording on the Payment tab. The rest of the original page (notes,
// tasks, status menu, pay links, the estimate link) is covered by job_detail_render_test.dart and estimate_page_test.dart.
//   flutter test test/job_page_behavior_test.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/widgets/dashboard_data.dart' show DashClock;

import 'job_page_fixture.dart';

Finder get _search => find.byWidgetPredicate((w) => w is TextField && (w.decoration?.hintText ?? '').startsWith('Add a line'));
Finder _cell(int line, String field) => find.byKey(ValueKey('line-$line-$field'));

Future<void> _pick(WidgetTester t, String query, String name) async {
  await t.enterText(_search, query);
  await settle(t, frames: 4);
  await t.tap(find.text(name).last);
  await settle(t, frames: 4);
}

Future<void> _type(WidgetTester t, Finder f, String text) async {
  await t.enterText(f, text);
  await t.pump(const Duration(milliseconds: 50));
}

/// Pins the page's "today" for date-dependent wording.
void _today(int month, int day) {
  DashClock.debugOverride = () => DateTime(2026, month, day, 10, 30);
  addTearDown(() => DashClock.debugOverride = null);
}

void main() {
  setUpAll(jobPageSetUp);

  group('line items from the catalog', () {
    testWidgets('a new estimate option: add products, change quantity, override a price, see cost and margin, save', (t) async {
      final s = FakeJobServer();
      final errors = await pumpJobPage(t, s, id: kEstimateId, body: () async {
        // No options yet: Service Fusion's items, read-only, and a way to start.
        expect(find.textContaining('Service Fusion\'s items, read-only'), findsOneWidget);
        expect(_search, findsNothing);
        await t.tap(find.text('New option'));
        await settle(t, frames: 3);
        await t.tap(find.text('Blank option'));
        await settle(t);
        expect(find.text('Option 1'), findsWidgets);
        expect(find.text('No lines in Option 1 yet'), findsOneWidget);

        await _pick(t, 'TS-250', 'Torsion Spring | 0.250 x 2" x 32"');
        await _pick(t, 'opener', 'LiftMaster 87504 Smart Opener');
        // Catalog defaults: quantity 1, the catalog's price and cost.
        expect(find.text(r'$89.00'), findsWidgets);
        expect(find.text(r'$19.50'), findsWidgets);
        expect(find.text(r'$689.00'), findsWidgets);
        expect(find.text('Unsaved changes'), findsOneWidget);

        // Quantity 3 and a price override on the spring: the line and the totals follow at once.
        await t.tap(find.text(r'$89.00').first);
        await settle(t, frames: 2);
        await _type(t, _cell(0, 'qty'), '3');
        await _type(t, _cell(0, 'rate'), '95');
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(t, frames: 4);
        expect(find.text(r'$285.00'), findsWidgets, reason: '3 x \$95');
        expect(find.text(r'$58.50'), findsWidgets, reason: 'extended cost 3 x \$19.50');
        // Items 285 + 689 = 974; cost 58.50 + 401.37 = 459.87; profit 514.13; margin 52.8%.
        expect(find.text(r'$974.00'), findsWidgets);
        expect(find.text(r'$459.87'), findsWidgets);
        expect(find.text(r'$514.13'), findsWidgets);
        expect(find.text('52.8%'), findsWidgets);

        await t.enterText(find.byKey(const ValueKey('tax-rate')), '10.5');
        await settle(t, frames: 2);
        // Both lines taxable: 10.5% of 974 = 102.27; total 1076.27.
        expect(find.text(r'$102.27'), findsWidgets);
        expect(find.text(r'$1,076.27'), findsWidgets);

        await t.tap(find.text('Save'));
        await settle(t);
        expect(find.text('Unsaved changes'), findsNothing);
      });
      expect(errors.messages, isEmpty);
      final put = s.saves.last;
      expect(put['taxRate'], 10.5);
      final items = (put['items'] as List).cast<Map>();
      expect(items, hasLength(2));
      expect(items[0]['name'], 'Torsion Spring | 0.250 x 2" x 32"');
      expect(items[0]['quantity'], 3);
      expect(items[0]['rate'], 95);
      expect(items[0]['cost'], 19.5);
      expect(items[0]['catalogRate'], 89, reason: 'the catalog price it was added at is kept, even after the override');
      expect(items[0]['catalogCost'], 19.5);
      expect(items[0]['inventoryItemId'], 7);
      expect(items[0]['sku'], 'TS-25032');
      expect(items[0]['source'], 'catalog');
      expect(items[1]['quantity'], 1);
      // Adding to an estimate never touches stock.
      expect(s.requests.where((r) => r.contains('checkout') || r.contains('inventory')), isEmpty);
    });

    testWidgets('a catalog entry with no price on file comes in unpriced, and the option can\'t be accepted until it is priced', (t) async {
      final s = FakeJobServer();
      await pumpJobPage(t, s, id: kEstimateId, body: () async {
        await t.tap(find.text('New option'));
        await settle(t, frames: 3);
        await t.tap(find.text('Blank option'));
        await settle(t);
        await t.enterText(_search, 'rolling');
        await settle(t, frames: 4);
        expect(find.textContaining('Price varies'), findsOneWidget, reason: 'the range is shown, no made-up default');
        await t.tap(find.text('Clopay Rolling Door').last);
        await settle(t, frames: 4);
        expect(find.text('Not priced'), findsOneWidget);
        expect(find.textContaining('1 line not priced yet'), findsOneWidget);
        await t.tap(find.text('Save'));
        await settle(t);
        await t.tap(find.text('Accept'));
        await settle(t, frames: 4);
        await t.tap(find.text('Accept option'));
        await settle(t);
        expect(find.textContaining('no price yet'), findsOneWidget, reason: 'the server refuses and says why');
      });
      expect((s.saves.last['items'] as List).single['rate'], isNull);
    });

    testWidgets('a custom line and a discount: the custom line opens on its price, the discount comes off the total', (t) async {
      final s = FakeJobServer();
      await pumpJobPage(t, s, id: kEstimateId, body: () async {
        await t.tap(find.text('New option'));
        await settle(t, frames: 3);
        await t.tap(find.text('Blank option'));
        await settle(t);
        await t.enterText(_search, 'Haul away old door');
        await settle(t, frames: 4);
        await t.tap(find.textContaining('Add a custom line'));
        await settle(t, frames: 3);
        await _type(t, _cell(0, 'rate'), '59');
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(t, frames: 2);
        await t.tap(find.text('Discount'));
        await settle(t, frames: 3);
        await _type(t, _cell(1, 'rate'), '9');
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(t, frames: 3);
        expect(find.text(r'-$9.00'), findsWidgets);
        expect(find.text(r'$50.00'), findsWidgets, reason: 'total 59 - 9');
        await t.tap(find.text('Save'));
        await settle(t);
      });
      final items = (s.saves.last['items'] as List).cast<Map>();
      expect(items[0]['name'], 'Haul away old door');
      expect(items[0]['source'], 'manual');
      expect(items[1]['kind'], 'discount');
      expect(items[1]['rate'], 9);
    });

    testWidgets('an invalid number blocks Save and says which line', (t) async {
      final s = FakeJobServer();
      await pumpJobPage(t, s, id: kEstimateId, body: () async {
        await t.tap(find.text('New option'));
        await settle(t, frames: 3);
        await t.tap(find.text('Blank option'));
        await settle(t);
        await _pick(t, 'spring', 'Torsion Spring | 0.250 x 2" x 32"');
        await t.tap(find.text(r'$89.00').first);
        await settle(t, frames: 2);
        await _type(t, _cell(0, 'qty'), '2..5');
        await t.tap(find.text('Save'));
        await settle(t, frames: 4);
        expect(find.textContaining("Line 1: quantity isn't a valid number"), findsOneWidget);
      });
      expect(s.saves, isEmpty, reason: 'nothing bad was sent');
    });
  });

  group('job line items', () {
    testWidgets('Service Fusion\'s items are read-only until copied; then edit, reorder, remove (with undo), add from the catalog, save, and it is all there after a reload', (t) async {
      final s = FakeJobServer();
      await pumpJobPage(t, s, body: () async {
        expect(find.textContaining('Service Fusion\'s line items, read-only'), findsOneWidget);
        // Service Fusion's own figures, as it has them, add up to its total.
        expect(find.text('Sales tax 10.5%'), findsOneWidget);
        expect(find.text(r'$1,735.97'), findsWidgets);
        await t.tap(find.text('Edit line items here'));
        await settle(t);
        expect(s.requests, contains('POST /api/jobs/$kJobId/options'));
        expect(_search, findsOneWidget);
        // The copy totals what Service Fusion says (the discount came across as a discount line).
        expect(find.text('Builder Relationship Discount'), findsOneWidget);
        expect(find.text(r'$1,735.97'), findsWidgets);

        // Stop mold: 4 -> 6.
        await t.tap(find.text(r'$17.84').first);
        await settle(t, frames: 2);
        await _type(t, _cell(2, 'qty'), '6');
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(t, frames: 2);
        expect(find.text(r'$26.76'), findsWidgets);

        // Move the install below the door, remove the stop mold, then undo the removal.
        await t.tap(find.byTooltip('Line 1 actions'));
        await settle(t, frames: 3);
        await t.tap(find.text('Move down'));
        await settle(t, frames: 2);
        await t.tap(find.byTooltip('Line 3 actions'));
        await settle(t, frames: 3);
        await t.tap(find.text('Remove line'));
        await settle(t, frames: 8);
        expect(find.text("Stop Mold | 7' Sandtone"), findsNothing);
        await t.tap(find.text('Undo'));
        await settle(t, frames: 3);
        expect(find.text("Stop Mold | 7' Sandtone"), findsOneWidget);

        await _pick(t, 'spring', 'Spring Replacement | Labor');
        await t.tap(find.text('Save'));
        await settle(t);
      });
      final items = (s.saves.last['items'] as List).cast<Map>();
      expect(items.map((i) => i['name']).toList(), [
        'SMH | Gallery Steel | GD5S | Complete Door | Sandtone (Clay)',
        'SMH Installation | Gallery Steel | 16x7 | Sandtone',
        "Stop Mold | 7' Sandtone",
        'Builder Relationship Discount',
        'Spring Replacement | Labor',
      ]);
      expect(items[2]['quantity'], 6);
      expect(items[0]['cost'], 507.16, reason: 'Service Fusion\'s extended cost became a unit cost');

      // A fresh page (a refresh, or opening the job again) shows what was saved.
      final again = await pumpJobPage(t, s);
      expect(again.messages, isEmpty);
      expect(find.text('Spring Replacement | Labor'), findsOneWidget);
      expect(find.text(r'$26.76'), findsWidgets);
      expect(find.textContaining('Edited here'), findsOneWidget);
    });

    testWidgets('an unsaved draft survives a look at another tab, and Ctrl+S saves it', (t) async {
      final s = FakeJobServer();
      await pumpJobPage(t, s, body: () async {
        await t.tap(find.text('Edit line items here'));
        await settle(t);
        await _pick(t, 'opener', 'LiftMaster 87504 Smart Opener');
        // Switching the panels' tabs above (Pics, Payment) and back leaves the draft alone.
        await t.tap(find.text('Payment').first);
        await settle(t, frames: 4);
        await t.tap(find.textContaining('Pics').first);
        await settle(t, frames: 4);
        expect(find.text('Unsaved changes'), findsOneWidget);
        await t.tap(find.text('Scheduling').first);
        await t.tap(find.text('Summary').first);
        await settle(t, frames: 4);
        expect(find.text('LiftMaster 87504 Smart Opener'), findsOneWidget);
        await t.tap(find.text('LiftMaster 87504 Smart Opener'));
        await settle(t, frames: 2);
        await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await t.sendKeyEvent(LogicalKeyboardKey.keyS);
        await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await settle(t);
        expect(find.text('Unsaved changes'), findsNothing);
      });
      expect((s.saves.single['items'] as List).length, 5);
    });

    testWidgets('a save refused because someone else saved first keeps the draft and says what to do', (t) async {
      final s = FakeJobServer();
      await pumpJobPage(t, s, body: () async {
        await t.tap(find.text('Edit line items here'));
        await settle(t);
        s.optionsOf(kJobId).first.version += 1; // someone else saved meanwhile
        await _pick(t, 'opener', 'LiftMaster 87504 Smart Opener');
        await t.tap(find.text('Save'));
        await settle(t);
        expect(find.textContaining('Someone else changed these lines'), findsOneWidget);
        expect(find.text('LiftMaster 87504 Smart Opener'), findsOneWidget, reason: 'the draft is still there');
        await t.tap(find.text('Save'));
        await settle(t);
        expect(find.text('Unsaved changes'), findsNothing, reason: 'saving again replaces their version');
      });
    });
  });

  group('estimate options', () {
    testWidgets('options stay independent: duplicate, change the copy, rename, recommend, delete', (t) async {
      final s = FakeJobServer();
      await pumpJobPage(t, s, id: kEstimateId, size: const Size(1500, 2400), body: () async {
        await t.tap(find.text('Copy into Option 1'));
        await settle(t);
        expect(find.text(r'$907.75'), findsWidgets, reason: 'the copy totals what Service Fusion says, incl. 10.5% tax');
        await t.tap(find.byTooltip('Duplicate as a new option'));
        await settle(t);
        expect(find.text('Option 1 (copy)'), findsWidgets);
        await _pick(t, 'opener', 'LiftMaster 87504 Smart Opener');
        await t.tap(find.text('Save'));
        await settle(t);
        // The copy: 907.75 + 689 + 10.5% of 689 (72.35) = 1669.10. The original is untouched.
        expect(find.text(r'$1,669.10'), findsWidgets);
        await t.tap(find.byTooltip('Rename'));
        await settle(t, frames: 3);
        await t.enterText(find.byType(TextField).last, 'Upgraded');
        await t.tap(find.text('Rename').last);
        await settle(t);
        await t.tap(find.byTooltip('Mark as recommended'));
        await settle(t);
        await t.tap(find.textContaining('Option 1').first);
        await settle(t, frames: 4);
        expect(find.text('LiftMaster 87504 Smart Opener'), findsNothing, reason: 'Option 1 never got the opener');
        await t.tap(find.byTooltip('Delete option'));
        await settle(t, frames: 3);
        expect(find.textContaining('The other options are not touched'), findsOneWidget);
        await t.tap(find.text('Delete option'));
        await settle(t);
      });
      final left = s.optionsOf(kEstimateId);
      expect(left.map((o) => o.name), ['Upgraded']);
      expect(left.single.recommended, isTrue);
      expect(left.single.items.length, 6);
    });

    testWidgets('accept one option, it locks, the others stay; send it to the job once', (t) async {
      final s = FakeJobServer();
      seedThreeOptions(s);
      await pumpJobPage(t, s, id: kEstimateId, size: const Size(1500, 2400), body: () async {
        // Each tab shows its own total.
        expect(find.textContaining(r'$892.99'), findsWidgets);
        expect(find.textContaining(r'$1,654.33'), findsWidgets);
        expect(find.textContaining(r'$1,776.02'), findsWidgets);
        await t.tap(find.text('Accept'));
        await settle(t, frames: 4);
        expect(find.textContaining('Accept Upgraded for \$1,654.33?'), findsOneWidget);
        await t.tap(find.text('Accept option'));
        await settle(t);
        expect(find.textContaining('Locked so the agreed price stays'), findsOneWidget);
        expect(_search, findsNothing, reason: 'an accepted option is read-only');
        expect(find.text('Accept'), findsNothing, reason: 'only one option can be accepted');

        await t.tap(find.text('Send to job'));
        await settle(t, frames: 4);
        expect(find.widgetWithText(TextField, kJobId), findsOneWidget, reason: 'the likely job is suggested');
        await t.tap(find.text('Send to job').last);
        await settle(t);
        expect(find.textContaining('sent to job #$kJobId'), findsWidgets);
        expect(find.textContaining('and sent to job #$kJobId'), findsOneWidget);
      });
      final upgraded = s.optionsOf(kEstimateId).firstWhere((o) => o.name == 'Upgraded');
      expect(upgraded.acceptedAt, isNotNull);
      expect(upgraded.convertedJobId, kJobId);
      final jobSet = s.optionsOf(kJobId).single;
      expect(jobSet.sourceOptionId, upgraded.id);
      expect(jobSet.items.length, upgraded.items.length);
      expect(jobSet.items.map((i) => i['rate']), upgraded.items.map((i) => i['rate']));
      expect(s.optionsOf(kEstimateId).where((o) => o.acceptedAt != null).length, 1);
      expect(s.optionsOf(kEstimateId).length, 3, reason: 'the alternatives are kept');
    });

    testWidgets('the customer PDF of an estimate with no proposal offers to make one first', (t) async {
      final s = FakeJobServer();
      await pumpJobPage(t, s, id: kEstimateId, body: () async {
        await t.tap(find.text('Customer PDF'));
        await settle(t, frames: 4);
        expect(find.text('Make the proposal first?'), findsOneWidget);
        await t.tap(find.text('Cancel'));
        await settle(t, frames: 3);
      });
      expect(s.optionsOf(kEstimateId), isEmpty, reason: 'nothing made without asking');
    });
  });

  group('permissions', () {
    testWidgets('someone who can\'t see costs gets no cost columns, profit or margin', (t) async {
      final s = FakeJobServer(canSeeCost: false);
      seedThreeOptions(s);
      final errors = await pumpJobPage(t, s, id: kEstimateId, body: () async {
        expect(find.text('Cost'), findsNothing);
        expect(find.text('Ext. cost'), findsNothing);
        expect(find.text('Gross profit'), findsNothing);
        expect(find.text('Margin'), findsNothing);
        expect(find.text(r'$507.16'), findsNothing);
        await t.enterText(_search, 'spring');
        await settle(t, frames: 4);
        expect(find.textContaining('Cost \$'), findsNothing, reason: 'the catalog hides costs too');
      });
      expect(errors.messages, isEmpty);
    });

    testWidgets('someone who can\'t edit sees the lines but nothing to change them with', (t) async {
      final s = FakeJobServer(canEdit: false);
      seedThreeOptions(s);
      await pumpJobPage(t, s, id: kEstimateId, body: () async {
        expect(_search, findsNothing);
        expect(find.text('New option'), findsNothing);
        expect(find.text('Accept'), findsNothing);
        expect(find.byTooltip('Rename'), findsNothing);
      });
      final job = FakeJobServer(canEdit: false);
      await pumpJobPage(t, job, body: () async {
        expect(find.text('Edit line items here'), findsNothing);
      });
    });
  });

  group('the rest of the page', () {
    testWidgets('balances (Payment tab): owed, paid in full, paid on its invoice, or what is on file', (t) async {
      Future<void> check(Map<String, dynamic> Function(Map<String, dynamic>) edit, String shown) async {
        final rec = edit(jobRecord());
        final s = FakeJobServer(records: {kJobId: rec, kEstimateId: estimateRecord()});
        await pumpJobPage(t, s, body: () async {
          await t.tap(find.text('Payment').first);
          await settle(t, frames: 4);
          expect(find.text('Balance Due'), findsOneWidget);
          expect(find.text(shown), findsWidgets, reason: shown);
        });
      }

      // Service Fusion's $235.97, less the $200.00 Stripe payment (net of its refund) it has no entry for.
      await check((r) => r, r'$35.97');
      await check((r) {
        (r['job'] as Map)['due_total'] = '0';
        r['payments'] = [
          {'amount': '1735.97', 'received_on': '2026-10-09T15:00:00Z', 'payment_type': 'Check', 'transaction_type': 'Payment'},
        ];
        r['stripePayments'] = [];
        return r;
      }, 'Paid in full');
      // The same, with the $200.00 Stripe payment on top: more than the total came in.
      await check((r) {
        (r['job'] as Map)['due_total'] = '0';
        r['payments'] = [
          {'amount': '1735.97', 'received_on': '2026-10-09T15:00:00Z', 'payment_type': 'Check', 'transaction_type': 'Payment'},
        ];
        return r;
      }, r'Overpaid by $200.00');
      await check((r) {
        (r['job'] as Map)['due_total'] = '0';
        r['payments'] = [];
        r['invoices'] = [
          {'number': 12249, 'total': 1735.97, 'is_paid': true, 'invoice_date': '2026-10-09T09:51:06Z'},
        ];
        return r;
      }, 'Paid (invoice #12249)');
      await check((r) {
        (r['job'] as Map)['due_total'] = '0';
        r['payments'] = [];
        r['invoices'] = [];
        r['stripePayments'] = [];
        return r;
      }, r'$0.00 (no payment on file)');
      await check((r) {
        (r['job'] as Map)['due_total'] = '0';
        r['payments'] = [];
        r['invoices'] = [];
        return r;
      }, r'$0.00 (only $200.00 paid on file)');
    });

    testWidgets('Scheduling names the sales agent: the estimate\'s opportunity owner, else the job\'s own, else Not Set', (t) async {
      Future<void> check(Map<String, dynamic> Function(Map<String, dynamic>) edit, String shown) async {
        final s = FakeJobServer(records: {kJobId: edit(jobRecord()), kEstimateId: estimateRecord()});
        await pumpJobPage(t, s, body: () async {
          expect(find.text('Sales Agent'), findsOneWidget);
          // The nearest Row is the icon + label; the next one out is the whole row with its value.
          final row = find.ancestor(of: find.text('Sales Agent'), matching: find.byType(Row)).at(1);
          expect(find.descendant(of: row, matching: find.text(shown)), findsWidgets, reason: shown);
        });
      }

      await check((r) => r..['fromEstimateOwner'] = 'Zac Moore', 'Zac Moore');
      await check((r) => r, 'Heather Vera');
      await check((r) {
        (r['job'] as Map).remove('opportunity_owner');
        return r;
      }, 'Not Set');
    });

    testWidgets('Scheduling opens with where the job stands in time, and the visits sit on a timeline with today marked', (t) async {
      Future<void> check(int month, int day, Map<String, dynamic> Function(Map<String, dynamic>) edit, List<String> shown, {String? shot}) async {
        _today(month, day);
        final s = FakeJobServer(records: {kJobId: edit(jobRecord()), kEstimateId: estimateRecord()});
        final errors = await pumpJobPage(t, s, body: () async {
          for (final text in shown) {
            expect(find.text(text), findsWidgets, reason: text);
          }
          if (shot != null) await saveJobShot(t, shot);
        });
        expect(errors.messages, isEmpty);
      }

      Map<String, dynamic> open(Map<String, dynamic> r) => r..['job'] = (Map<String, dynamic>.from(r['job'] as Map)..remove('closed_at'));

      await check(11, 3, (r) => r, ['Closed 25 days ago'], shot: 'timing_closed');
      expect(find.textContaining('Today, '), findsNothing); // a closed job's visits are all behind it
      await check(10, 6, open, ['On site today', 'Day 1 of 2  ·  8:00 AM - 10:00 AM'], shot: 'timing_on_site');
      await check(10, 1, open, ['Starts in 5 days', 'Today, Oct 1'], shot: 'timing_upcoming');
      await check(10, 20, open, ['Work finished 13 days ago', 'Today, Oct 20']);
      await check(10, 20, (r) {
        final job = Map<String, dynamic>.from(r['job'] as Map)
          ..remove('closed_at')
          ..remove('start_date')
          ..remove('end_date');
        (job['sf_details'] as Map).remove('visits');
        return r..['job'] = job;
      }, ['Not scheduled yet']);
    });

    testWidgets('Payment opens with a paid bar, how long the balance has been open, the invoice, and the balance after each payment', (t) async {
      _today(11, 3);
      final s = FakeJobServer(records: {kJobId: jobRecord(), kEstimateId: estimateRecord()});
      await pumpJobPage(t, s, body: () async {
        await t.tap(find.text('Payment').first);
        await settle(t, frames: 12);
        await saveJobShot(t, 'payment_owed');
        // Service Fusion has $1,500.00 of $1,735.97; the Stripe deposit less its refund ($200.00) counts too.
        expect(find.textContaining(r'of $1,735.97 paid', findRichText: true), findsOneWidget);
        expect(find.text('98% paid'), findsOneWidget);
        expect(find.text('Balance open 27 days'), findsOneWidget); // since the work finished on Oct 7
        expect(find.text(r'$235.97 left'), findsOneWidget); // after the check
        expect(find.text(r'$35.97 left'), findsNWidgets(2)); // the bar, and after the Stripe refund
        expect(find.text('Invoice #12249  ·  Oct 9, 2026'), findsOneWidget);
        expect(find.text('Unpaid'), findsOneWidget);
        expect(find.text(r'Request $35.97'), findsOneWidget);
        // Stripe: each payment in date order with what it was for and its reference, marked as not in Service Fusion.
        expect(find.text('Deposit via Stripe'), findsOneWidget);
        expect(find.text('Refund via Stripe'), findsOneWidget);
        expect(find.text('pi_3Q1abc'), findsNWidgets(2));
        expect(find.text('Not in Service Fusion'), findsNWidgets(2));
        expect(find.textContaining(r'$200.00 paid through Stripe', findRichText: true), findsOneWidget);
      });

      final paid = jobRecord();
      (paid['job'] as Map)['due_total'] = '0';
      paid['payments'] = [
        {'amount': '1000.00', 'received_on': '2026-10-08T15:00:00Z', 'payment_type': 'Check', 'transaction_type': 'Payment'},
        {'amount': '735.97', 'received_on': '2026-10-09T15:00:00Z', 'payment_type': 'Card', 'transaction_type': 'Payment'},
      ];
      paid['invoices'] = [];
      paid['stripePayments'] = []; // paid in full in Service Fusion alone
      await pumpJobPage(t, FakeJobServer(records: {kJobId: paid, kEstimateId: estimateRecord()}), body: () async {
        await t.tap(find.text('Payment').first);
        await settle(t, frames: 12);
        await saveJobShot(t, 'payment_paid');
        expect(find.text('100% paid'), findsOneWidget);
        expect(find.text(r'$735.97 left'), findsOneWidget);
        expect(find.text('Nothing left to pay'), findsOneWidget);
        expect(find.textContaining('Balance open'), findsNothing);
        expect(find.textContaining('Request '), findsNothing); // nothing to ask for
      });
    });

    testWidgets('Task List and Notes: counts in the headings, ours and Service Fusion\'s told apart, tick off and remove', (t) async {
      final s = FakeJobServer(records: {kJobId: jobRecord(), kEstimateId: estimateRecord()});
      s.tasks.addAll([
        {'id': '1', 'description': 'Order the forklift for day two', 'isCompleted': false, 'createdBy': 'Dana Whitfield', 'createdAt': '2026-11-02T15:00:00Z'},
      ]);
      s.notes.addAll([
        {'id': '1', 'body': 'Customer wants the grays to match the garage trim.', 'author': 'Dana Whitfield', 'createdAt': '2026-11-02T16:00:00Z'},
        {'id': '2', 'body': 'Gate code changed to 5581.', 'author': 'Marcus Lee', 'createdAt': '2026-11-01T14:00:00Z'},
      ]);
      final errors = await pumpJobPage(t, s, body: () async {
        await saveJobShot(t, 'notes_tasks');
        expect(find.text('Task List (3)'), findsOneWidget);
        expect(find.text('1 of 3 done'), findsOneWidget); // ours + Service Fusion's two, one already ticked
        expect(find.text('Notes (3)'), findsOneWidget);
        expect(find.text('Show all 3 notes (1 older)'), findsOneWidget);
        expect(find.textContaining('Service Fusion'), findsWidgets);

        await t.tap(find.byTooltip('Mark done'));
        await settle(t, frames: 8);
        expect(find.text('2 of 3 done'), findsOneWidget);
        expect(find.textContaining('done by Dana Whitfield'), findsOneWidget);

        await t.tap(find.text('Show all 3 notes (1 older)'));
        await settle(t, frames: 8);
        expect(find.text('Doors are unloaded on site.'), findsOneWidget);
        await saveJobShot(t, 'notes_tasks_open');
      });
      expect(errors.messages, isEmpty);

      // The pop-ups: an empty note is refused under the field; a failed save keeps the text and says why; then it saves.
      await pumpJobPage(t, s, body: () async {
        s.notesDown = true;
        await t.tap(find.text('Add Notes'));
        await settle(t, frames: 6);
        expect(find.text('Add a note'), findsOneWidget);
        await t.tap(find.text('Save note'));
        await settle(t, frames: 4);
        expect(find.text('Type something first.'), findsOneWidget);
        await t.enterText(find.byType(TextField), 'Builder asked for a Saturday install.');
        await t.tap(find.text('Save note'));
        await settle(t, frames: 6);
        expect(find.textContaining('Not saved: The database is busy.'), findsOneWidget);
        expect(find.text('Builder asked for a Saturday install.'), findsOneWidget); // still in the box
        await saveJobShot(t, 'dialog_note_failed');
        s.notesDown = false;
        await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await t.sendKeyEvent(LogicalKeyboardKey.enter); // Ctrl+Enter saves a note
        await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await settle(t, frames: 8);
        expect(find.text('Add a note'), findsNothing);
        expect(find.text('Builder asked for a Saturday install.'), findsOneWidget); // now on the page

        await t.tap(find.text('Add Task'));
        await settle(t, frames: 6);
        await saveJobShot(t, 'dialog_task');
        await t.enterText(find.byType(TextField), 'Call the builder about Saturday');
        await t.testTextInput.receiveAction(TextInputAction.done); // Enter saves a task
        await settle(t, frames: 8);
        expect(find.text('Call the builder about Saturday'), findsOneWidget);

        await t.tap(find.byTooltip('Remove task').first);
        await settle(t, frames: 6);
        expect(find.text('Remove this task?'), findsOneWidget);
        await saveJobShot(t, 'dialog_remove_task');
        await t.tap(find.text('Cancel'));
        await settle(t, frames: 6);
        expect(find.text('Remove this task?'), findsNothing);
        expect(find.text('Call the builder about Saturday'), findsOneWidget); // Cancel keeps it
      });

      // Nothing on the job: each panel says so and points at its Add button.
      final bare = jobRecord();
      ((bare['job'] as Map)['sf_details'] as Map)
        ..remove('tasks')
        ..remove('notes');
      final empty = await pumpJobPage(t, FakeJobServer(records: {kJobId: bare, kEstimateId: estimateRecord()}), body: () async {
        expect(find.text('No tasks yet. Use Add Task to add one.'), findsOneWidget);
        expect(find.text('No notes yet. Use Add Notes to write one.'), findsOneWidget);
        expect(find.text('Add Task'), findsOneWidget);
        expect(find.text('Add Notes'), findsOneWidget);
        await saveJobShot(t, 'notes_tasks_empty');
      });
      expect(empty.messages, isEmpty);

      // Narrow window: the two stack and nothing overflows.
      final narrow = await pumpJobPage(t, s, size: const Size(560, 3200));
      expect(narrow.messages, isEmpty);
    });

    testWidgets('a Stripe payment the office also entered in Service Fusion shows once, as the Stripe payment, and still counts', (t) async {
      _today(11, 3);
      final r = jobRecord();
      (r['job'] as Map)['due_total'] = '0';
      r['invoices'] = [];
      r['payments'] = [
        {'amount': '1500.00', 'received_on': '2026-10-09T15:00:00Z', 'payment_type': 'Check', 'transaction_type': 'Payment'},
        // What the office types in Service Fusion for a Stripe payment (a Chicago date stamped UTC, so it reads a day early).
        {'amount': '235.97', 'received_on': '2026-10-30T00:00:00Z', 'payment_type': 'Credit Card (Offline)', 'transaction_type': 'Payment', 'reference_number': 'Job Payment Database'},
      ];
      r['stripePayments'] = [
        {'id': 'stripe-pi_final', 'amount': '235.97', 'received_on': '2026-10-30T16:39:00Z', 'kind': 'payment', 'memo': 'Stripe Final Balance - job #1096183137 - Schuber Mitchell Homes', 'payment_intent': 'pi_final'},
        // Not entered in Service Fusion yet: listed with the others, marked, and counted on the job.
        {'id': 'stripe-pi_tip', 'amount': '40.00', 'received_on': '2026-11-01T16:00:00Z', 'kind': 'payment', 'memo': 'Stripe Payment - job #1096183137', 'payment_intent': 'pi_tip'},
      ];
      await pumpJobPage(t, FakeJobServer(records: {kJobId: r, kEstimateId: estimateRecord()}), body: () async {
        await t.tap(find.text('Payment').first);
        await settle(t, frames: 12);
        await saveJobShot(t, 'payment_stripe_merged');
        expect(find.text('Final Balance via Stripe'), findsOneWidget);
        expect(find.textContaining('Credit Card (Offline)'), findsNothing); // the Service Fusion copy is not drawn again
        expect(find.text('pi_final'), findsOneWidget);
        expect(find.text('Nothing left to pay'), findsOneWidget); // after the entered one
        expect(find.text(r'$40.00 over'), findsOneWidget); // the $40 on top is beyond the total
        expect(find.text('102% paid'), findsOneWidget);
        expect(find.text('Payment via Stripe'), findsOneWidget);
        expect(find.text('Not in Service Fusion'), findsOneWidget); // only the $40
        expect(find.textContaining(r'$40.00 paid through Stripe', findRichText: true), findsOneWidget);
      });
    });

    testWidgets('paid twice: the card, Balance Due and the list say how much too much came in (job 1087590664 on prod)', (t) async {
      _today(11, 3);
      final r = jobRecord();
      (r['job'] as Map)['due_total'] = '0';
      r['invoices'] = [];
      // The office entered the first Stripe charge; two days later Stripe took the same amount again, never refunded.
      r['payments'] = [
        {'amount': '1735.97', 'received_on': '2026-06-29T00:00:00Z', 'payment_type': 'Credit Card (Offline)', 'transaction_type': 'Payment', 'reference_number': 'Job Payment Database'},
      ];
      r['stripePayments'] = [
        {'id': 'stripe-pi_first', 'amount': '1735.97', 'received_on': '2026-06-29T14:17:24Z', 'kind': 'payment', 'memo': 'Stripe Final Balance - job #1096183137', 'payment_intent': 'pi_first'},
        {'id': 'stripe-pi_again', 'amount': '1735.97', 'received_on': '2026-07-01T18:28:56Z', 'kind': 'payment', 'memo': 'Stripe Final Balance - job #1096183137', 'payment_intent': 'pi_again'},
      ];
      final errors = await pumpJobPage(t, FakeJobServer(records: {kJobId: r, kEstimateId: estimateRecord()}), body: () async {
        await t.tap(find.text('Payment').first);
        await settle(t, frames: 12);
        await saveJobShot(t, 'payment_overpaid');
        expect(find.textContaining(r'$3,471.94', findRichText: true), findsWidgets); // $3,471.94 of $1,735.97 paid
        expect(find.text('200% paid'), findsOneWidget);
        expect(find.text(r'Overpaid $1,735.97'), findsOneWidget);
        expect(find.text(r'Overpaid by $1,735.97'), findsOneWidget); // Balance Due
        expect(find.text('Paid in full'), findsNothing);
        expect(find.textContaining(r'$1,735.97 more than the job total was paid.', findRichText: true), findsOneWidget);
        expect(find.text('Nothing left to pay'), findsOneWidget); // after the first
        expect(find.text(r'$1,735.97 over'), findsOneWidget); // after the second
        expect(find.textContaining('Request '), findsNothing);
      });
      expect(errors.messages, isEmpty);
    });

    testWidgets('a job paid only through Stripe reads as paid, with the payment in the list (job 1095809012 on prod)', (t) async {
      _today(11, 3);
      final r = jobRecord();
      // Service Fusion: $0 due, and its payment entry has not synced here.
      (r['job'] as Map)['due_total'] = '0';
      r['payments'] = [];
      r['invoices'] = [];
      r['stripePayments'] = [
        {'id': 'stripe-pi_full', 'amount': '1735.97', 'received_on': '2026-10-12T13:16:26Z', 'kind': 'payment', 'memo': 'Stripe Final Balance - job #1096183137 - Schuber Mitchell Homes', 'payment_intent': 'pi_full'},
      ];
      final errors = await pumpJobPage(t, FakeJobServer(records: {kJobId: r, kEstimateId: estimateRecord()}), body: () async {
        await t.tap(find.text('Payment').first);
        await settle(t, frames: 12);
        await saveJobShot(t, 'payment_stripe_only');
        expect(find.textContaining(r'$1,735.97', findRichText: true), findsWidgets);
        expect(find.text('100% paid'), findsOneWidget);
        expect(find.text('Paid in full'), findsNWidgets(2)); // the card and Balance Due
        expect(find.text('No payments recorded'), findsNothing);
        expect(find.text('Final Balance via Stripe'), findsOneWidget);
        expect(find.text('Paid in Service Fusion'), findsOneWidget);
        expect(find.text('Not in Service Fusion'), findsNothing); // job 1100263579: Service Fusion did have the payment
        expect(find.textContaining('no payment entry', findRichText: true), findsNothing);
        expect(find.textContaining('has not synced here yet', findRichText: true), findsOneWidget);
        expect(find.text('Nothing left to pay'), findsOneWidget);
        expect(find.textContaining('Request '), findsNothing); // nothing to ask for
        expect(find.textContaining(r'$1,735.97 paid through Stripe', findRichText: true), findsOneWidget);
      });
      expect(errors.messages, isEmpty);
    });

    testWidgets('Stripe pairing: a cent off, a partial refund the office entered net, a charge refunded in full (all from prod)', (t) async {
      _today(11, 3);
      final r = jobRecord();
      (r['job'] as Map)['due_total'] = '0';
      r['invoices'] = [];
      r['payments'] = [
        // The office typed a cent less than Stripe charged (jobs 1083924657, 1084296878).
        {'amount': '1355.97', 'received_on': '2026-10-09T00:00:00Z', 'payment_type': 'Credit Card (Offline)', 'transaction_type': 'Payment', 'reference_number': 'Job Payment Database'},
        // The office entered what was left after a refund (job 1099563432: $563.35 less $183.35).
        {'amount': '380.00', 'received_on': '2026-10-16T00:00:00Z', 'payment_type': 'Credit Card (Offline)', 'transaction_type': 'Payment', 'reference_number': 'Job Payment Database'},
      ];
      r['stripePayments'] = [
        {'id': 'stripe-pi_cent', 'amount': '1355.98', 'received_on': '2026-10-09T15:00:00Z', 'kind': 'payment', 'memo': 'Stripe Deposit - job #1096183137', 'payment_intent': 'pi_cent'},
        {'id': 'stripe-pi_net', 'amount': '563.35', 'received_on': '2026-10-13T14:51:30Z', 'kind': 'payment', 'memo': 'Stripe Final Balance - job #1096183137', 'payment_intent': 'pi_net'},
        {'id': 'stripe-refund-re_net', 'amount': '-183.35', 'received_on': '2026-10-16T10:22:37Z', 'kind': 'refund', 'memo': 'Stripe refund', 'payment_intent': 'pi_net'},
        // Charged twice by mistake and the second given back (job 1090118471): it pairs with nothing and nets to $0.
        {'id': 'stripe-pi_twice', 'amount': '380.00', 'received_on': '2026-10-16T15:00:00Z', 'kind': 'payment', 'memo': 'Stripe Final Balance - job #1096183137', 'payment_intent': 'pi_twice'},
        {'id': 'stripe-refund-re_twice', 'amount': '-380.00', 'received_on': '2026-10-17T09:00:00Z', 'kind': 'refund', 'memo': 'Stripe refund', 'payment_intent': 'pi_twice'},
      ];
      final errors = await pumpJobPage(t, FakeJobServer(records: {kJobId: r, kEstimateId: estimateRecord()}), body: () async {
        await t.tap(find.text('Payment').first);
        await settle(t, frames: 12);
        await saveJobShot(t, 'payment_stripe_pairing');
        expect(find.textContaining('Credit Card (Offline)'), findsNothing); // both office entries show as Stripe
        expect(find.text('pi_cent'), findsOneWidget);
        expect(find.text('pi_net'), findsOneWidget); // the refund folded into the entry the office made
        expect(find.text('Paid in full'), findsNWidgets(2)); // $1,355.97 + $380.00 entered, and the double charge nets $0
        expect(find.text('Not in Service Fusion'), findsNWidgets(2)); // the double charge and its refund
        expect(find.text('pi_twice'), findsNWidgets(2));
        expect(find.textContaining('through Stripe', findRichText: true), findsNothing); // nets to $0: no note
      });
      expect(errors.messages, isEmpty);
    });

    testWidgets('Payment: the invoice opens to its details (emailed, terms, billed to, QuickBooks, work) with its online link', (t) async {
      _today(11, 3);
      final s = FakeJobServer(records: {kJobId: jobRecord(), kEstimateId: estimateRecord()});
      final errors = await pumpJobPage(t, s, body: () async {
        await t.tap(find.text('Payment').first);
        await settle(t, frames: 12);
        // The only invoice starts open.
        // Shown in local time, so only the day and how long ago are pinned here.
        expect(find.textContaining(RegExp(r'^Oct 9, 2026 at \d{1,2}:\d\d [AP]M \(25 days ago\)$')), findsOneWidget);
        expect(find.text('Due upon receipt'), findsOneWidget);
        expect(find.text('Accounting'), findsOneWidget);
        expect(find.text('Invoice #12249'), findsOneWidget); // the QuickBooks number
        expect(find.text('Two 16x7 Gallery Steel doors / Stop mold'), findsOneWidget); // SF's underscore rule trimmed off
        expect(find.text('Open invoice'), findsOneWidget);
        expect(find.text('Copy link'), findsOneWidget);
        await saveJobShot(t, 'payment_invoice_open');

        await t.tap(find.text('Invoice #12249  ·  Oct 9, 2026'));
        await settle(t, frames: 6);
        expect(find.text('Due upon receipt'), findsNothing);
        await t.tap(find.text('Invoice #12249  ·  Oct 9, 2026'));
        await settle(t, frames: 6);
        expect(find.text('Due upon receipt'), findsOneWidget);
      });
      expect(errors.messages, isEmpty);

      // Narrow window: the details still fit.
      final narrow = await pumpJobPage(t, s, size: const Size(560, 3200), body: () async {
        await t.tap(find.byTooltip('Payment').first); // narrow tabs are icons, named by their tooltip
        await settle(t, frames: 12);
        expect(find.text('Due upon receipt'), findsOneWidget);
        await saveJobShot(t, 'payment_invoice_narrow');
      });
      expect(narrow.messages, isEmpty);
    });

    testWidgets('a record opened by its address shows the page shape, then the record; a missing one says so with Retry', (t) async {
      final s = FakeJobServer();
      final errors = await pumpJobPage(t, s, id: '1999999999');
      expect(errors.messages, isEmpty);
      expect(find.text('Job #1999999999 was not found.'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });
  });
}
