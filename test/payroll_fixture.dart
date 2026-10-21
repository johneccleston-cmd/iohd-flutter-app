// Fake /api/payroll/commission-detail reports for the payroll screen tests, built the way payroll_detail.js builds
// the real one (lines -> share -> retainage -> net -> week gross -> \$750 hurdle -> cash pay -> totals), so the numbers
// on screen add up like real ones.

import 'dart:convert';
import 'dart:math' as math;

double _r2(double v) => (v * 100).roundToDouble() / 100;

String payrollYmd(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime payrollAddDays(DateTime d, int n) => DateTime(d.year, d.month, d.day + n);

const _customers = [
  'Ideal Structures LLC',
  'Beran Concrete Inc',
  'Trulove Construction',
  'Maria Gonzalez',
  'Lennar Homes - Cypress Creek Ranch Phase 4',
  'Robert & Linda Fitzgerald-Harrington',
  'Hill Country Self Storage',
  'Ken Wu',
  'Sunbelt Rentals #4412',
  'Pecan Grove HOA',
];

const _lineItems = [
  ('Clopay Classic Steel | 16x7 | Complete Door', 'Residential Install'),
  ('LiftMaster 8500W Wall Mount Opener', 'Opener Install'),
  ('Torsion Spring Replacement (pair)', 'Residential Service'),
  ('Commercial Rolling Steel Door 12x14', 'Commercial Install'),
  ('Service Call', 'Residential Service'),
  ('Weather Seal - Bottom Retainer', 'Residential Service'),
];

/// One closed job for one tech, shaped like payroll_detail.js buildJob().
Map<String, dynamic> _job(
  math.Random rnd,
  String id,
  DateTime closed,
  double pct, {
  bool commercial = false,
  double advancesRepaid = 0,
  double cap = 0,
  List<String> workers = const [],
}) {
  final lines = <Map<String, dynamic>>[];
  final n = 1 + rnd.nextInt(3);
  double commission = 0;
  for (var i = 0; i < n; i++) {
    final li = commercial ? _lineItems[3] : _lineItems[rnd.nextInt(_lineItems.length)];
    final amount = _r2(80 + rnd.nextDouble() * (commercial ? 1400 : 520));
    commission += amount;
    lines.add({
      'name': li.$1,
      'category': li.$2,
      'kind': 'standard',
      'jobAmount': amount,
      'techShare': _r2(amount * pct),
    });
  }
  final poolAmount = _r2(-commission * 0.01);
  lines.add({
    'name': 'Company Pool',
    'category': 'Company Pool Deduction',
    'kind': 'company_pool',
    'jobAmount': poolAmount,
    'techShare': _r2(poolAmount * pct),
  });
  final share = _r2(lines.fold<double>(0, (s, l) => s + (l['techShare'] as double)) - cap);
  final retainage = commercial ? _r2(share * 0.2) : 0.0;
  final net = _r2(share - retainage - advancesRepaid);
  final first = payrollAddDays(closed, -(1 + rnd.nextInt(3)));
  return {
    'jobId': id,
    'customer': _customers[rnd.nextInt(_customers.length)],
    'status': 'Closed',
    'closedOn': payrollYmd(closed),
    'firstWorked': payrollYmd(first),
    'lastWorked': payrollYmd(payrollAddDays(closed, -1)),
    'daysWorked': 1 + rnd.nextInt(3),
    'jobRevenue': _r2(commission * (2.6 + rnd.nextDouble())),
    'splitPct': _r2(pct * 100),
    'adjustment': -cap,
    'toCompanyPool': _r2(-poolAmount),
    'workers': workers,
    'share': share,
    'retainage': retainage,
    'advancesRepaid': advancesRepaid,
    'net': net,
    'lines': lines,
  };
}

class PayrollPerson {
  final int id;
  final String name;
  final String role;
  final bool sales;
  final bool callbackOnly;
  final int jobsPerWeek;
  final double pct;
  final bool commercial;
  final int advanceDays;
  final int callbacks;
  final double releases;
  const PayrollPerson(
    this.id,
    this.name,
    this.role, {
    this.sales = false,
    this.callbackOnly = false,
    this.jobsPerWeek = 3,
    this.pct = 0.5,
    this.commercial = false,
    this.advanceDays = 0,
    this.callbacks = 0,
    this.releases = 0,
  });
}

const payrollPeople = [
  PayrollPerson(11, 'Andrew Johnson', 'Technician', jobsPerWeek: 1, pct: 0.15, advanceDays: 2),
  PayrollPerson(12, 'Brett Miller', 'Lead Technician', jobsPerWeek: 3, pct: 0.5, commercial: true),
  PayrollPerson(13, 'Christopher Montgomery-Alexander', 'Technician', jobsPerWeek: 4, pct: 0.6, callbacks: 1),
  PayrollPerson(14, 'Daniel Baty', 'Lead Technician', jobsPerWeek: 2, pct: 1, releases: 312.5),
  PayrollPerson(15, 'Dennis Ortega', 'Warehouse Tech', callbackOnly: true, jobsPerWeek: 0, callbacks: 2),
  PayrollPerson(16, 'Nick Smith', 'Technician', jobsPerWeek: 3, pct: 0.7),
  PayrollPerson(36, 'Zac Clemens', 'Sales Rep', sales: true, jobsPerWeek: 1, pct: 0.5),
];

/// A report for [weeks] pay weeks ending on [lastSunday]. [people] defaults to the seven above; [extra] adds
/// generated people for the stress test.
String payrollReport(DateTime lastSunday, int weeks, {List<PayrollPerson> people = payrollPeople, int seed = 7}) {
  final rnd = math.Random(seed);
  final start = payrollAddDays(lastSunday, -(weeks * 7 - 1));
  var jobSeq = 1095800000;
  final techs = <Map<String, dynamic>>[];
  for (final p in people) {
    final weekList = <Map<String, dynamic>>[];
    for (var w = 0; w < weeks; w++) {
      final mon = payrollAddDays(start, w * 7);
      final sun = payrollAddDays(mon, 6);
      final jobs = <Map<String, dynamic>>[];
      for (var k = 0; k < p.jobsPerWeek; k++) {
        final commercial = p.commercial && k == 0;
        final advRepaid = p.advanceDays > 0 && k == 0 ? 20.0 : 0.0;
        final cap = p.sales && k == 0 ? 118.0 : 0.0;
        jobs.add(
          _job(
            rnd,
            '${jobSeq++}',
            payrollAddDays(mon, 1 + rnd.nextInt(5)),
            p.pct,
            commercial: commercial,
            advancesRepaid: advRepaid,
            cap: cap,
            workers: [p.name, if (p.pct < 1) 'Nick Smith'],
          ),
        );
      }
      final advances = [
        for (var a = 0; a < p.advanceDays; a++)
          {
            'jobId': '${jobSeq + 400 + a}',
            'customer': _customers[(a + 3) % _customers.length],
            'date': payrollYmd(payrollAddDays(mon, a)),
            'amount': 200.0,
          },
      ];
      final callbacks = [
        for (var c = 0; c < p.callbacks; c++)
          {
            'jobId': '${jobSeq + 800 + c}',
            'customer': _customers[(c + 5) % _customers.length],
            'date': payrollYmd(payrollAddDays(mon, 2 + c)),
            'amount': 50.0,
          },
      ];
      final reps = p.sales
          ? [
              {
                'jobId': '1098030331',
                'customer': 'Beran Concrete Inc',
                'wonOn': payrollYmd(payrollAddDays(mon, -30)),
                'closedOn': payrollYmd(payrollAddDays(mon, 2)),
                'basisLabel': 'Commercial Hard Bid',
                'labor': 18400.0,
                'ratePct': 2.0,
                'amount': 368.0,
              },
              {
                'jobId': '1096788106',
                'customer': 'Trulove Construction',
                'wonOn': payrollYmd(payrollAddDays(mon, -20)),
                'closedOn': payrollYmd(payrollAddDays(mon, 3)),
                'basisLabel': 'Assigned account',
                'labor': 6200.0,
                'ratePct': 1.0,
                'amount': 62.0,
              },
            ]
          : <Map<String, dynamic>>[];
      final jobNet = _r2(jobs.fold<double>(0, (s, j) => s + (j['net'] as double)));
      final retainage = _r2(jobs.fold<double>(0, (s, j) => s + (j['retainage'] as double)));
      final advancesPaid = _r2(advances.fold<double>(0, (s, a) => s + (a['amount'] as double)));
      final callbackPay = _r2(callbacks.fold<double>(0, (s, c) => s + (c['amount'] as double)));
      final repPay = _r2(reps.fold<double>(0, (s, r) => s + (r['amount'] as double)));
      final gross = _r2(jobNet + advancesPaid + callbackPay + repPay + retainage);
      final rule = p.sales || p.callbackOnly ? 0.0 : 750.0;
      final cash = rule == 0 ? gross : (gross >= rule ? _r2(gross - rule) : 0.0);
      final shortfall = p.advanceDays > 0 && jobNet < advancesPaid ? _r2(advancesPaid - jobNet - 40) : 0.0;
      weekList.add({
        'weekStart': payrollYmd(mon),
        'weekEnd': payrollYmd(sun),
        'jobNet': jobNet,
        'advancesPaid': advancesPaid,
        'callbackPay': callbackPay,
        'repPay': repPay,
        'otherAdjustments': 0,
        'weeklyGross': gross,
        'hurdleApplied': _r2(gross - cash),
        'hurdleRule': rule,
        'hurdleCredit': retainage,
        'cashPay': cash,
        'advanceShortfall': shortfall,
        'retainage': retainage,
        'jobs': jobs,
        'advances': advances,
        'callbacks': callbacks,
        'repCommissions': reps,
      });
    }
    double sum(String k) => _r2(weekList.fold<double>(0, (s, w) => s + ((w[k] as num?)?.toDouble() ?? 0)));
    final releases = p.releases > 0
        ? [
            {
              'jobId': '1094410022',
              'type': 'release',
              'amount': p.releases,
              'releasedOn': payrollYmd(payrollAddDays(lastSunday, -3)),
            },
            {
              'jobId': '1094410022',
              'type': 'callback_deduction',
              'amount': -50.0,
              'releasedOn': payrollYmd(payrollAddDays(lastSunday, -3)),
            },
          ]
        : <Map<String, dynamic>>[];
    final released = _r2(releases.fold<double>(0, (s, r) => s + (r['amount'] as double)));
    techs.add({
      'userId': p.id,
      'name': p.name,
      'role': p.role,
      'imageUrl': '',
      'isSales': p.sales,
      'isCallbackOnly': p.callbackOnly,
      'totals': {
        'retainage': sum('retainage'),
        'advancesPaid': sum('advancesPaid'),
        'callbackPay': sum('callbackPay'),
        'weeklyGross': sum('weeklyGross'),
        'hurdleApplied': sum('hurdleApplied'),
        'cashPay': sum('cashPay'),
        'retainageReleased': released,
        'totalDue': _r2(sum('cashPay') + released),
      },
      'weeks': weekList,
      'retainageReleases': releases,
    });
  }
  return jsonEncode({
    'success': true,
    'range': {'start': payrollYmd(start), 'end': payrollYmd(lastSunday)},
    'rules': {
      'weeklyThreshold': 750,
      'dailyAdvance': 200,
      'callbackPay': 50,
      'companyPoolRate': 0.01,
      'retainageRate': 0.2,
    },
    'techs': techs,
  });
}
