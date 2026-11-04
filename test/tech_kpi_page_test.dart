// The technician KPI page (lib/employee_kpi_tech.dart) for Andrew Johnson and Nick Smith, on production's figures of
// Oct 30, 2026 (test/tech_kpi_fixture.dart): it fits the desktop sizes without scrolling, every metric and animation
// of the page before it is still there, every figure and caption matches the records, the comparisons leave the tech
// out of the "rest of team", the year picker and Refresh ask the server again, and failures, an older server and
// missing callbacks are handled. Screenshots go to build/dash_shots/.
//   flutter test test/tech_kpi_page_test.dart

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:iohd_desktop/config/auth_session.dart';
import 'package:iohd_desktop/kpi_dashboard_screen.dart';
import 'package:iohd_desktop/widgets/dashboard_kit.dart';

import 'dashboard_fit.dart';
import 'dashboard_harness.dart';
import 'nav_fixture.dart';
import 'tech_kpi_fixture.dart';

/// Oct 30, 2026, 9:30 AM (the fixtures were computed at 9:25 and 9:28).
final _now = DateTime(2026, 10, 30, 9, 30);

/// A fake server for the technician pages. [kpisStatus] / [statsStatus] force an error ([statsStatusOf] can change
/// between requests); [kpisGate] holds the KPI answer back until it completes; [mutateKpis] changes the KPI answer
/// before it goes out; [statsFigures] / [company] replace tech_stats' callback figures.
DashFakeApi techApi({
  bool newServer = true,
  bool corrected = true,
  Map<String, List<Map<String, dynamic>>> reviews = const {},
  Map<String, ({int evals, int converted})> conversions = const {},
  Set<String> supervisors = const {},
  int Function()? kpisStatus,
  int statsStatus = 200,
  int Function()? statsStatusOf,
  Map<String, (int, int, int, int, int)>? statsFigures,
  ({int callbacks, int jobs})? company,
  Completer<void>? kpisGate,
  List<Map<String, dynamic>>? users,
  void Function(Map<String, dynamic> body)? mutateKpis,
}) {
  final api = DashFakeApi();
  api.extra.add((req) async {
    final path = req.url.path;
    if (path == '/users') return jsonResponse(users ?? usersBody());
    final kpis = RegExp(r'^/api/employees/([^/]+)/kpis$').firstMatch(path);
    if (kpis != null) {
      if (kpisGate != null) await kpisGate.future;
      final status = kpisStatus?.call() ?? 200;
      if (status != 200) return jsonResponse({'error': 'simulated'}, status);
      final who = techPeople.where((p) => p.username == Uri.decodeComponent(kpis[1]!)).firstOrNull;
      if (who == null) return jsonResponse({'success': false, 'error': 'Employee not found.'}, 404);
      final year = int.parse(req.url.queryParameters['year'] ?? '2026');
      final body = kpisBody(
        who,
        year: year,
        newServer: newServer,
        reviews: reviews[who.username],
        evalConversion: conversions[who.username] ?? (evals: 0, converted: 0),
        supervisor: supervisors.contains(who.username),
      );
      mutateKpis?.call(body);
      return jsonResponse(body);
    }
    if (path == '/api/tech_stats') {
      final status = statsStatusOf?.call() ?? statsStatus;
      if (status != 200) return jsonResponse({'error': 'simulated'}, status);
      final year = int.parse(req.url.queryParameters['year'] ?? '2026');
      return jsonResponse(techStatsBody(year: year, corrected: corrected, figures: statsFigures, company: company));
    }
    if (RegExp(r'^/api/employees/[^/]+/callbacks$').hasMatch(path)) return jsonResponse(callbacksBody(1));
    return null;
  });
  return api;
}

Widget _page(String username) => EmployeeKpiScreen(employeeId: username);

/// The rows of the team table, top to bottom (by where each name is drawn).
List<String> _tableOrder(WidgetTester t, List<String> names) {
  final y = {for (final n in names) n: t.getTopLeft(find.text(n).last).dy};
  return names.toList()..sort((a, b) => y[a]!.compareTo(y[b]!));
}

/// A review quote is cut short on purpose (a "Read" link opens it whole).
bool _isQuote(String s) => s.startsWith('“');

Finder _rich(String text) => find.textContaining(text, findRichText: true);

void main() {
  setUpAll(loadDashFonts);
  setUp(() async {
    pinDashClock(_now);
    await dashSignIn();
  });
  tearDown(unpinDashClock);

  // ---------------------------------------------------------------------------------------------------------------
  // Fits every desktop size, at 100% and 130% text, for both techs.
  // ---------------------------------------------------------------------------------------------------------------
  dashFitTests(
    'tech_kpi_andrew',
    () => _page('AndrewJohnson'),
    () => techApi(),
    mustShow: ['Labor per work day', r'$755', 'Callback rate', '4.5%', 'How Andrew compares', 'Customer reviews', 'Andrew Johnson', 'Inv. strikes'],
    mayCut: _isQuote,
  );
  dashFitTests(
    'tech_kpi_nick',
    () => _page('nsmith'),
    () => techApi(reviews: {'nsmith': reviewsFor('Nick')}),
    mustShow: ['Labor per work day', r'$2,511', 'Callback rate', '0.0%', 'How Nick compares', 'Customer reviews', 'Nick Smith', 'Inv. strikes'],
    mayCut: _isQuote,
  );
  // Six scorecards: the field supervisor's dark team callback rate, and Brett's service call conversion.
  dashFitTests(
    'tech_kpi_daniel',
    () => _page('gbaty'),
    () => techApi(supervisors: {'gbaty'}),
    mustShow: ['Team callback rate', '5.0%', 'Callback-free streak', 'How Daniel compares', 'Customer reviews', 'Daniel Baty'],
    mayCut: _isQuote,
    // The card's bars stay at every width at normal text size, the narrowest (1280) included.
    extra: (t, size, scale) async {
      if (scale == 1.0) expect(find.byWidgetPredicate((w) => w.runtimeType.toString() == '_BreakdownBars'), findsOneWidget);
    },
  );
  dashFitTests(
    'tech_kpi_brett',
    () => _page('bmiller'),
    () => techApi(conversions: {'bmiller': (evals: 14, converted: 6)}),
    mustShow: ['Service call conversion', '43%', 'Callback-free streak', 'How Brett compares', 'Customer reviews', 'Brett Miller'],
    mayCut: _isQuote,
  );

  // ---------------------------------------------------------------------------------------------------------------
  // Nothing the page showed before is gone (a rule for every KPI page)
  // ---------------------------------------------------------------------------------------------------------------
  testWidgets('every metric of the previous page is still on it', (t) async {
    await pumpDashboard(t, _page('nsmith'), api: techApi(reviews: {'nsmith': reviewsFor('Nick')}), size: const Size(1500, 800), body: () async {
      // Profile: rank, years badge, integrity score against the team average.
      expect(find.text('Rank #1'), findsOneWidget);
      expect(find.text('2 yrs'), findsOneWidget);
      expect(find.text('100%'), findsOneWidget);
      expect(find.text('Integrity · at team average'), findsOneWidget);
      // The scorecards (labor dollars, labor per day, jobs, callback rate) and the callback-free streak.
      for (final label in ['Labor billed', 'Labor per work day', 'Completed jobs worked', 'Callback rate', 'Callback-free streak']) {
        expect(find.text(label), findsWidgets, reason: label);
      }
      // The monthly chart's three metrics, and the labor per day against the rest of the team.
      for (final tab in ['Per work day', 'Labor', 'Jobs']) {
        expect(find.text(tab), findsWidgets, reason: tab);
      }
      // The chart's key, and the tag over the team table's dashed rest-of-team line.
      expect(find.text('Rest of team'), findsNWidgets(2));
      // The team comparison: labor a day, callback rate and inventory strikes against the rest of the team, in words.
      expect(_rich('How Nick compares'), findsOneWidget);
      expect(find.text('vs rest of team'), findsOneWidget);
      expect(find.text('Ahead 81%'), findsOneWidget);
      // Peer rating and morale now sit in the title bar; customer reviews, inventory strikes (a column of the team
      // table) and callback strikes (the callback rate scorecard opens them) are on the page too.
      expect(find.text('Peer rating'), findsOneWidget);
      expect(find.text('Morale'), findsOneWidget);
      expect(find.text('Customer reviews'), findsOneWidget);
      expect(find.textContaining('Inv. strikes'), findsOneWidget); // "(all time)" too where the bars keep their room
      expect(find.text('25'), findsWidgets);
      expect(find.text('0 strikes on 8 jobs since Oct 5'), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------------------------------------------------------
  // The figures, against the records
  // ---------------------------------------------------------------------------------------------------------------
  testWidgets('the integrity score says what lowers it and how many missed completions there are', (t) async {
    final errors = await pumpDashboard(t, _page('AndrewJohnson'), api: techApi(), size: const Size(1500, 800), body: () async {
      final tip = t.widget<Tooltip>(find.byWidgetPredicate((w) => w is Tooltip && (w.message ?? '').startsWith('Integrity score')));
      expect(tip.message, contains('loses points each time the office has to mark one of their visits complete'));
      expect(tip.message, contains('No missed completions this year.'));
      expect(tip.message, isNot(contains('for now')));
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets("Andrew: every figure and caption matches production's records", (t) async {
    final api = techApi();
    final errors = await pumpDashboard(t, _page('AndrewJohnson'), api: api, size: const Size(1500, 800), body: () async {
      // Labor $34,728.48 over 46 calendar days. He started in late July, so the rest of the team (Brett, Daniel, Nick)
      // is pooled over the same months, Jul–Oct: $336,499.89 over 182 days = $1,849 (all year it is $1,736).
      expect(find.text(r'$755'), findsWidgets);
      expect(find.textContaining(r'59% below rest of team'), findsOneWidget);
      expect(find.text(r'$34,728'), findsOneWidget);
      expect(find.text('Over 46 work days · Jul – today'), findsOneWidget);
      // 97 jobs, 95 with labor: $34,728.48 ÷ 95 = $366.
      expect(find.text('97'), findsOneWidget);
      expect(find.text(r'$366 average per labor job'), findsOneWidget);
      // 1 strike on the 22 jobs he did the original work on (not the 48 the old count used).
      expect(find.text('4.5%'), findsWidgets);
      expect(find.text('1 strike on 22 jobs since Oct 5'), findsOneWidget);
      expect(find.text('16'), findsOneWidget);
      expect(find.text('Jobs since the last callback'), findsOneWidget);
      // Inventory strikes: 29 (the others average 27), all time, in the team table.
      expect(find.text('29'), findsWidgets);
      expect(find.text('27 avg'), findsOneWidget);
      // The team table: everyone by labor a day, Andrew fourth, and how he stands against the rest pooled.
      expect(_rich('Ranked 4th of 4 by labor per work day'), findsOneWidget);
      expect(_tableOrder(t, ['Nick Smith', 'Daniel Baty', 'Brett Miller', 'Andrew Johnson']), ['Nick Smith', 'Daniel Baty', 'Brett Miller', 'Andrew Johnson']);
      expect(find.text(r'$2,511'), findsOneWidget);
      expect(find.text(r'$2,341'), findsOneWidget);
      expect(find.text(r'$988'), findsOneWidget);
      expect(find.text('6.3%'), findsOneWidget); // Daniel 1 ÷ 16
      expect(find.text('5.6%'), findsOneWidget); // Brett 3 ÷ 54
      // The pooled row is the page's one rest-of-team figure: the same months as Andrew, and says so.
      expect(find.text('Rest of team (3)'), findsOneWidget);
      expect(find.text('Pooled over Jul–Oct'), findsOneWidget);
      expect(find.text(r'$1,736'), findsNothing);
      expect(find.text(r'$1,849'), findsOneWidget);
      expect(find.text('182'), findsOneWidget);
      expect(find.text('5.1%'), findsOneWidget); // (3 + 1 + 0) ÷ (54 + 16 + 8)
      expect(find.text('Behind 59%'), findsOneWidget);
      // 4.5% against 5.1% is less than one strike apart (one strike on his 22 jobs is 4.5 points): on par.
      expect(find.text('On par'), findsOneWidget);
      expect(find.text('Behind'), findsOneWidget); // 29 strikes against 27
      // The verdict tiles over the table: both figures each, and the tally in words.
      expect(find.text('Behind on 2 of 3'), findsOneWidget);
      expect(find.text(r'$755 vs $1,849 · Jul–Oct'), findsOneWidget);
      expect(find.text('1 of 22 jobs vs 4 of 78'), findsOneWidget);
      expect(find.text('29 vs 27 avg · all time'), findsOneWidget);
      // No reviews: the note follows the card's title on one line (the rest of the height goes to the team table).
      expect(find.text('No Google reviews mention Andrew yet.'), findsOneWidget);
      expect(t.getCenter(find.text('No Google reviews mention Andrew yet.')).dy, closeTo(t.getCenter(find.text('Customer reviews')).dy, 1));
      // The chart's story: the year's figure, how far behind the team over the months it is pooled over (named, not to
      // be read as the Sep-vs-Aug chip beside the title), and the months in words. July (2 work days) is too short a
      // month to judge, so the full months are August and September: named with their figures, so nothing claims a
      // "best" that July's taller bar seems to contradict.
      expect(find.text('a work day so far in 2026'), findsOneWidget);
      expect(find.text(r'below the rest of the team, Jul–Oct ($1,849)'), findsOneWidget);
      expect(find.text(r'Behind the rest of the team in Aug ($1,083) and Sep ($408)'), findsOneWidget);
      // His callback rate is on par, so neither the scorecard nor his cell in the table is amber.
      for (final cell in t.widgetList<Text>(find.text('4.5%'))) {
        expect(cell.style?.color, isNot(anyOf(DashUi.amber, DashUi.amberText)));
      }
      // The scorecard's hover text says the rest of the team is the same months, and what all of 2026 is.
      expect(find.bySemanticsLabel(RegExp(r'over the same months Andrew worked \(Jul–Oct\): \$1,849 a day\. Over all of 2026 it is \$1,736\.')), findsOneWidget);
      // The rank pill is the integrity rank among everyone, and says so.
      expect(find.byWidgetPredicate((w) => w is Tooltip && (w.message ?? '').startsWith('Integrity rank: #1')), findsOneWidget);
      // One request each, for this year, by username.
      expect(api.to('/api/employees/AndrewJohnson/kpis').single.url.queryParameters['year'], '2026');
      expect(api.to('/api/tech_stats').single.url.queryParameters['year'], '2026');
      // The header: name, title, time with the company, rank and integrity, and how old the figures are.
      expect(find.text('ANDREW JOHNSON'), findsOneWidget);
      expect(find.text('Technician · 3 months at IOHD'), findsOneWidget);
      expect(find.text('Rank #1'), findsOneWidget);
      expect(find.text('Updated 5 min ago'), findsOneWidget);
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets('Nick: ahead of the rest of the team, no callbacks, his review on screen', (t) async {
    final errors = await pumpDashboard(t, _page('nsmith'), api: techApi(reviews: {'nsmith': reviewsFor('Nick')}), size: const Size(1500, 800), body: () async {
      // $271,142.06 over 108 days; the rest (Brett, Daniel, Andrew) $515,451.37 over 371 days.
      expect(find.text(r'$2,511'), findsWidgets);
      expect(find.text(r'81% above rest of team ($1,389)'), findsOneWidget);
      expect(find.text(r'$271,142'), findsOneWidget);
      expect(find.text('134'), findsOneWidget);
      expect(find.text(r'$2,169 average per labor job'), findsOneWidget);
      expect(find.text('0.0%'), findsWidgets);
      expect(find.text('0 strikes on 8 jobs since Oct 5'), findsOneWidget);
      expect(find.text('No callbacks since Oct 5'), findsOneWidget);
      expect(_rich('Ranked 1st of 4 by labor per work day'), findsOneWidget);
      expect(find.text(r'above the rest of the team ($1,389)'), findsOneWidget);
      expect(find.text('Lead Technician · 2 yrs 5 mo at IOHD'), findsOneWidget);
      expect(find.textContaining('Nick was on time'), findsOneWidget);
      expect(find.textContaining('Sample customer A.'), findsOneWidget);
      // 5 stars from 1 review.
      expect(find.text('5.0'), findsOneWidget);
      expect(find.text(' (1)'), findsOneWidget);
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets('on par within 5% either way', (t) async {
    // The rest of the team (over the same months) set 3% above Andrew's $754.97.
    void mutate(Map<String, dynamic> b) => (b['tech'] as Map)['team']['sameMonths']['laborPerDay'] = 777.62;
    await pumpDashboard(t, _page('AndrewJohnson'), api: techApi(mutateKpis: mutate), size: const Size(1500, 800), body: () async {
      expect(find.textContaining('On par with rest of team'), findsOneWidget);
      expect(find.textContaining(r'($778)'), findsOneWidget);
      expect(find.text('On par'), findsNWidgets(2)); // labor a day, and the callback rate (less than a strike apart)
    });
  });

  testWidgets('a short month taller than the best full one: the callout says "best full month"', (t) async {
    // Andrew's Jul (2 work days, $1,613 a day) stays out of the months judged; a third full month (Jun) means they are
    // counted rather than named, so the best one has to say it is the best full month.
    void mutate(Map<String, dynamic> b) {
      (b['tech']['monthly'] as List).add({'month': 6, 'jobs': 12, 'labor': 7200.0, 'laborDays': 8, 'laborPerDay': 900.0});
    }

    await pumpDashboard(t, _page('AndrewJohnson'), api: techApi(mutateKpis: mutate), size: const Size(1500, 800), body: () async {
      expect(find.text(r'Behind the rest of the team in all 3 full months · best full month: Aug, $1,083'), findsOneWidget);
    });
  });

  Set<Color?> colorsOf(WidgetTester t, String text) => {for (final w in t.widgetList<Text>(find.text(text))) w.style?.color};

  testWidgets('inventory strikes are coloured against the average, not red for every count', (t) async {
    // Everyone has 25 to 29 (all time). Andrew's 29 against the rest of the team's 27 is behind (amber, as his chip
    // says); the others read against the whole team's 27.5: Nick's 25 fewer (green), Daniel's 27 and Brett's 29 within 5%.
    await pumpDashboard(t, _page('AndrewJohnson'), api: techApi(), size: const Size(1500, 800), body: () async {
      expect(colorsOf(t, '25'), {DashUi.emeraldText});
      expect(colorsOf(t, '27'), {DashUi.ink});
      expect(colorsOf(t, '29'), {DashUi.ink, DashUi.amberText});
      expect(find.byWidgetPredicate((w) => w is Tooltip && (w.message ?? '').contains("Andrew's is green when fewer than the rest of the team's average")), findsOneWidget);
    });
  });

  testWidgets("Nick's 25 strikes read ahead, like his chip; a past year has no verdict on them", (t) async {
    await pumpDashboard(t, _page('nsmith'), api: techApi(), size: const Size(1500, 800), body: () async {
      expect(find.text('Ahead'), findsOneWidget); // 25 against the rest's 28.3
      expect(colorsOf(t, '25'), {DashUi.emeraldText});
      await t.tap(dashYearArrow('Previous year'));
      await settleDashboard(t);
      expect(find.text('Not kept by year'), findsOneWidget);
      for (final n in ['25', '27', '29']) {
        expect(colorsOf(t, n), {DashUi.ink}, reason: n);
      }
    });
  });

  testWidgets('the field supervisor also sees the whole team’s callback rate', (t) async {
    final errors = await pumpDashboard(t, _page('gbaty'), api: techApi(supervisors: {'gbaty'}), size: const Size(1500, 800), body: () async {
      expect(find.text('Team callback rate'), findsOneWidget);
      // (3 + 1 + 0 + 1) strikes on (54 + 16 + 8 + 22) jobs.
      expect(find.text('5.0%'), findsOneWidget);
      expect(find.textContaining('5 strikes on 100 jobs'), findsOneWidget);
      // The bars' key and finding in words (the hover definition and screen readers): the dashed line is the team
      // rate, and each tech's rate, highest first.
      expect(find.bySemanticsLabel(RegExp(r'dashed line is the team rate\. Daniel 6\.3%, Brett 5\.6%, Andrew 4\.5%, Nick 0\.0%\.')), findsOneWidget);
      // May ($1,358 against $1,343) is within 5%: level, not ahead.
      expect(find.text(r'Ahead of the rest of the team in 8 of 9 full months · best: Mar, $4,349'), findsOneWidget);
      // How it differs from the Technicians dashboard's company rate, with that rate quoted.
      expect(
        find.bySemanticsLabel(RegExp(r"Daniel included: 5 strikes on 100 jobs\. A job two techs worked counts once for each of them, like the "
            r"strikes\. The Technicians dashboard's company callback rate counts each callback visit once over every completed "
            r"job \(5\.3%: 5 visits on 94 jobs\), so the two differ\.")),
        findsOneWidget,
      );
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
    await saveDashShot(t, 'tech_kpi_daniel_supervisor');
  });

  testWidgets('Brett: the service call conversion scorecard (his alone, as before)', (t) async {
    final errors = await pumpDashboard(t, _page('bmiller'), api: techApi(conversions: {'bmiller': (evals: 14, converted: 6)}), size: const Size(1500, 800), body: () async {
      expect(find.text('Service call conversion'), findsOneWidget);
      expect(find.text('43%'), findsOneWidget);
      expect(find.textContaining('6 of 14'), findsOneWidget);
      await saveDashShot(t, 'tech_kpi_brett_conversion');
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets('Andrew and Nick do not get the conversion or supervisor scorecards', (t) async {
    await pumpDashboard(t, _page('nsmith'), api: techApi(conversions: {'nsmith': (evals: 3, converted: 1)}), size: const Size(1500, 800), body: () async {
      expect(find.text('Service call conversion'), findsNothing);
      expect(find.text('Team callback rate'), findsNothing);
    });
  });

  // ---------------------------------------------------------------------------------------------------------------
  // Animations and the Preview
  // ---------------------------------------------------------------------------------------------------------------
  testWidgets('the chart steps to its next view every 8 seconds, and holds while the pointer is on it', (t) async {
    await pumpDashboard(t, _page('AndrewJohnson'), api: techApi(), size: const Size(1500, 800), body: () async {
      expect(find.text('a work day so far in 2026'), findsOneWidget);
      await t.pump(const Duration(seconds: 6));
      await t.pump(const Duration(seconds: 1));
      expect(find.text('labor billed so far in 2026'), findsOneWidget);
      // Pointer on the chart: it stays put.
      final title = find.text('labor billed so far in 2026');
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: t.getCenter(title));
      await mouse.moveTo(t.getCenter(title) + const Offset(0, 120));
      await t.pump(const Duration(seconds: 9));
      expect(find.text('labor billed so far in 2026'), findsOneWidget);
      await mouse.removePointer();
      await t.pump(const Duration(seconds: 9));
      expect(find.text('jobs over 46 work days'), findsOneWidget);
      expect(find.text('per labor job'), findsOneWidget);
      expect(find.text('Work days'), findsOneWidget);
      // The new view's figures count up from zero (not down from the last view's dollars) and settle on its own.
      await t.pump(const Duration(seconds: 2));
      expect(find.text('97'), findsNWidgets(2));
      expect(find.text(r'$366'), findsOneWidget);
      await saveDashShot(t, 'tech_kpi_andrew_jobs_view');
    });
  });

  testWidgets('a view picked by hand shows at once', (t) async {
    await pumpDashboard(t, _page('nsmith'), api: techApi(), size: const Size(1500, 800), body: () async {
      await t.tap(find.text('Jobs').first);
      await settleDashboard(t, frames: 12);
      expect(find.text('jobs over 108 work days'), findsOneWidget);
    });
  });

  testWidgets('reviews rotate every 12 seconds, with a count of where you are', (t) async {
    final errors = await pumpDashboard(t, _page('nsmith'), api: techApi(reviews: {'nsmith': reviewsFor('Nick', count: 2)}), size: const Size(1500, 800), body: () async {
      expect(find.textContaining('Nick was on time'), findsOneWidget);
      await t.pump(const Duration(seconds: 12));
      await settleDashboard(t, frames: 8);
      expect(find.textContaining('Nick replaced both springs'), findsOneWidget);
      expect(find.text('2/2'), findsOneWidget);
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  Finder moraleBadge() => find.byWidgetPredicate((w) => w is Tooltip && (w.message ?? '').startsWith('Morale'));

  for (final size in const [Size(1280, 600), Size(1500, 800)]) {
    testWidgets('morale in the title bar previews sample scores, tries others, then hides (${size.width.round()}x${size.height.round()})', (t) async {
      final errors = await pumpDashboard(t, _page('AndrewJohnson'), api: techApi(), size: size, body: () async {
        await t.tap(moraleBadge());
        await settleDashboard(t, frames: 12);
        expect(find.text(' · sample'), findsOneWidget); // the sample reviews card
        expect(find.text('4.2'), findsOneWidget); // peer rating
        expect(find.text('3.6'), findsOneWidget); // morale
        if (size.width >= 1400) expect(find.text('Morale · sample'), findsOneWidget);
        await saveDashShot(t, 'tech_kpi_andrew_preview_${size.width.round()}');
        await t.tap(moraleBadge());
        await settleDashboard(t, frames: 4);
        expect(find.text('4.5'), findsOneWidget);
        for (var i = 0; i < 3; i++) {
          await t.tap(moraleBadge());
          await settleDashboard(t, frames: 4);
        }
        expect(find.text(' · sample'), findsNothing); // back to nothing recorded
        expect(find.text('4.2'), findsNothing);
      });
      expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
    });
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Filters, refresh and drill-downs
  // ---------------------------------------------------------------------------------------------------------------
  testWidgets("the year picker loads Nick's 2025 from the server, and the callback figures say tracking began later", (t) async {
    final api = techApi();
    final errors = await pumpDashboard(t, _page('nsmith'), api: api, size: const Size(1500, 800), body: () async {
      await t.tap(dashYearArrow('Previous year'));
      await settleDashboard(t);
      expect(api.to('/api/employees/nsmith/kpis').map((r) => r.url.queryParameters['year']), ['2026', '2025']);
      expect(api.to('/api/tech_stats').map((r) => r.url.queryParameters['year']), ['2026', '2025']);
      // 2025: $229,939.49 over 142 days; the rest of the team that year (Brett, Daniel) $495,618.93 over 356 days.
      expect(find.text(r'$1,619'), findsWidgets);
      expect(find.text(r'16% above rest of team ($1,392)'), findsOneWidget);
      expect(find.text('Over 142 work days · all of 2025'), findsOneWidget);
      expect(find.text('Tracking began Oct 5, 2026'), findsOneWidget);
      // The callback-free streak is a figure for today, so a past year leaves it out.
      expect(find.text('Callback-free streak'), findsNothing);
      // Inventory strikes are all time (no dates), so a past year has no verdict on them and the tally leaves them out.
      expect(find.text('Not kept by year'), findsOneWidget);
      expect(find.textContaining(RegExp(r'^25 vs [\d.]+ avg · all time$')), findsOneWidget);
      expect(find.text('Ahead on labor per work day'), findsOneWidget);
      // Nick worked every month the others did, so the rest of the team is their whole year: no months named.
      expect(find.textContaining('Jan–Dec'), findsNothing);
      await saveDashShot(t, 'tech_kpi_nick_2025');
      await t.tap(dashYearArrow('Next year'));
      await settleDashboard(t);
      expect(api.to('/api/employees/nsmith/kpis').last.url.queryParameters['year'], '2026');
      expect(find.text(r'81% above rest of team ($1,389)'), findsOneWidget);
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets("Andrew's year picker starts at his hire year (no empty years to pick)", (t) async {
    await pumpDashboard(t, _page('AndrewJohnson'), api: techApi(), size: const Size(1500, 800), body: () async {
      expect(t.widget<Semantics>(dashYearArrow('Previous year')).properties.enabled, isFalse);
    });
  });

  testWidgets('Refresh asks both sources again past their caches and keeps the figures on screen', (t) async {
    final api = techApi();
    await pumpDashboard(t, _page('AndrewJohnson'), api: api, size: const Size(1500, 800), body: () async {
      await t.tap(dashRefreshButton);
      await t.pump(const Duration(milliseconds: 10));
      expect(find.text(r'$34,728'), findsOneWidget, reason: 'figures stay while it refreshes');
      await settleDashboard(t);
      expect(api.to('/api/employees/AndrewJohnson/kpis').last.url.queryParameters['fresh'], '1');
      expect(api.to('/api/tech_stats').last.url.queryParameters['fresh'], '1');
    });
  });

  testWidgets('the callback rate opens the callback visits behind it, for the year shown', (t) async {
    final api = techApi();
    await pumpDashboard(t, _page('AndrewJohnson'), api: api, size: const Size(1500, 800), body: () async {
      await t.tap(find.text('1 strike on 22 jobs since Oct 5'));
      await settleDashboard(t, frames: 10);
      expect(find.text('Andrew Johnson · Callback strikes'), findsOneWidget);
      // Strikes count from callback tracking's start, so the list says so (not "year to date").
      expect(find.text('1 callback visit · since Oct 5, 2026, newest first'), findsOneWidget);
      expect(find.text('Sample customer 1'), findsOneWidget);
      await saveDashShot(t, 'tech_kpi_andrew_callbacks');
      expect(api.requests.where((r) => r.url.path.endsWith('/callbacks')).map((r) => r.url.queryParameters['year']), ['2026']);
    });
  });

  testWidgets('Nick has no strikes, so his callback figures have nothing to open', (t) async {
    final api = techApi();
    await pumpDashboard(t, _page('nsmith'), api: api, size: const Size(1500, 800), body: () async {
      await t.tap(find.text('0 strikes on 8 jobs since Oct 5'));
      await settleDashboard(t, frames: 5);
      expect(find.textContaining('Callback strikes'), findsNothing); // no dialog
      expect(api.requests.where((r) => r.url.path.endsWith('/callbacks')), isEmpty);
    });
  });

  testWidgets("a teammate's row opens their page; the back button returns to the list", (t) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(1500, 800);
    addTearDown(t.view.reset);
    final api = techApi();
    final router = GoRouter(
      initialLocation: '/hr/kpis/AndrewJohnson',
      routes: [
        GoRoute(path: '/hr/kpis', builder: (_, _) => const Text('KPI list'), routes: [
          GoRoute(path: ':id', builder: (_, s) => EmployeeKpiScreen(employeeId: s.pathParameters['id']!)),
        ]),
      ],
    );
    await http.runWithClient(() async {
      await t.pumpWidget(MaterialApp.router(routerConfig: router, theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true)));
      await settleDashboard(t);
      await t.tap(find.text('Nick Smith'));
      await settleDashboard(t);
      expect(router.routerDelegate.currentConfiguration.uri.path, '/hr/kpis/nsmith');
      expect(find.text('NICK SMITH'), findsOneWidget);
      expect(find.text(r'81% above rest of team ($1,389)'), findsOneWidget);
      await t.tap(find.byTooltip('All employees'));
      await settleDashboard(t, frames: 5);
      expect(find.text('KPI list'), findsOneWidget);
    }, api.client);
  });

  testWidgets("a teammate's row opens their page on the same year", (t) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(1500, 800);
    addTearDown(t.view.reset);
    final api = techApi();
    final router = GoRouter(
      initialLocation: '/hr/kpis/nsmith',
      routes: [
        GoRoute(path: '/hr/kpis', builder: (_, _) => const Text('KPI list'), routes: [
          GoRoute(path: ':id', builder: (_, s) => EmployeeKpiScreen(employeeId: s.pathParameters['id']!)),
        ]),
      ],
    );
    await http.runWithClient(() async {
      await t.pumpWidget(MaterialApp.router(routerConfig: router, theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true)));
      await settleDashboard(t);
      await t.tap(dashYearArrow('Previous year'));
      await settleDashboard(t);
      await t.tap(find.text('Daniel Baty'));
      await settleDashboard(t);
      final uri = router.routerDelegate.currentConfiguration.uri;
      expect(uri.path, '/hr/kpis/gbaty');
      expect(uri.queryParameters['year'], '2025');
      expect(find.text('DANIEL BATY'), findsOneWidget);
      expect(api.to('/api/employees/gbaty/kpis').map((r) => r.url.queryParameters['year']), ['2025']);
      expect(find.text('2025'), findsWidgets);
    }, api.client);
  });

  testWidgets('the team table ranks only techs with 10+ work days, and equal figures share a place', (t) async {
    void mutate(Map<String, dynamic> body) {
      final members = ((body['tech'] as Map)['teamMembers'] as List).cast<Map>();
      final nick = members.firstWhere((m) => m['username'] == 'nsmith');
      // Daniel level with Nick (as shown, to the dollar); Brett on only 6 work days.
      members.firstWhere((m) => m['username'] == 'gbaty')['laborPerDay'] = (nick['laborPerDay'] as num) + 0.2;
      members.firstWhere((m) => m['username'] == 'bmiller')['laborDays'] = 6;
    }

    await pumpDashboard(t, _page('AndrewJohnson'), api: techApi(mutateKpis: mutate), size: const Size(1500, 800), body: () async {
      expect(_tableOrder(t, ['Nick Smith', 'Daniel Baty', 'Brett Miller', 'Andrew Johnson']), ['Daniel Baty', 'Nick Smith', 'Andrew Johnson', 'Brett Miller']);
      expect(_rich('Ranked 3rd of 3 by labor per work day'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Number 1\. Daniel Baty')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Number 1\. Nick Smith')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Number 3\. Andrew Johnson')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Brett Miller: ')), findsOneWidget, reason: 'unranked: no number');
    });
  });

  testWidgets('a tech under 10 work days is listed last, not ranked', (t) async {
    void mutate(Map<String, dynamic> body) {
      final members = ((body['tech'] as Map)['teamMembers'] as List).cast<Map>();
      members.firstWhere((m) => m['username'] == 'AndrewJohnson')['laborDays'] = 8;
    }

    await pumpDashboard(t, _page('AndrewJohnson'), api: techApi(mutateKpis: mutate), size: const Size(1500, 800), body: () async {
      expect(_rich('Not ranked: under 10 work days'), findsOneWidget);
      expect(_tableOrder(t, ['Nick Smith', 'Daniel Baty', 'Brett Miller', 'Andrew Johnson']), ['Nick Smith', 'Daniel Baty', 'Brett Miller', 'Andrew Johnson']);
    });
  });

  testWidgets("production's Nov 2 callbacks: one strike apart is on par, and a shared highest rate names everyone on it", (t) async {
    final api = techApi(supervisors: {'gbaty'}, statsFigures: techStatsNov2, company: (callbacks: 9, jobs: 156));
    // One column, so the team rate's fullest caption (with the finding) has room.
    await pumpDashboard(t, _page('gbaty'), api: api, size: const Size(520, 1400), body: () async {
      // Daniel 2 of 18 (11.1%) against the rest's 6 of 100 (6.0%): 5.1 points, under one strike on 18 jobs (5.6).
      expect(find.text('2 of 18 jobs vs 6 of 100'), findsOneWidget);
      expect(find.text('On par'), findsWidgets);
      // The team: 8 strikes on 118 jobs (6.8%); Nick's 1 of 9 is also 11.1%, so both are "Most".
      expect(find.text('6.8%'), findsWidgets);
      expect(find.textContaining('Highest: Nick, Daniel 11.1%'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'\(5\.8%: 9 visits on 156 jobs\), so the two differ')), findsOneWidget);
    });
  });

  testWidgets('opening a KPI page directly: the KPI list built under it (never laid out) throws nothing', (t) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(1366, 768);
    addTearDown(t.view.reset);
    final router = GoRouter(
      initialLocation: '/hr/kpis/nsmith',
      routes: [
        GoRoute(path: '/hr/kpis', builder: (_, _) => const KPIDashboardScreen(), routes: [
          GoRoute(path: ':id', builder: (_, s) => EmployeeKpiScreen(employeeId: s.pathParameters['id']!)),
        ]),
      ],
    );
    await http.runWithClient(() async {
      await t.pumpWidget(MaterialApp.router(routerConfig: router, theme: ThemeData(fontFamily: 'Segoe UI', useMaterial3: true)));
      await settleDashboard(t);
      // The list reads its scroll extent for "1–4 of 9"; while the KPI page covers it there is none (it was a null check).
      expect(t.takeException(), isNull);
      expect(find.text('NICK SMITH'), findsOneWidget);
      await t.tap(find.byTooltip('All employees'));
      await settleDashboard(t);
      expect(t.takeException(), isNull);
      expect(find.text('TEAM KPIS'), findsOneWidget);
    }, techApi().client);
  });

  // ---------------------------------------------------------------------------------------------------------------
  // Loading, failures, an older server
  // ---------------------------------------------------------------------------------------------------------------
  testWidgets('a skeleton while the figures load, then the page', (t) async {
    final gate = Completer<void>();
    await pumpDashboard(t, _page('AndrewJohnson'), api: techApi(kpisGate: gate), size: const Size(1280, 600), body: () async {
      expect(find.bySemanticsLabel('Loading figures'), findsOneWidget);
      await saveDashShot(t, 'tech_kpi_loading');
      gate.complete();
      await settleDashboard(t);
      expect(find.bySemanticsLabel('Loading figures'), findsNothing);
      expect(find.text(r'$34,728'), findsOneWidget);
    });
  });

  testWidgets('a failed load says so in words, with Try again that works', (t) async {
    var status = 500;
    final api = techApi(kpisStatus: () => status);
    await pumpDashboard(t, _page('AndrewJohnson'), api: api, size: const Size(1280, 600), body: () async {
      expect(find.text("Couldn't load Andrew's figures"), findsOneWidget);
      expect(find.textContaining('error 500'), findsOneWidget);
      await saveDashShot(t, 'tech_kpi_error');
      status = 200;
      await t.tap(find.text('Try again'));
      await settleDashboard(t);
      expect(find.text(r'$34,728'), findsOneWidget);
    });
  });

  testWidgets('without the callback source the page still loads and says so', (t) async {
    final errors = await pumpDashboard(t, _page('AndrewJohnson'), api: techApi(statsStatus: 500), size: const Size(1280, 600), body: () async {
      expect(find.text(r'$34,728'), findsOneWidget);
      // The callback rate and the streak say so.
      expect(find.text("Couldn't load callbacks"), findsNWidgets(2));
      await saveDashShot(t, 'tech_kpi_no_callbacks');
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets("the supervisor's team callback rate says it couldn't load (not that tracking began later)", (t) async {
    await pumpDashboard(t, _page('gbaty'), api: techApi(supervisors: {'gbaty'}, statsStatus: 500), size: const Size(1500, 800), body: () async {
      expect(find.text('Team callback rate'), findsOneWidget);
      expect(find.text('Tracking began Oct 5, 2026'), findsNothing);
      expect(find.text("Couldn't load callbacks"), findsNWidgets(3)); // the rate, the streak and the team's rate
      // The comparison names it rather than leaving a blank (and leaves it out of the tally).
      expect(find.text("Couldn't load"), findsOneWidget);
      expect(find.text('Refresh to try again'), findsOneWidget);
    });
  });

  testWidgets('a Refresh whose callbacks fail keeps the last ones on screen and says the refresh failed', (t) async {
    var stats = 200;
    final api = techApi(statsStatusOf: () => stats);
    await pumpDashboard(t, _page('AndrewJohnson'), api: api, size: const Size(1500, 800), body: () async {
      expect(find.text('1 strike on 22 jobs since Oct 5'), findsOneWidget);
      stats = 500;
      await t.tap(dashRefreshButton);
      await settleDashboard(t);
      expect(api.to('/api/tech_stats').length, 2);
      expect(find.text('1 strike on 22 jobs since Oct 5'), findsOneWidget, reason: 'the last callback figures stay');
      expect(find.text("Couldn't load callbacks"), findsNothing);
      expect(find.textContaining("Couldn't refresh"), findsWidgets);
    });
  });

  testWidgets('a signed-out answer signs out', (t) async {
    await pumpDashboard(t, _page('AndrewJohnson'), api: techApi(kpisStatus: () => 401), size: const Size(1280, 600), body: () async {
      expect(AuthSession.instance.isLoggedIn, isFalse);
      expect(find.text('Your session ended'), findsOneWidget);
    });
  });

  testWidgets('an older server: work days worked out from the months, the team as one pooled row', (t) async {
    final errors = await pumpDashboard(t, _page('AndrewJohnson'), api: techApi(newServer: false, corrected: false), size: const Size(1500, 800), body: () async {
      expect(find.text('Over 46 work days · Jul – today'), findsOneWidget);
      expect(find.text('Rest of team (3)'), findsOneWidget);
      // That server sends only the rest of the team's whole year: the figure stays, and the hover text says so.
      expect(find.text(r'$1,736'), findsWidgets);
      expect(find.bySemanticsLabel(RegExp(r"over all of 2026: \$1,736 a day\. Andrew worked only Jul–Oct, and this server can't pool")), findsOneWidget);
      expect(find.text('Andrew'), findsWidgets);
      expect(find.text('27 avg'), findsOneWidget);
      expect(_rich('against the rest of the team'), findsOneWidget);
      // That server still counts callback-only and zero-weight visits: 1 ÷ 48. The page shows what it is given.
      expect(find.text('1 strike on 48 jobs since Oct 5'), findsOneWidget);
      await saveDashShot(t, 'tech_kpi_andrew_old_server');
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets('a tech with no work in the year: dashes and plain empty states, not zeros', (t) async {
    final users = usersBody()..[0] = {...usersBody()[0], 'yearsWorked': 1.4};
    final errors = await pumpDashboard(t, _page('AndrewJohnson'), api: techApi(users: users), size: const Size(1500, 800), body: () async {
      await t.tap(dashYearArrow('Previous year'));
      await settleDashboard(t);
      expect(find.text('No labor jobs in 2025'), findsWidgets);
      expect(find.text('Andrew has no completed labor jobs in 2025.'), findsOneWidget);
      // None of his months to pool over, so the pooled row is the rest of the team's whole year, not "— over 0 days":
      // $725,558.42 over 498 days (Nick 142, Brett 196, Daniel 160).
      expect(find.text(r'$1,457'), findsOneWidget);
      expect(find.text('498'), findsOneWidget);
      // No trend lines along zero on the scorecards.
      expect(find.byWidgetPredicate((w) => w.runtimeType.toString() == '_Spark'), findsNothing);
      await saveDashShot(t, 'tech_kpi_andrew_empty_year');
    });
    expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
  });

  testWidgets('reduced motion: final figures at once, nothing left animating', (t) async {
    await pumpDashboard(t, _page('nsmith'), api: techApi(reviews: {'nsmith': reviewsFor('Nick', count: 2)}), size: const Size(1280, 600), reduceMotion: true, body: () async {
      expect(find.text(r'$2,511'), findsWidgets);
      expect(t.binding.hasScheduledFrame, isFalse, reason: 'the flame, the heartbeat, the reviews and the scorecards hold still');
    });
  });

  testWidgets('a "Warehouse Technician" by title whose role is warehouse gets the warehouse page, not the technician one', (t) async {
    final users = [
      ...usersBody(),
      {'id': 'dgray', 'name': 'Dennis Gray', 'role': 'warehouse', 'job_title': 'Warehouse Technician', 'integrity_score': 90.0, 'years_worked': 2.0, 'avatar_url': ''},
    ];
    final api = techApi(users: users);
    await pumpDashboard(t, _page('dgray'), api: api, size: const Size(1500, 800), body: () async {
      expect(_rich('How Dennis compares'), findsNothing);
      expect(api.to('/api/tech_stats'), isEmpty, reason: 'the technician page was never built');
      expect(find.text('DENNIS GRAY'), findsOneWidget); // the warehouse page's title bar
    });
  });

  testWidgets("no photo is fetched from a third-party avatar service with the person's name", (t) async {
    final users = [
      for (final u in usersBody()) {...u, 'avatarUrl': 'https://ui-avatars.com/api/?name=${Uri.encodeComponent(u['name'] as String)}'},
    ];
    await pumpDashboard(t, _page('AndrewJohnson'), api: techApi(users: users), size: const Size(1500, 800), body: () async {
      expect(dashNetworkImageUrls(t).where((u) => u.contains('ui-avatars')), isEmpty);
    });
  });

  // ---------------------------------------------------------------------------------------------------------------
  // Narrow windows scroll in one column, like the dashboards
  // ---------------------------------------------------------------------------------------------------------------
  for (final size in const [Size(1000, 700), Size(800, 900)]) {
    testWidgets('below desktop width: one scrolling column (${size.width.round()}x${size.height.round()})', (t) async {
      final errors = await pumpDashboard(t, _page('nsmith'), api: techApi(reviews: {'nsmith': reviewsFor('Nick', count: 2)}), size: size, body: () async {
        await saveDashShot(t, 'tech_kpi_nick_${size.width.round()}x${size.height.round()}');
      });
      expect(errors.overflowed, isFalse, reason: errors.messages.join('\n'));
    });
  }

  // ---------------------------------------------------------------------------------------------------------------
  // The photo breaks out of the ribbon, over the navigation bar, in the real app shell
  // ---------------------------------------------------------------------------------------------------------------
  group('the title-bar photo in the app shell', () {
    setUpAll(loadNavFonts);
    setUp(() => navStubPage = (path) => path.startsWith('/hr/kpis/') ? _page(path.split('/').last) : const SizedBox());
    tearDown(() => navStubPage = null);

    final shot = GlobalKey();
    Finder photo() => find.byWidgetPredicate((w) => w is DashAvatar && w.size > 60);
    // The whole coin (ring and all), as drawn where it follows the title bar.
    Finder coin() => find.descendant(of: find.byType(CompositedTransformFollower), matching: find.byType(SizedBox)).first;
    Rect ribbon(WidgetTester t) => t.getRect(find.ancestor(of: find.text('ANDREW JOHNSON'), matching: find.byType(SafeArea)).first);

    Future<GoRouter> pumpShell(WidgetTester t, Size size) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = size;
      addTearDown(t.view.reset);
      final router = navTestRouter(initial: '/hr/kpis/AndrewJohnson');
      await t.pumpWidget(RepaintBoundary(
        key: shot,
        child: MaterialApp.router(debugShowCheckedModeBanner: false, routerConfig: router, theme: navTestTheme()),
      ));
      await settleDashboard(t);
      return router;
    }

    Future<void> save(WidgetTester t, String name) => t.runAsync(() async {
          final image = await (shot.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          File('build/dash_shots/$name.png')
            ..createSync(recursive: true)
            ..writeAsBytesSync(bytes!.buffer.asUint8List());
        });

    for (final size in const [Size(1280, 720), Size(1500, 800), Size(1920, 940)]) {
      testWidgets('sits on the ribbon, over the bottom of the nav bar and the top of the page (${size.width.round()})', (t) async {
        await http.runWithClient(() async {
          await pumpShell(t, size);
          await save(t, 'kpi_photo_shell_${size.width.round()}x${size.height.round()}');
          final bar = t.getRect(find.descendant(of: navShell, matching: find.byType(PreferredSize)).first);
          final band = ribbon(t);
          final pic = t.getRect(coin());
          expect(band.top, bar.bottom, reason: 'the ribbon starts right under the nav bar, as on every page');
          expect(pic.center.dy, closeTo(band.center.dy, 0.5));
          expect(pic.top, lessThan(band.top - 8), reason: 'rises over the nav bar');
          expect(pic.bottom, greaterThan(band.bottom + 8), reason: 'hangs over the page');
          // The app's text style, not the bare one text gets outside a Material.
          final initials = find.descendant(of: photo(), matching: find.text('AJ'));
          expect(DefaultTextStyle.of(t.element(initials)).style.fontFamily, 'Segoe UI');
          // Clicks go through it to the nav bar and the page.
          final result = HitTestResult();
          t.binding.hitTestInView(result, Offset(pic.center.dx, bar.bottom - 3), t.view.viewId);
          final navBox = t.renderObject(find.descendant(of: navShell, matching: find.byType(PreferredSize)).first);
          expect(result.path.any((e) => e.target == navBox), isTrue);
        }, techApi().client);
      });
    }

    testWidgets('is drawn only while the page is on screen', (t) async {
      await http.runWithClient(() async {
        final router = await pumpShell(t, const Size(1500, 800));
        expect(photo(), findsOneWidget);
        router.go('/calendar');
        await settleDashboard(t, frames: 10);
        expect(photo(), findsNothing);
        router.go('/hr/kpis/AndrewJohnson');
        await settleDashboard(t);
        expect(photo(), findsOneWidget);
        router.go('/hr/kpis');
        await settleDashboard(t, frames: 10);
        expect(photo(), findsNothing);
      }, techApi().client);
    });
  });
}
