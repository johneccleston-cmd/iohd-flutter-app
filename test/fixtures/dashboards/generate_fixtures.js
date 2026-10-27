// Generates test/fixtures/dashboards/*.json: synthetic, scrubbed dashboard responses shaped exactly like the backend's,
// with every total consistent with the series it summarizes. "Now" is 2026-10-22 (October is the month in progress).
// Run from the repo root: node test/fixtures/dashboards/generate_fixtures.js test/fixtures/dashboards
const fs = require('fs');
const path = require('path');
const out = process.argv[2];
fs.mkdirSync(out, { recursive: true });

const GENERATED_AT = '2026-10-22T19:30:00.000Z'; // 2:30 PM in Chicago
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const ELAPSED = 10; // Jan..Oct have data
const DAY_OF_YEAR = 295; // Oct 22, 2026
const sum = (a) => a.reduce((t, v) => t + v, 0);
const r2 = (v) => Math.round(v * 100) / 100;
const usd0 = (n) => (n < 0 ? '-' : '') + '$' + Math.round(Math.abs(n)).toLocaleString('en-US');
const write = (name, body) => fs.writeFileSync(path.join(out, `${name}.json`), JSON.stringify(body, null, 2) + '\n');

// Made-up people and customers. None of these are real staff or customers.
const TECHS = ['Alex Rivera', 'Sam Carter', 'Jordan Lee', 'Casey Morgan'];
const CUSTOMERS = ['Northwind Homes LLC', 'Summit Builders', 'Lakeside Residence', 'Oakridge Property Co', 'Pine Hollow Apartments', 'Cedar Point Storage'];

// ─── Financial (/api/financial_dashboard) ───────────────────────────────────────────────────────────────────────
{
  const rev = [182400, 171250, 246310, 268920, 290115, 301480, 274660, 288905, 247730, 49640];
  const margin = [0.41, 0.38, 0.4, 0.42, 0.39, 0.4, 0.43, 0.41, 0.4, 0.37];
  const profit = rev.map((v, i) => Math.round(v * margin[i]));
  const expense = [96400, 88210, 99870, 101330, 97650, 104220, 99180, 102560, 98340, 41380];
  const completed = sum(rev);
  const deposits = 245000;
  const revenueYtd = completed + deposits;
  const segments = { high: Math.round(revenueYtd * 0.18), com: Math.round(revenueYtd * 0.36), res: Math.round(revenueYtd * 0.41) };
  segments.other = revenueYtd - segments.high - segments.com - segments.res;
  const expCats = [['Payroll (office)', 0.38], ['Vehicles & fuel', 0.17], ['Rent & utilities', 0.12], ['Insurance', 0.11], ['Marketing', 0.09], ['Software', 0.05], ['Tools & equipment', 0.05], ['Uncategorized', 0.03]];
  const totalExp = sum(expense);
  const cats = expCats.map(([c, s]) => ({ category: c, amount: Math.round(totalExp * s) }));
  cats[cats.length - 1].amount += totalExp - sum(cats.map((c) => c.amount)); // categories add up to the monthly total exactly
  const body = (empty) => ({
    revenueYtd: usd0(empty ? 0 : revenueYtd),
    depositsYtd: empty ? 0 : deposits,
    outstandingMoney: usd0(empty ? 0 : 359120),
    grossProfitYtd: usd0(empty ? 0 : sum(profit)),
    yearlyProjected: usd0(empty ? 0 : revenueYtd / (DAY_OF_YEAR / 365)),
    companyPool: usd0(empty ? 0 : 17),
    commercialPool: usd0(empty ? 0 : 250),
    history: empty ? { outstanding: [], projected: [] } : {
      outstanding: Array.from({ length: 17 }, (_, i) => 351000 + i * 480),
      projected: Array.from({ length: 17 }, (_, i) => 3620000 + i * 1500),
    },
    highVolumeRevenue: empty ? 0 : segments.high,
    commercialRevenue: empty ? 0 : segments.com,
    residentialRevenue: empty ? 0 : segments.res,
    otherRevenue: empty ? 0 : segments.other,
    operatingExpenses: empty ? [] : cats.sort((a, b) => b.amount - a.amount),
    chartData: MONTHS.map((m, i) => {
      const has = !empty && i < ELAPSED;
      const p = has ? profit[i] : 0;
      const e = has ? expense[i] : 0;
      return { month: m, revenue: has ? rev[i] : 0, profit: p, marginPct: has ? r2(p / rev[i] * 100) : 0, expense: e, netIncome: p - e, hasData: has };
    }),
    generatedAt: GENERATED_AT,
  });
  write('financial', body(false));
  write('financial_empty', body(true));
}

// ─── Commissions (/api/commissions_stats) ───────────────────────────────────────────────────────────────────────
{
  // Commissions started Oct 5, 2026, so only October has payouts. The last person is a sales-role install tech
  // with real pool pay: on the job pool (onPool), so his pay shows and he counts in the average per recipient, but
  // in a sales role (isSales), so he is not on the hurdle meters.
  const people = [
    { id: 'alex.rivera', name: 'Alex Rivera', jobTitle: 'Lead Technician', isSales: false, onPool: true, ytdCommission: 2410, lockedBalance: 0, strikes: 0, totalPenalties: 0, weekGross: 781.74, hurdleStreak: 2, hurdleWeeksHit: 2 },
    { id: 'sam.carter', name: 'Sam Carter', jobTitle: 'Technician', isSales: false, onPool: true, ytdCommission: 1250, lockedBalance: 116.35, strikes: 1, totalPenalties: 50, weekGross: 520, hurdleStreak: 1, hurdleWeeksHit: 1 },
    { id: 'jordan.lee', name: 'Jordan Lee', jobTitle: 'Technician', isSales: false, onPool: true, ytdCommission: 650, lockedBalance: 0, strikes: 0, totalPenalties: 0, weekGross: 210.5, hurdleStreak: 0, hurdleWeeksHit: 0 },
    { id: 'casey.morgan', name: 'Casey Morgan', jobTitle: 'Technician', isSales: false, onPool: true, ytdCommission: 0, lockedBalance: 0, strikes: 0, totalPenalties: 0, weekGross: 0, hurdleStreak: 0, hurdleWeeksHit: 0 },
    { id: 'riley.brooks', name: 'Riley Brooks', jobTitle: 'Commercial Estimator', isSales: true, onPool: true, ytdCommission: 312.4, lockedBalance: 0, strikes: 0, totalPenalties: 0, weekGross: 0, hurdleStreak: 0, hurdleWeeksHit: 0 },
  ].map((p) => ({ ...p, imageUrl: '' }));
  const total = r2(sum(people.map((p) => p.ytdCommission)));
  const recipients = people.filter((p) => p.onPool);
  const revenue = [212300, 198440, 281950, 305120, 331870, 342200, 318760, 329140, 288930, 61720];
  // Commission % of revenue: the two finalized pay weeks since go-live. Their payouts add up to Total payouts (every
  // payout this year is after go-live); revenue is what jobs closed in those same weeks.
  const rateWeeks = [
    { weekStart: '2026-10-05', payouts: 2311.2, completedRevenue: 51360, completedJobs: 31 },
    { weekStart: '2026-10-12', payouts: r2(total - 2311.2), completedRevenue: 45880, completedJobs: 27 },
  ];
  const ratePayouts = r2(sum(rateWeeks.map((w) => w.payouts)));
  const rateRevenue = sum(rateWeeks.map((w) => w.completedRevenue));
  const body = (empty) => ({
    history: { retainagePool: empty ? [] : Array.from({ length: 17 }, (_, i) => r2(80 + i * 2.1)) },
    summary: {
      totalPayoutsYtd: empty ? 0 : total,
      companyRetainagePool: empty ? 0 : 57.13,
      commercialRetainagePool: empty ? 0 : 116.35,
      avgCommissionPerRecipient: empty ? 0 : r2(total / recipients.length),
      avgCommissionPerTech: empty ? 0 : r2(total / recipients.length),
      commissionRate: empty ? null : {
        pct: ratePayouts / rateRevenue * 100,
        payouts: ratePayouts,
        completedRevenue: rateRevenue,
        completedJobs: sum(rateWeeks.map((w) => w.completedJobs)),
        from: '2026-10-05',
        to: '2026-10-18',
        weeks: rateWeeks,
      },
      salesCommission: { total: empty ? 0 : 140.25, estimates: empty ? 0 : 2, hardBid: 0, newAccount: empty ? 0 : 140.25, account: 0 },
      nextDisbursement: { date: '2027-01-01', amount: 0, techCount: 0 },
    },
    meta: {
      year: 2026, goLiveDate: '2026-10-05', weeklyThreshold: 750, retainageScope: 'locked balance: lifetime; strikes and penalties: selected year',
      averageBasis: 'commission recipients: everyone on the job pool (sales-only reps left out)',
      averageHeadcount: empty ? 0 : recipients.length,
    },
    technicians: empty ? [] : people,
    monthlyData: MONTHS.map((m, i) => ({ month: m, payout: !empty && i === 9 ? total : 0, revenue: !empty && i < ELAPSED ? revenue[i] : 0 })),
    generatedAt: GENERATED_AT,
  });
  write('commissions', body(false));
  write('commissions_empty', body(true));
}

// ─── Technicians (/api/tech_stats) ──────────────────────────────────────────────────────────────────────────────
{
  const profit = [68400, 61920, 94310, 101870, 108240, 113560, 104020, 109830, 93410, 18760];
  const jobs = [151, 128, 154, 166, 181, 192, 175, 163, 152, 47];
  // callbackJobs = completed jobs since go-live (Oct 5), the callback-rate denominator. Per tech they add up to more
  // than the company figure because a job worked by two techs counts for each.
  const techs = [
    { id: 'alex.rivera', name: 'Alex Rivera', jobTitle: 'Lead Technician', completedJobsYtd: 733, callbackJobs: 38, callbackCount: 3, jobsSinceCallback: 5, revenue: 512340.55 },
    { id: 'sam.carter', name: 'Sam Carter', jobTitle: 'Technician', completedJobsYtd: 412, callbackJobs: 24, callbackCount: 1, jobsSinceCallback: 7, revenue: 388910.2 },
    { id: 'jordan.lee', name: 'Jordan Lee', jobTitle: 'Technician', completedJobsYtd: 286, callbackJobs: 19, callbackCount: 1, jobsSinceCallback: 1, revenue: 301220.0 },
    { id: 'casey.morgan', name: 'Casey Morgan', jobTitle: 'Technician', completedJobsYtd: 82, callbackJobs: 6, callbackCount: 0, jobsSinceCallback: 0, revenue: 74960.4 },
  ].map((t) => ({ ...t, avatarUrl: '', revenueGenerated: '$' + t.revenue.toLocaleString('en-US', { minimumFractionDigits: 2 }), totalPenalties: '$0.00' }));
  const totalJobs = sum(jobs);
  const callbackJobs = 72; // completed jobs since Oct 5 (distinct jobs)
  const callbacks = sum(techs.map((t) => t.callbackCount));
  const techCount = techs.length;
  const workDays = DAY_OF_YEAR / 365 * 240;
  const totalProfit = sum(profit);
  const avgProfitYtd = totalProfit / techCount;
  const body = (empty) => ({
    summary: {
      metrics: {
        year: 2026,
        avgProfitYtd: empty ? 0 : avgProfitYtd,
        avgProfitPerDay: empty ? 0 : avgProfitYtd / workDays,
        // Strikes ÷ completed jobs, both since go-live; null (no rate) when there are no such jobs.
        callbackRatePct: empty ? null : callbacks / callbackJobs * 100,
        callbacks: empty ? 0 : callbacks,
        callbackJobs: empty ? 0 : callbackJobs,
        callbackPeriod: { from: '2026-10-05', to: '2026-10-22' },
        jobs: empty ? 0 : totalJobs,
        techCount,
        avgCustomerRating: null,
      },
      totalJobsYtd: empty ? 0 : totalJobs,
      chartData: Array.from({ length: ELAPSED }, (_, i) => {
        const partial = i === 9;
        const days = partial ? 22 / 31 * 20 : 20;
        return {
          month: MONTHS[i],
          avgProfitPerDay: empty ? 0 : Math.round(profit[i] / techCount / days),
          totalProfit: empty ? 0 : profit[i],
          jobCount: empty ? 0 : jobs[i],
          priorAvgProfitPerDay: Math.round(profit[i] * 0.9 / techCount / 20),
          priorTotalProfit: Math.round(profit[i] * 0.9),
          priorJobCount: Math.round(jobs[i] * 0.95),
          partial,
        };
      }),
    },
    techs: empty ? [] : techs,
    generatedAt: GENERATED_AT,
  });
  write('technicians', body(false));
  write('technicians_empty', body(true));
}

// ─── Inventory (/api/dashboards/inventory) ─────────────────────────────────────────────────────────────────────
{
  const cats = [
    ['Hardware & Fasteners', 6120, 410], ['Miscellaneous & Other', 9875, 1290], ['Operators & Electronics', 17640, 2310],
    ['Seals & Insulation', 3205, 260], ['Springs & Balancing', 10220, 1745], ['Tracks & Struts', 1820, 304],
  ];
  const palette = ['#0284C7', '#D97706', '#059669', '#7C3AED', '#4F46E5', '#475569'];
  const total = sum(cats.map((c) => c[1] + c[2]));
  const body = (empty) => ({
    history: { valuation: empty ? [] : Array.from({ length: 17 }, (_, i) => 54800 + i * 23) },
    totalValuation: empty ? 0 : total,
    deadStockValue: null,
    lowStockCount: empty ? 0 : 132,
    accuracyPct: null,
    lastCycleCount: empty ? null : '2026-10-16',
    movementTracked: false,
    categories: empty ? [] : cats.map(([c, a, l], i) => ({ category: c, activeValue: a, lowStockValue: l, deadValue: 0, colorHex: palette[i] })),
    topStrikeTechs: empty ? [] : [
      { name: 'Casey Morgan', imageUrl: '', strikeCount: 0 },
      { name: 'Jordan Lee', imageUrl: '', strikeCount: 2 },
      { name: 'Sam Carter', imageUrl: '', strikeCount: 4 },
    ],
    monthly: [],
    generatedAt: GENERATED_AT,
  });
  write('inventory', body(false));
  write('inventory_empty', body(true));
}

// ─── Sales (/api/dashboards/sales) ─────────────────────────────────────────────────────────────────────────────
{
  const resM = [31520, 84674, 77961, 87599, 79919, 38780, 87263, 53342, 137118, 24931, 0, 0];
  const comM = [0, 0, 0, 0, 0, 0, 33867, 0, 2926, 478, 0, 0];
  const resWon = [4, 12, 11, 13, 12, 6, 14, 9, 21, 5, 0, 0];
  const comWon = [0, 0, 0, 0, 0, 0, 1, 0, 1, 1, 0, 0];
  const lost = [1, 2, 2, 1, 3, 1, 2, 1, 3, 2, 0, 0];
  const sent = [22, 31, 33, 36, 34, 25, 40, 30, 52, 23, 0, 0];
  const won = resWon.map((v, i) => v + comWon[i]);
  const wonValue = sum(resM) + sum(comM);
  const wonCount = sum(won);
  const closed = won.map((v, i) => v + lost[i]);
  const priorM = [100000, 160000, 220000, 280000, 340000, 100000, 160000, 220000, 280000, 340000, 100000, 160000];
  const resLost = sum(lost) - 0;
  const body = (empty) => ({
    success: true,
    year: 2026,
    summary: {
      wonValue: empty ? 0 : wonValue,
      wonCount: empty ? 0 : wonCount,
      winRate: empty ? 0 : wonCount / sum(closed) * 100,
      largestDeal: empty ? 0 : 38608,
      sentCount: empty ? 0 : sum(sent),
      // Same Jan 1 - Oct 22 stretch of 2025 (like-for-like), not the whole of 2025.
      priorWonValue: empty ? 0 : sum(priorM.slice(0, 9)) + Math.round(priorM[9] * 22 / 31),
    },
    doorTypes: empty ? [] : [
      ['Modern Steel', 34, 13, 0, 41824], ['Gallery Steel', 40, 11, 1, 13621], ['Classic Steel', 52, 10, 3, 16761],
      ['Bridgeport Steel', 25, 9, 0, 27451], ['Canyon Ridge', 16, 6, 0, 86724], ['Unspecified', 45, 25, 5, 55466],
    ].map(([type, s, w, l, rv]) => ({ type, sentCount: s, wonCount: w, lostCount: l, winRate: 0, revenue: rv })),
    monthly: empty ? [] : Array.from({ length: ELAPSED }, (_, i) => ({ month_num: i + 1, won_value: resM[i] + comM[i], won_count: won[i], closed_count: closed[i], sent_count: sent[i] })),
    priorMonthly: Array.from({ length: 12 }, (_, i) => ({ month_num: i + 1, won_value: empty ? 0 : priorM[i], won_count: 25, closed_count: 27, sent_count: 31 })),
    people: empty ? [] : [
      { name: 'Taylor Reed', role: 'Residential Sales', imageUrl: '', wonValue: sum(resM), wonCount: sum(resWon), sentCount: sum(sent) - 28, lostCount: resLost, largestDeal: 38608, winRate: sum(resWon) / (sum(resWon) + resLost) * 100, monthlyWon: resM },
      { name: 'Riley Brooks', role: 'Commercial Sales', imageUrl: '', wonValue: sum(comM), wonCount: sum(comWon), sentCount: 28, lostCount: 0, largestDeal: 33867, winRate: 100, monthlyWon: comM },
    ],
    generatedAt: GENERATED_AT,
  });
  write('sales', body(false));
  write('sales_empty', body(true));
}

// ─── Collections (/api/dashboards/collections) ─────────────────────────────────────────────────────────────────
{
  const cur = [230676, 195153, 269204, 395785, 326921, 207158, 292252, 362004, 137737, 23769];
  const pri = [159188, 236958, 241508, 280098, 337189, 227778, 378541, 273155, 226395, 326806, 249551, 268718];
  const collected = sum(cur);
  const stages = [['none', 'Final Invoice Sent', 68389.63, 105], ['14', '14 Day Notice', 44494.11, 33], ['30', '30 Day Notice', 10492.39, 11],
    ['60', '60 Day Notice', 8604.67, 8], ['90', '90 Day Notice', 22577.47, 40], ['check', 'Check on Payment', 83574.56, 12]];
  const outstanding = r2(sum(stages.map((s) => s[2])));
  const methods = [['Check', 0.686, 1177], ['Card', 0.297, 378], ['ACH', 0.0167, 12], ['Cash', 0.0004, 5]];
  const m = methods.map(([method, s, n]) => ({ method, amount: Math.round(collected * s), paymentCount: n }));
  m.push({ method: 'Other', amount: collected - sum(m.map((x) => x.amount)), paymentCount: 2 }); // methods add up to Collected
  const writeOffs = [{ month_num: 2, job_count: 1, balance: 50.47 }, { month_num: 3, job_count: 1, balance: 202.91 }, { month_num: 4, job_count: 2, balance: 79.97 }];
  const body = (empty) => ({
    success: true,
    year: 2026,
    summary: {
      collected: empty ? 0 : collected,
      paymentCount: empty ? 0 : 1574,
      largestPayment: empty ? 0 : 64358,
      // Same Jan 1 - Oct 22 stretch of 2025.
      priorCollected: empty ? 0 : sum(pri.slice(0, 9)) + Math.round(pri[9] * 22 / 31),
      outstanding: empty ? 0 : outstanding,
      outstandingJobs: empty ? 0 : sum(stages.map((s) => s[3])),
      over90: empty ? 0 : 22577.47,
      over90Jobs: empty ? 0 : 40,
      writeOffJobs: empty ? 0 : sum(writeOffs.map((w) => w.job_count)),
      writeOffBalance: empty ? 0 : r2(sum(writeOffs.map((w) => w.balance))),
    },
    writeOffMonthly: empty ? [] : writeOffs,
    history: empty ? [] : Array.from({ length: 17 }, (_, i) => ({ day: `2026-10-${String(i + 6).padStart(2, '0')}`, outstanding: 230000 + i * 480, over90: 21000 + i * 90 })),
    overdue: empty ? [] : Array.from({ length: 12 }, (_, i) => ({ jobId: String(9100001 + i), customer: CUSTOMERS[i % CUSTOMERS.length], amount: 1200 + i * 835, status: 'Final Invoice Sent', daysOverdue: 900 - i * 62 })),
    monthly: cur.map((v, i) => ({ month_num: i + 1, collected: empty ? 0 : v, payment_count: 150 })),
    priorMonthly: pri.map((v, i) => ({ month_num: i + 1, collected: empty ? 0 : v, payment_count: 150 })),
    methods: empty ? [] : m,
    stages: stages.map(([stage, label, amount, jobCount]) => ({ stage, label, amount: empty ? 0 : amount, jobCount: empty ? 0 : jobCount })),
    topOwing: empty ? [] : [
      ['Summit Builders', 64358, 1, 80], ['Oakridge Property Co', 36531.25, 5, 143], ['Northwind Homes LLC', 21610.17, 46, 1091],
      ['Cedar Point Storage', 20857.33, 1, 4], ['Pine Hollow Apartments', 20679.62, 1, 108],
    ].map(([customer, amount, jobCount, oldestDays]) => ({ customer, amount, jobCount, oldestDays })),
    generatedAt: GENERATED_AT,
  });
  write('collections', body(false));
  write('collections_empty', body(true));
}

// ─── Jobs (/api/dashboards/jobs) ───────────────────────────────────────────────────────────────────────────────
{
  const vol = [[159, 104, 42], [131, 75, 41], [159, 102, 38], [168, 122, 35], [183, 127, 34], [196, 137, 37], [178, 114, 38], [167, 107, 45], [157, 108, 39], [8, 4, 0]];
  const statuses = [['Need To Schedule', 130], ['Scheduled - Full Day', 33], ['Complete', 21], ['Need Deposit', 13], ['Delayed', 12], ['Partially Complete', 11],
    ['Need To Sell', 9], ['Manage Project', 5], ['Appointment', 1], ['14 Day Notice', 1], ['Check on Payment', 1], ['Need To Order', 1], ['Part Ordered', 1]];
  const completed = sum(vol.map((v) => v[0]));
  const body = (empty) => ({
    success: true,
    year: 2026,
    history: { activeOpenJobs: empty ? [] : Array.from({ length: 17 }, (_, i) => 228 + (i % 5) * 2 + Math.floor(i / 2)) },
    monthlyMetrics: empty ? [] : Array.from({ length: ELAPSED }, (_, i) => ({ month_num: i + 1, profit_margin: 36 + (i % 4) * 2.5, new_customers: 30 + (i % 5) * 6 })),
    scorecards: {
      completedYtd: empty ? 0 : completed,
      activeOpenJobs: empty ? 0 : sum(statuses.map((s) => s[1])),
      avgJobRevenue: empty ? 0 : 1597,
      newCustomersYtd: empty ? 0 : 412,
      avgProfitMargin: empty ? 0 : 38.2,
    },
    monthlyVolume: empty ? [] : vol.map(([c, inst, svc], i) => ({ month_num: i + 1, completed_count: c, install_count: inst, service_count: svc })),
    weeklySplit: [],
    monthlySplit: empty ? [] : Array.from({ length: ELAPSED }, (_, i) => ({ month_num: i + 1, commercial_rev: i === 9 ? 4200 : 40000 + (i % 4) * 45000, residential_rev: i === 9 ? 8600 : 150000 + (i % 3) * 30000 })),
    statusCounts: empty ? [] : statuses.map(([status, count]) => ({ status, count })),
    pipelineStages: [],
    splitCoverage: { completedJobs: empty ? 0 : completed, jobsWithCategories: empty ? 0 : 1349, jobsWithLineItems: empty ? 0 : 1446 },
    generatedAt: GENERATED_AT,
  });
  write('jobs', body(false));
  write('jobs_empty', body(true));
}

// ─── Estimates (/api/dashboards/estimates) ─────────────────────────────────────────────────────────────────────
{
  // The open pipeline is every estimate open today, any year. 312 of them ($5,312,640) are dated before 2026, all in
  // the 31+ day bar with this year's 290 older ones ($5,865,223).
  const prior = { count: 312, value: 5312640, before: '2026-01-01' };
  const aging = [['0-7 days', 17, 202797, false], ['8-14 days', 10, 241384, false], ['15-30 days', 31, 433864, false],
    ['31+ days', 290 + prior.count, 5865223 + prior.value, true]];
  // The stale list (14+ days, $1,000+), oldest first: two from earlier years, then this year's.
  const stale = [
    { job_id: '9100001', customer_name: CUSTOMERS[4], value: 18250, days_old: 912 },
    { job_id: '9100002', customer_name: CUSTOMERS[5], value: 7400, days_old: 401 },
    ...Array.from({ length: 8 }, (_, i) => ({ job_id: String(9200001 + i), customer_name: CUSTOMERS[i % CUSTOMERS.length], value: 4000 + i * 900, days_old: 300 - i * 31 })),
  ];
  const lostM = [15000, 27000, 39000, 3000, 15000, 27000, 39000, 3000, 75000, 4922];
  const monthly = Array.from({ length: ELAPSED }, (_, i) => {
    const m = i + 1;
    return { month_num: m, sent_value: 300000 + m * 20000, won_value: 120000 + m * 9000, sent_count: 30 + m, won_count: 12 + Math.floor(m / 2), closed_count: 14 + Math.floor(m / 2), lost_value: lostM[i] };
  });
  const lostTotal = sum(lostM);
  const reasons = [['Other', Math.round(lostTotal * 0.85), 29], ['Price', 38176, 1], ['Competitor', 4960, 1], ['Unresponsive', 0, 1], ['Timing', 0, 0]];
  reasons[0][1] = lostTotal - sum(reasons.slice(1).map((r) => r[1])); // reasons add up to Lost value
  const won = sum(monthly.map((m) => m.won_count));
  const closedCount = sum(monthly.map((m) => m.closed_count));
  const body = (empty) => ({
    success: true,
    year: 2026,
    scorecards: {
      openValue: empty ? 0 : sum(aging.map((a) => a[2])),
      openCount: empty ? 0 : sum(aging.map((a) => a[1])),
      openPriorYears: empty ? { count: 0, value: 0, before: prior.before } : prior,
      lostValue: empty ? 0 : lostTotal,
      winRate: empty ? 0 : won / closedCount * 100,
      sentYtd: empty ? 0 : sum(monthly.map((m) => m.sent_count)),
    },
    stalePipeline: empty ? [] : stale,
    staleSummary: empty ? { totalCount: 0, totalValue: 0, oldestDays: 0, avgDays: 0 } : { totalCount: stale.length, totalValue: sum(stale.map((s) => s.value)), oldestDays: stale[0].days_old, avgDays: Math.round(sum(stale.map((s) => s.days_old)) / stale.length) },
    agingBuckets: aging.map(([bucket, count, value, stale]) => ({ bucket, count: empty ? 0 : count, value: empty ? 0 : value, stale })),
    history: { openValue: empty ? [] : Array.from({ length: 17 }, (_, i) => 11920000 + i * 8000) },
    monthlyValue: empty ? [] : monthly,
    lostReasons: reasons.map(([reason, v, n]) => ({ reason, lost_value: empty ? 0 : v, count: empty ? 0 : n })),
    generatedAt: GENERATED_AT,
  });
  write('estimates', body(false));
  write('estimates_empty', body(true));
}

console.log('wrote', fs.readdirSync(out).length, 'files to', out);
