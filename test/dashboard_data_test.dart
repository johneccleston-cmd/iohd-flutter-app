// Unit tests for the dashboards' shared data rules (lib/widgets/dashboard_data.dart, dashTrend in dashboard_kit.dart):
// reporting periods, month-over-month comparisons, and how a request turns into data or a typed failure.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/config/auth_session.dart';
import 'package:iohd_desktop/widgets/dashboard_data.dart';
import 'package:iohd_desktop/widgets/dashboard_kit.dart';

import 'dashboard_harness.dart';

final _twelve = [for (var i = 1; i <= 12; i++) i * 10.0];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => pinDashClock());
  tearDown(unpinDashClock);

  group('reporting periods (pinned to Oct 22, 2026)', () {
    test('a past year has 12 finished months, a future year none, this year up to last month', () {
      expect(dashCompleteMonths(2025), 12);
      expect(dashCompleteMonths(2027), 0);
      expect(dashCompleteMonths(2026), 9); // Jan..Sep; October is still running
    });

    test('period labels say which stretch of the year a figure covers', () {
      expect(dashPeriodLabel(2026), 'Jan 1 – today');
      expect(dashPeriodLabel(2025), 'all of 2025');
      expect(dashPeriodLabel(2027), '2027 (not started)');
    });

    test('on Jan 1 nothing in the new year is finished yet', () {
      pinDashClock(DateTime(2027, 1, 1, 9));
      expect(dashCompleteMonths(2027), 0);
      expect(dashCompleteMonths(2026), 12);
      expect(dashMonthChange(_twelve, 2027), isNull);
    });
  });

  group('month-over-month change', () {
    test('compares the last two finished months, never the month in progress', () {
      final c = dashMonthChange(_twelve, 2026)!;
      expect(c.label, 'Sep vs Aug');
      expect(c.pct, closeTo((90 - 80) / 80 * 100, 1e-9));
    });

    test('a partial month that looks like a collapse is not compared', () {
      // Jobs-style data: September 157 completed, October 8 so far.
      final monthly = <double>[159.0, 131, 159, 168, 183, 196, 178, 167, 157, 8, 0, 0];
      final c = dashMonthChange(monthly, 2026)!;
      expect(c.label, 'Sep vs Aug');
      expect(c.pct, closeTo((157 - 167) / 167 * 100, 1e-9));
    });

    test('a finished year compares December with November', () {
      expect(dashMonthChange(_twelve, 2025)!.label, 'Dec vs Nov');
    });

    test('nothing to compare against when the earlier month is zero', () {
      final monthly = <double>[0.0, 0, 0, 0, 0, 0, 0, 0, 0, 1413.66, 0, 0]; // commissions: only October has payouts
      expect(dashMonthChange(monthly, 2026), isNull);
      expect(dashMonthChange(<double>[0, 0, 0, 0, 0, 0, 0, 0, 5, 0, 0, 0], 2026), isNull); // Sep vs Aug(0)
    });

    test('the two months are always next to each other (a zero month is a real zero, not skipped)', () {
      final monthly = <double>[10.0, 10, 10, 10, 10, 10, 10, 50, 0, 0, 0, 0];
      final c = dashMonthChange(monthly, 2026)!;
      expect(c.label, 'Sep vs Aug');
      expect(c.pct, -100);
    });

    test('short series (a chart that only has the months so far) still line up by month', () {
      final c = dashMonthChange(<double>[1, 2, 3, 4, 5, 6, 7, 8, 9, 1], 2026)!; // Jan..Oct
      expect(c.label, 'Sep vs Aug');
    });
  });

  group('scorecard trend lines', () {
    test('this year stops at the last finished month', () {
      expect(dashTrend(_twelve, 2026), _twelve.take(9).toList());
    });

    test('a past year uses all twelve months', () {
      expect(dashTrend(_twelve, 2025), _twelve);
    });

    test('a leading run of zeros is trimmed to one month before the first value', () {
      final monthly = <double>[0.0, 0, 0, 0, 0, 5, 6, 7, 8, 9, 0, 0];
      expect(dashTrend(monthly, 2026), [0, 5, 6, 7, 8]);
    });

    test('fewer than two points means no line', () {
      pinDashClock(DateTime(2026, 2, 3));
      expect(dashTrend(_twelve, 2026), isNull); // only January is finished
    });

    test('a series the caller already cut short is left as it is', () {
      // The KPI warehouse page passes year 0 with only finished months; that keeps working.
      expect(dashTrend(<double>[3, 4, 5], 0), [3, 4, 5]);
    });
  });

  group('DashRequests', () {
    setUp(() async => dashSignIn());

    Future<T> withApi<T>(Future<T> Function() body, Future<http.Response> Function(http.Request) handler) =>
        http.runWithClient(body, () => MockClient(handler));

    test('200: the body, and when the server computed it', () async {
      final r = DashRequests();
      final p = await withApi(
        () => r.get('/api/dashboards/sales', query: {'year': '2026'}),
        (req) async => http.Response(json.encode({'wonValue': 1, 'generatedAt': '2026-10-22T19:30:00.000Z'}), 200),
      );
      expect(p!.body['wonValue'], 1);
      expect(p.generatedAt, DateTime.parse('2026-10-22T19:30:00.000Z').toLocal());
      expect(p.receivedAt, kDashNow);
    });

    test('sends the user token and, for a refresh, fresh=1', () async {
      http.Request? seen;
      await withApi(
        () => DashRequests().get('/api/dashboards/sales', query: {'year': '2026'}, fresh: true),
        (req) async {
          seen = req;
          return http.Response('{}', 200);
        },
      );
      expect(seen!.url.queryParameters, {'year': '2026', 'fresh': '1'});
      expect(seen!.headers['x-user-token'], isNotEmpty);
    });

    test('a server that does not say when it computed the figures: generatedAt is null', () async {
      final p = await withApi(() => DashRequests().get('/x'), (_) async => http.Response('{}', 200));
      expect(p!.generatedAt, isNull);
    });

    test('401 signs the person out', () async {
      expect(AuthSession.instance.isLoggedIn, isTrue);
      await expectLater(
        withApi(() => DashRequests().get('/x'), (_) async => http.Response('{"error":"Session expired"}', 401)),
        throwsA(isA<DashLoadException>().having((e) => e.kind, 'kind', DashFailure.signedOut)),
      );
      expect(AuthSession.instance.isLoggedIn, isFalse);
    });

    test('403 is "no access": the session stays, and retrying is not offered', () async {
      try {
        await withApi(() => DashRequests().get('/x'), (_) async => http.Response('{"error":"no"}', 403));
        fail('expected a failure');
      } on DashLoadException catch (e) {
        expect(e.kind, DashFailure.noAccess);
        expect(e.canRetry, isFalse);
      }
      expect(AuthSession.instance.isLoggedIn, isTrue);
    });

    test('500 is a server failure with its status, and can be retried', () async {
      try {
        await withApi(() => DashRequests().get('/x'), (_) async => http.Response('boom', 500));
        fail('expected a failure');
      } on DashLoadException catch (e) {
        expect(e.kind, DashFailure.server);
        expect(e.status, 500);
        expect(e.canRetry, isTrue);
        expect(e.message, contains('500'));
      }
    });

    test('an answer that is not a JSON object is bad data', () async {
      for (final body in ['<html>', '[1,2]', '"text"']) {
        await expectLater(
          withApi(() => DashRequests().get('/x'), (_) async => http.Response(body, 200)),
          throwsA(isA<DashLoadException>().having((e) => e.kind, 'kind', DashFailure.badData)),
        );
      }
    });

    test('no answer within the timeout', () async {
      await expectLater(
        withApi(
          () => DashRequests(timeout: const Duration(milliseconds: 30)).get('/x'),
          (_) async {
            await Future<void>.delayed(const Duration(milliseconds: 300));
            return http.Response('{}', 200);
          },
        ),
        throwsA(isA<DashLoadException>().having((e) => e.kind, 'kind', DashFailure.timeout)),
      );
    });

    test('no connection', () async {
      await expectLater(
        withApi(() => DashRequests().get('/x'), (_) async => throw http.ClientException('connection refused')),
        throwsA(isA<DashLoadException>().having((e) => e.kind, 'kind', DashFailure.offline)),
      );
    });

    test('an older request that answers late is ignored; the newest one wins', () async {
      final r = DashRequests();
      final slow = Completer<http.Response>();
      final results = await withApi(() async {
        final first = r.get('/api/dashboards/sales', query: {'year': '2026'});
        final second = r.get('/api/dashboards/sales', query: {'year': '2025'});
        final b = await second;
        slow.complete(http.Response(json.encode({'year': 2026}), 200));
        final a = await first;
        return (a, b);
      }, (req) => req.url.queryParameters['year'] == '2026' ? slow.future : Future.value(http.Response(json.encode({'year': 2025}), 200)));
      expect(results.$1, isNull, reason: 'the 2026 answer arrived after the 2025 request and must not be used');
      expect(results.$2!.body['year'], 2025);
    });

    test('an older request that FAILS late is ignored too (no stale error over good data)', () async {
      final r = DashRequests();
      final slow = Completer<http.Response>();
      final results = await withApi(() async {
        final first = r.get('/x', query: {'n': '1'});
        final second = r.get('/x', query: {'n': '2'});
        final b = await second;
        slow.complete(http.Response('boom', 500));
        final a = await first;
        return (a, b);
      }, (req) => req.url.queryParameters['n'] == '1' ? slow.future : Future.value(http.Response('{"ok":true}', 200)));
      expect(results.$1, isNull);
      expect(results.$2!.body['ok'], isTrue);
    });

    test('cancel() makes everything in flight resolve to null (a screen that closed)', () async {
      final r = DashRequests();
      final slow = Completer<http.Response>();
      final result = await withApi(() async {
        final pending = r.get('/x');
        r.cancel();
        slow.complete(http.Response('{}', 200));
        return pending;
      }, (_) => slow.future);
      expect(result, isNull);
    });
  });
}
