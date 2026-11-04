// Renders the Payments screen with fake API data to test/shots/. Run:  flutter test test/payments_render_test.dart --update-goldens

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/payments_screen.dart';
import 'package:iohd_desktop/theme/app_theme.dart';
import 'package:iohd_desktop/widgets/dashboard_kit.dart';
import 'package:iohd_desktop/widgets/stripe_mark.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
  }
  await loader.load();
}

final _requests = <Uri>[];

// Shapes as payments_list.js sends them.
const _rows = [
  // A Stripe payment the office entered in Service Fusion: Stripe's details.
  {'id': 'a', 'job_id': '1099563432', 'customer': 'John Bishop', 'job_on_file': true, 'payment_type': 'Credit Card (Offline)', 'transaction_type': 'Payment', 'reference_number': 'Job Payment Database', 'amount': 380.0, 'via_stripe': true, 'received_on': '2026-10-16T00:00:00Z', 'source': 'sf', 'counted': true, 'stripe_id': 'stripe-pi_3UWlpdDct5wTeJeh3QCuw65p', 'stripe_received_on': '2026-10-16T16:39:00Z', 'stripe_memo': 'Stripe Final Balance - job #1099563432 - John Bishop', 'stripe_intent': 'pi_3UWlpdDct5wTeJeh3QCuw65p'},
  // Stripe payments nobody has entered in Service Fusion yet, one of them with no job number.
  {'id': 'stripe-pi_new', 'job_id': '1096000001', 'customer': 'Cooper Family', 'job_on_file': true, 'payment_type': 'Stripe', 'transaction_type': 'Payment', 'reference_number': 'pi_new', 'amount': 900.0, 'via_stripe': true, 'received_on': '2026-10-16T14:00:00Z', 'source': 'stripe', 'counted': false, 'stripe_id': 'stripe-pi_new', 'stripe_received_on': '2026-10-16T14:00:00Z', 'stripe_memo': 'Stripe Deposit - job #1096000001 - Cooper Family', 'stripe_intent': 'pi_new'},
  {'id': 'stripe-pi_nojob', 'job_id': null, 'customer': '', 'job_on_file': false, 'payment_type': 'Stripe', 'transaction_type': 'Payment', 'reference_number': 'pi_nojob', 'amount': 60.0, 'via_stripe': true, 'received_on': '2026-10-16T13:00:00Z', 'source': 'stripe', 'counted': false, 'stripe_id': 'stripe-pi_nojob', 'stripe_received_on': '2026-10-16T13:00:00Z', 'stripe_memo': 'Stripe Payment - no job number - Walk In Smith', 'stripe_intent': 'pi_nojob'},
  // Service Fusion has this job paid but its payment entry has not synced here: listed, not in the not-entered total.
  {'id': 'stripe-pi_inv', 'job_id': '1096000002', 'customer': 'Maple Court Apartments', 'job_on_file': true, 'payment_type': 'Stripe', 'transaction_type': 'Payment', 'reference_number': 'pi_inv', 'amount': 410.2, 'via_stripe': true, 'received_on': '2026-10-16T12:00:00Z', 'source': 'stripe', 'counted': false, 'sf_settled': true, 'stripe_id': 'stripe-pi_inv', 'stripe_received_on': '2026-10-16T12:00:00Z', 'stripe_memo': 'Stripe Final Balance - job #1096000002 -', 'stripe_intent': 'pi_inv'},
  {'id': 'b', 'job_id': '1094424959', 'customer': '911 Restoration', 'job_on_file': true, 'payment_type': 'Check', 'transaction_type': 'Payment', 'reference_number': '2682', 'amount': 47223.08, 'received_on': '2026-10-16T00:00:00Z'},
  {'id': 'c', 'job_id': '1094865244', 'customer': 'JDW Construction With A Very Long Company Name Incorporated', 'job_on_file': true, 'payment_type': 'Credit Card (Offline)', 'transaction_type': 'Payment', 'reference_number': 'Job Payment Database', 'amount': 2940.87, 'via_stripe': true, 'received_on': '2026-10-16T00:00:00Z'},
  {'id': 'd', 'job_id': '1099563432', 'customer': 'John Bishop', 'job_on_file': true, 'payment_type': 'Credit Card (Offline)', 'transaction_type': 'VOID', 'reference_number': 'Job Payment Database', 'amount': 0.0, 'received_on': '2026-10-16T09:54:29Z'},
  // Paid through Stripe on Oct 14; the office entered it in Service Fusion two days later, the day the totals count it.
  {'id': 'f', 'job_id': '1096784577', 'customer': 'Ridgeview HOA', 'job_on_file': true, 'payment_type': 'Credit Card (Offline)', 'transaction_type': 'Payment', 'reference_number': 'Job Payment Database', 'amount': 13680.43, 'via_stripe': true, 'received_on': '2026-10-16T00:00:00Z', 'source': 'sf', 'counted': true, 'stripe_id': 'stripe-pi_late', 'stripe_received_on': '2026-10-14T19:02:12Z', 'stripe_memo': 'Stripe Deposit - job #1096784577 - Ridgeview HOA', 'stripe_intent': 'pi_late'},
  {'id': 'e', 'job_id': '1096961883', 'customer': 'Rogers Dental', 'job_on_file': true, 'payment_type': 'Check', 'transaction_type': 'REFUND', 'reference_number': '3242', 'amount': -150.0, 'received_on': '2026-10-14T00:00:00Z'},
  // A correction typed as a negative "payment", and a payment whose job is not in the app.
  {'id': 'g', 'job_id': '1057388582', 'customer': 'Hill Street Storage', 'job_on_file': true, 'payment_type': 'Cash', 'transaction_type': 'Payment', 'reference_number': 'Cash', 'amount': -1.47, 'received_on': '2026-10-13T00:00:00Z'},
  {'id': 'h', 'job_id': '1083818562', 'customer': '', 'job_on_file': false, 'payment_type': 'Check', 'transaction_type': 'Payment', 'reference_number': '126344', 'amount': 897.03, 'received_on': '2026-10-13T00:00:00Z'},
];

// The Final Invoice Sent, $0 balance filter: a payment, a Stripe payment paid on the SF invoice, and a billed job with none.
const _finalZeroRows = [
  {'id': 'z', 'job_id': '1100608371', 'customer': 'Dave Ganzel', 'job_on_file': true, 'job_total': 787.1, 'payment_type': 'Check', 'transaction_type': 'Payment', 'reference_number': '2682', 'amount': 787.1, 'received_on': '2026-11-03T00:00:00Z', 'source': 'sf', 'counted': true},
  {'id': 'stripe-pi_inv', 'job_id': '1095809012', 'customer': 'Ideal Structures LLC', 'job_on_file': true, 'job_total': 10102.36, 'payment_type': 'Stripe', 'transaction_type': 'Payment', 'reference_number': 'pi_inv', 'amount': 10102.36, 'via_stripe': true, 'received_on': '2026-10-16T12:00:00Z', 'source': 'stripe', 'counted': false, 'sf_settled': true, 'stripe_id': 'stripe-pi_inv', 'stripe_received_on': '2026-10-16T12:00:00Z', 'stripe_memo': 'Stripe Final Balance - job #1095809012 -', 'stripe_intent': 'pi_inv'},
  {'id': '1093058241', 'job_id': '1093058241', 'customer': 'Lennar', 'job_on_file': true, 'job_total': 410.0, 'payment_type': '', 'transaction_type': 'None', 'reference_number': null, 'amount': 0, 'received_on': null, 'source': 'job', 'counted': false, 'via_stripe': false, 'sf_settled': false},
];

const _stats = {'today': 0, 'month': 78271.57, 'monthCount': 38, 'stripeNotEntered': 960.0, 'stripeNotEnteredCount': 2};

http.Response _page(List<Map<String, Object?>> rows, {int total = 10930, int totalPages = 219, bool filters = true, bool sorts = true, bool types = false}) => http.Response(
      jsonEncode({
        'data': rows,
        'total': total,
        'totalPages': totalPages,
        if (filters) 'filters': ['final_zero', if (types) 'type'],
        if (sorts) 'sorts': ['date', 'customer', 'amount'],
        'stats': _stats,
      }),
      200,
    );

http.Client _mock({bool empty = false, int? failCode}) => MockClient((req) async {
      _requests.add(req.url);
      if (failCode != null) return http.Response('boom', failCode);
      if (req.url.queryParameters['show'] == 'final_zero') return _page(_finalZeroRows, total: 3, totalPages: 1);
      return empty ? _page(const [], total: 0, totalPages: 1) : _page(_rows);
    });

// The app's own colours (main.dart), so buttons in the shots are the real ones.
final _theme = ThemeData(
  useMaterial3: true,
  fontFamily: 'Segoe UI',
  colorScheme: ColorScheme.fromSeed(seedColor: AppTheme.brandRed, primary: AppTheme.brandRed),
);

Widget _app(Widget home) => MaterialApp(debugShowCheckedModeBanner: false, theme: _theme, home: home);

Future<void> _shot(WidgetTester t, Size size, String name, http.Client client, {Future<void> Function()? then}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  await http.runWithClient(() async {
    await t.pumpWidget(RepaintBoundary(key: const ValueKey('shot'), child: _app(const PaymentsScreen())));
    await t.pumpAndSettle();
    if (then != null) await then();
  }, () => client);
  expect(t.takeException(), isNull);
  await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('shots/$name.png'));
}

/// Taps a pager arrow, scrolling it into view first (it sits below the table).
Future<void> _pager(WidgetTester t, String tooltip) async {
  await t.ensureVisible(find.byTooltip(tooltip));
  await t.pumpAndSettle();
  await t.tap(find.byTooltip(tooltip));
  await t.pumpAndSettle();
}

/// Pumps the screen with [client] and runs [body] inside the fake-HTTP zone.
Future<void> _run(WidgetTester t, http.Client client, Future<void> Function() body, {Size size = const Size(1366, 720)}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  _requests.clear();
  await http.runWithClient(() async {
    await t.pumpWidget(_app(const PaymentsScreen()));
    await t.pumpAndSettle();
    await body();
  }, () => client);
}

void main() {
  setUpAll(() async {
    await _loadFont('Segoe UI', ['C:/Windows/Fonts/segoeui.ttf', 'C:/Windows/Fonts/segoeuib.ttf']);
    await _loadFont('MaterialIcons', ['C:/src/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
    // The Stripe mark is drawn from font_awesome_flutter's brands font.
    await (FontLoader('packages/font_awesome_flutter/FontAwesomeBrands')
          ..addFont(rootBundle.load('packages/font_awesome_flutter/lib/fonts/Font-Awesome-7-Brands-Regular-400.otf')))
        .load();
  });

  testWidgets('real rows, no sample data', (t) async {
    await _shot(t, const Size(1366, 900), 'payments_data', _mock());
    expect(find.text('Sarah Jenkins'), findsNothing); // the old dummy row
    expect(find.text('John Bishop'), findsWidgets);
    // Stripe: the entered ones show Stripe's details once; the two not entered are listed but marked and not totalled.
    // The two paired ones, the offline-card one, the two not entered and the one paid on its SF invoice.
    expect(find.byType(StripeMark), findsNWidgets(6));
    expect(find.text('Final Balance'), findsNWidgets(2));
    expect(find.text('pi_3UWlpdDct5wTeJeh3QCuw65p'), findsOneWidget);
    expect(find.text('Job Payment Database'), findsNothing); // the payment sheet's name is not a reference
    expect(find.byTooltip('Copied into Service Fusion from the payment sheet ("Job Payment Database"). No Stripe record to link to.'), findsNWidgets(2));
    expect(find.text('Not in SF'), findsNWidgets(2));
    expect(find.text('Paid in SF'), findsOneWidget); // SF has the job paid: nothing to enter
    expect(find.text('Walk In Smith'), findsOneWidget); // no job on file: the payer named in Stripe
    expect(find.textContaining('Stripe Not in Service Fusion'), findsNothing); // the scorecard is gone, the rows stay marked
    expect(find.text('Refund'), findsOneWidget);
    expect(find.text('Void'), findsOneWidget);
    expect(find.text('Page 1 of 219'), findsOneWidget);
  });

  testWidgets('empty', (t) async => _shot(t, const Size(1366, 720), 'payments_empty', _mock(empty: true)));
  testWidgets('error shows retry and no payment count', (t) async {
    await _shot(t, const Size(1366, 720), 'payments_error', _mock(failCode: 500));
    expect(find.text('Try again'), findsOneWidget);
    expect(find.textContaining('Could not load payments (server error 500)'), findsOneWidget);
    expect(find.text('0 payments'), findsNothing); // the load failed: there is no count to show
  });
  testWidgets('narrow: stacked rows, with the amount and status in view and nothing to scroll sideways', (t) async {
    await _shot(t, const Size(520, 800), 'payments_520', _mock());
    expect(find.text('Date'), findsNothing); // no column headers: every row names its own parts
    final amount = t.getRect(find.text(r'$380.00'));
    final status = t.getRect(find.text('Paid').first);
    expect(amount.right, lessThanOrEqualTo(520));
    expect(status.right, lessThanOrEqualTo(520));
  });
  testWidgets('phone width', (t) async => _shot(t, const Size(360, 780), 'payments_360', _mock()));
  testWidgets('800 wide', (t) async => _shot(t, const Size(800, 900), 'payments_800', _mock()));
  testWidgets('very wide', (t) async => _shot(t, const Size(1920, 1000), 'payments_1920', _mock()));
  testWidgets('text at 130%', (t) async {
    t.view.physicalSize = const Size(1366, 800);
    t.view.devicePixelRatio = 1;
    t.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    await http.runWithClient(() async {
      await t.pumpWidget(RepaintBoundary(key: const ValueKey('shot'), child: _app(const PaymentsScreen())));
      await t.pumpAndSettle();
    }, () => _mock());
    expect(t.takeException(), isNull);
    await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('shots/payments_text130.png'));
  });
  testWidgets('Final Invoice Sent, \$0 balance filter', (t) async {
    await _shot(t, const Size(1366, 720), 'payments_final_zero', _mock(), then: () async {
      await t.tap(find.text(r'Final Invoice Sent, $0 balance'));
      await t.pumpAndSettle();
    });
    expect(_requests.last.queryParameters['show'], 'final_zero');
    expect(_requests.last.queryParameters['page'], '1');
    expect(find.text('Job total'), findsOneWidget);
    expect(find.text('Reference'), findsNothing);
    expect(find.text('No payment'), findsOneWidget);
    expect(find.text(r'$410.00'), findsOneWidget); // the job's total, with no payment against it
    expect(find.text('Paid in SF'), findsOneWidget);
    expect(find.text('911 Restoration'), findsNothing);
    expect(find.text('3 matching'), findsOneWidget);
  });

  testWidgets('switching the filter keeps the old columns over the old rows until the new ones land', (t) async {
    final reply = Completer<http.Response>();
    final client = MockClient((req) async {
      if (req.url.queryParameters['show'] == 'final_zero') return reply.future;
      return _page(_rows);
    });
    await _run(t, client, () async {
      await t.tap(find.text(r'Final Invoice Sent, $0 balance'));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('Job total'), findsNothing); // these rows carry no job total: it would read $0.00
      expect(find.text('Reference'), findsOneWidget);
      reply.complete(_page(_finalZeroRows, total: 3, totalPages: 1));
      await t.pumpAndSettle();
      expect(find.text('Job total'), findsOneWidget);
    });
  });

  testWidgets('a failed reload keeps the rows and says they may be old', (t) async {
    var fail = false;
    final client = MockClient((req) async => fail ? http.Response('boom', 500) : _page(_rows));
    await _run(t, client, () async {
      fail = true;
      await t.tap(find.byTooltip('Refresh'));
      await t.pumpAndSettle();
      expect(find.text('911 Restoration'), findsOneWidget);
      expect(find.textContaining('Showing the last loaded payments'), findsOneWidget);
      expect(find.text("Payments didn't load"), findsNothing);
      fail = false;
      await t.tap(find.text('Try again'));
      await t.pumpAndSettle();
      expect(find.textContaining('Showing the last loaded payments'), findsNothing);
    });
  });

  testWidgets('a failed search does not leave the old rows passing for its answer', (t) async {
    final client = MockClient((req) async => req.url.queryParameters['q'] == 'bishop' ? http.Response('boom', 500) : _page(_rows));
    await _run(t, client, () async {
      await t.enterText(find.byType(TextField), 'bishop');
      await t.pump(const Duration(milliseconds: 500));
      await t.pumpAndSettle();
      expect(find.text("Payments didn't load"), findsOneWidget);
      expect(find.text('911 Restoration'), findsNothing);
    });
  });

  testWidgets('a slow first load says the server may be waking up', (t) async {
    final reply = Completer<http.Response>();
    t.view.physicalSize = const Size(1366, 720);
    t.view.devicePixelRatio = 1;
    await http.runWithClient(() async {
      await t.pumpWidget(_app(const PaymentsScreen()));
      await t.pump(const Duration(seconds: 7));
      expect(find.textContaining('Waking up the server'), findsNothing);
      await t.pump(const Duration(seconds: 2));
      expect(find.textContaining('Waking up the server'), findsOneWidget);
      reply.complete(_page(_rows));
      await t.pumpAndSettle();
      expect(find.textContaining('Waking up the server'), findsNothing);
    }, () => MockClient((_) => reply.future));
  });

  testWidgets('the column headers stay in view while the rows scroll', (t) async {
    final many = [for (var i = 0; i < 50; i++) {..._rows[4], 'id': 'r$i', 'customer': 'Customer $i'}];
    await _run(t, MockClient((req) async => _page(many)), () async {
      final top = t.getTopLeft(find.text('Customer').first).dy;
      await t.drag(find.byType(CustomScrollView), const Offset(0, -900));
      await t.pumpAndSettle();
      expect(find.text('Customer 0'), findsNothing);
      expect(find.text('Customer'), findsOneWidget);
      expect(t.getTopLeft(find.text('Customer')).dy, lessThan(top));
      expect(t.getTopLeft(find.text('Customer')).dy, greaterThanOrEqualTo(56)); // just under the ribbon
    });
  });

  testWidgets('the next page opens at its top, and the pager is there without scrolling to it', (t) async {
    final many = [for (var i = 0; i < 50; i++) {..._rows[4], 'id': 'r$i', 'customer': 'Customer $i'}];
    await _run(t, MockClient((req) async => _page(many)), () async {
      await t.drag(find.byType(CustomScrollView), const Offset(0, -900));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('Next page'));
      await t.pumpAndSettle();
      expect(find.text('Page 2 of 219'), findsOneWidget);
      expect(find.text('51–100 of 10,930'), findsOneWidget);
      expect(find.text('Customer 0'), findsOneWidget);
    });
  });

  testWidgets('rows per page asks for that many, from the first page', (t) async {
    await _run(t, _mock(), () async {
      await _pager(t, 'Next page');
      await t.tap(find.text('100'));
      await t.pumpAndSettle();
    });
    expect(_requests.last.queryParameters['limit'], '100');
    expect(_requests.last.queryParameters['page'], '1');
  });

  testWidgets('sorting: the server is asked, the arrow follows, and a second click turns it round', (t) async {
    await _run(t, _mock(), () async {
      expect(_requests.last.queryParameters.containsKey('sort'), isFalse); // newest first needs no asking
      expect(find.byIcon(Icons.arrow_downward_rounded), findsOneWidget);
      await t.tap(find.text('Amount'));
      await t.pumpAndSettle();
      expect(_requests.last.queryParameters['sort'], 'amount');
      expect(_requests.last.queryParameters['dir'], 'desc');
      expect(_requests.last.queryParameters['page'], '1');
      await t.tap(find.text('Amount'));
      await t.pumpAndSettle();
      expect(_requests.last.queryParameters['dir'], 'asc');
      expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);
      await t.tap(find.text('Customer'));
      await t.pumpAndSettle();
      expect(_requests.last.queryParameters['sort'], 'customer');
      expect(_requests.last.queryParameters['dir'], 'asc'); // names read A to Z first
    });
  });

  testWidgets('a server that cannot sort gets plain headers', (t) async {
    await _run(t, MockClient((req) async {
      _requests.add(req.url);
      return _page(_rows, sorts: false);
    }), () async {
      expect(find.byIcon(Icons.arrow_downward_rounded), findsNothing);
      final asked = _requests.length;
      await t.tap(find.text('Amount'));
      await t.pumpAndSettle();
      expect(_requests.length, asked);
    });
  });

  testWidgets('search: the clear button, Enter, and an empty result that says what was searched', (t) async {
    final client = MockClient((req) async {
      _requests.add(req.url);
      return req.url.queryParameters['q'] == 'nobody' ? _page(const [], total: 0, totalPages: 1) : _page(_rows);
    });
    await _run(t, client, () async {
      expect(find.byTooltip('Clear search'), findsNothing);
      await t.enterText(find.byType(TextField), 'nobody');
      await t.testTextInput.receiveAction(TextInputAction.search); // Enter does not wait for the pause in typing
      await t.pump();
      expect(_requests.last.queryParameters['q'], 'nobody');
      await t.pumpAndSettle();
      expect(find.text('No matching payments'), findsOneWidget);
      expect(find.textContaining('Nothing matches "nobody"'), findsOneWidget);
      await t.tap(find.text('Clear search'));
      await t.pumpAndSettle();
      expect(_requests.last.queryParameters['q'], '');
      expect(find.text('911 Restoration'), findsOneWidget);
      expect(find.byTooltip('Clear search'), findsNothing);
    });
  });

  testWidgets('one payment is one payment', (t) async {
    await _run(t, MockClient((req) async => _page([_rows[4]], total: 1, totalPages: 1)), () async {
      expect(find.text('1 payment'), findsOneWidget);
      expect(find.text('1–1 of 1'), findsOneWidget);
    });
  });

  testWidgets('blank values are a dash, and "Paid in SF" says the payment has not synced', (t) async {
    final blank = {..._rows[4], 'payment_type': '', 'reference_number': null};
    await _run(t, MockClient((req) async => _page([blank, _rows[3]], total: 2, totalPages: 1)), () async {
      expect(find.text('—'), findsNWidgets(2));
      final tips = t.widgetList<Tooltip>(find.byType(Tooltip)).map((w) => w.message ?? '').join('|');
      expect(tips, contains('has not synced here yet'));
      expect(tips.toLowerCase(), isNot(contains('instead of adding'))); // the old, wrong explanation
      expect(tips.toLowerCase(), isNot(contains('no payment entry')));
    });
  });

  testWidgets('reduced motion: the rows and figures are simply there', (t) async {
    t.view.physicalSize = const Size(1366, 720);
    t.view.devicePixelRatio = 1;
    await http.runWithClient(() async {
      await t.pumpWidget(MediaQuery(data: const MediaQueryData(disableAnimations: true), child: _app(const PaymentsScreen())));
      await t.pump(); // the reply
      await t.pump();
      expect(find.text(r'$78,271.57'), findsOneWidget);
      final fade = t.widget<FadeTransition>(find.ancestor(of: find.text('911 Restoration'), matching: find.byType(FadeTransition)).first);
      expect(fade.opacity.value, 1);
    }, () => _mock());
    await t.pumpAndSettle();
  });

  testWidgets('the Not in Service Fusion chip is gone', (t) async {
    await _run(t, _mock(), () async {});
    expect(find.widgetWithText(ChoiceChip, 'Not in Service Fusion (2)'), findsNothing);
  });

  testWidgets('a type chip asks the server for that kind of payment', (t) async {
    final client = MockClient((req) async {
      _requests.add(req.url);
      return _page(_rows, types: true);
    });
    await _run(t, client, () async {
      await t.tap(find.widgetWithText(ChoiceChip, 'Check'));
      await t.pumpAndSettle();
      expect(_requests.last.queryParameters['type'], 'check');
      expect(_requests.last.queryParameters['page'], '1');
      await t.tap(find.text('All types'));
      await t.pumpAndSettle();
      expect(_requests.last.queryParameters.containsKey('type'), isFalse);
    });
  });

  testWidgets('an older server that cannot filter gets no filter chips', (t) async {
    await _run(t, MockClient((req) async => _page(_rows, filters: false)), () async {});
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.text('10,930 payments'), findsOneWidget);
  });

  testWidgets('first load shows a skeleton, not a blank page', (t) async {
    t.view.physicalSize = const Size(1366, 720);
    t.view.devicePixelRatio = 1;
    final reply = Completer<http.Response>();
    await http.runWithClient(() async {
      await t.pumpWidget(_app(const PaymentsScreen()));
      await t.pump();
      expect(find.byType(SkeletonPulse), findsOneWidget);
      reply.complete(_page(_rows));
      await t.pumpAndSettle();
      expect(find.byType(SkeletonPulse), findsNothing);
      expect(find.text('911 Restoration'), findsOneWidget);
    }, () => MockClient((_) => reply.future));
  });

  testWidgets('no access: says so and offers no retry', (t) async {
    await _run(t, _mock(failCode: 403), () async {});
    expect(find.text("Your account doesn't have access to payments."), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
  });

  testWidgets('a dropped connection is described in plain words', (t) async {
    await _run(t, MockClient((req) async => throw http.ClientException('Failed to fetch', req.url)), () async {});
    expect(find.text("Couldn't reach the server. Check your connection and try again."), findsOneWidget);
    expect(find.textContaining('ClientException'), findsNothing);
    expect(find.textContaining('http'), findsNothing); // never the request URL
  });

  testWidgets('Try again asks for the page that failed, with the search that was typed', (t) async {
    var failSearch = true;
    final client = MockClient((req) async {
      _requests.add(req.url);
      if (req.url.queryParameters['q'] == 'bishop' && failSearch) return http.Response('boom', 502);
      return _page(_rows);
    });
    await _run(t, client, () async {
      await _pager(t, 'Next page');
      expect(find.text('Page 2 of 219'), findsOneWidget);
      await t.enterText(find.byType(TextField), 'bishop');
      await t.pump(const Duration(milliseconds: 500));
      await t.pumpAndSettle();
      expect(find.text('Try again'), findsOneWidget);
      failSearch = false;
      await t.tap(find.text('Try again'));
      await t.pumpAndSettle();
    });
    expect(_requests.last.queryParameters['q'], 'bishop');
    expect(_requests.last.queryParameters['page'], '1'); // a new search starts on page 1, not the page left behind
  });

  testWidgets('a page past the end (the list got shorter) shows the last page, not "no payments"', (t) async {
    var pages = 3;
    final client = MockClient((req) async {
      _requests.add(req.url);
      final page = int.parse(req.url.queryParameters['page']!);
      if (page > pages) return _page(const [], total: pages * 50, totalPages: pages);
      return _page(_rows, total: pages * 50, totalPages: pages);
    });
    await _run(t, client, () async {
      await _pager(t, 'Next page');
      await _pager(t, 'Next page');
      expect(find.text('Page 3 of 3'), findsOneWidget);
      pages = 2; // Stripe payments got entered: the list is now two pages long
      await t.tap(find.byTooltip('Refresh'));
      await t.pumpAndSettle();
    });
    expect(find.text('No payments yet'), findsNothing);
    expect(find.text('Page 2 of 2'), findsOneWidget);
    expect(_requests.last.queryParameters['page'], '2');
  });

  testWidgets('amounts stay on one line in a narrow window', (t) async {
    await _run(t, _mock(), () async {}, size: const Size(800, 900));
    for (final amount in [r'$47,223.08', r'$13,680.43', r'$2,940.87']) {
      final h = t.getSize(find.text(amount)).height;
      expect(h, lessThan(26), reason: '$amount wrapped onto a second line ($h px tall)');
    }
  });

  testWidgets('a Stripe payment entered on a later day says when Service Fusion has it', (t) async {
    await _run(t, _mock(), () async {});
    // Shown on Stripe's day; the totals count it on the day Service Fusion has it.
    expect(find.text('Oct 14, 2026'), findsWidgets);
    expect(
      find.byTooltip('Paid through Stripe on Oct 14, 2026. Entered in Service Fusion on Oct 16, 2026, the day the totals count it.'),
      findsOneWidget,
    );
    // Same day in both: nothing to explain.
    expect(find.byWidgetPredicate((w) => w is Tooltip && (w.message ?? '').contains('Oct 16, 2026. Entered')), findsNothing);
  });

  testWidgets('a negative entry that is not a refund reads as an adjustment, not "Paid"', (t) async {
    await _run(t, _mock(), () async {}, size: const Size(1366, 1100)); // the rows are built as they come into view
    expect(find.text('Adjustment'), findsOneWidget);
    expect(find.text(r'-$1.47'), findsOneWidget);
  });

  testWidgets('search sends the text to the server', (t) async {
    await _run(t, _mock(), () async {
      await t.enterText(find.byType(TextField), 'bishop');
      await t.pump(const Duration(milliseconds: 500));
      await t.pumpAndSettle();
    });
    expect(_requests.last.queryParameters['q'], 'bishop');
    expect(_requests.last.queryParameters['page'], '1');
  });

  testWidgets('clicking the job number opens that job; a job that is not in the app is not a link', (t) async {
    t.view.physicalSize = const Size(1366, 1100);
    t.view.devicePixelRatio = 1;
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, _) => const PaymentsScreen()),
      GoRoute(path: '/jobs/:id', builder: (_, s) => Scaffold(body: Text('JOB PAGE ${s.pathParameters['id']}'))),
    ]);
    await http.runWithClient(() async {
      await t.pumpWidget(MaterialApp.router(routerConfig: router));
      await t.pumpAndSettle();
      expect(find.text('Oct 16, 2026'), findsWidgets); // the date column
      await t.tap(find.text('1083818562')); // not on file: plain text
      await t.pumpAndSettle();
      expect(find.text('JOB PAGE 1083818562'), findsNothing);
      await t.tap(find.text('911 Restoration')); // the row itself is not a link
      await t.pumpAndSettle();
      expect(find.text('JOB PAGE 1094424959'), findsNothing);
      await t.tap(find.text('1094424959'));
      await t.pumpAndSettle();
    }, () => _mock());
    expect(find.text('JOB PAGE 1094424959'), findsOneWidget);
  });
}
