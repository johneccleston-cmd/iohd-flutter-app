part of 'payroll_screen.dart';

// ---------------------------------------------------------------------------
// PDF export: a cover register for everyone, then one section per technician
// with every pay week, closed job, commission line item, advance, callback and
// retainage release for the report dates.
//
// US Letter, landscape. Every register row reconciles across: closed-job net + advances + callbacks (+ sales
// commission, retainage held, other) = gross; gross - hurdle = cash pay; cash pay + retainage released = total due.
// The figures are the server's; this file only lays them out.
// ---------------------------------------------------------------------------

final PdfColor _pInk = PdfColor.fromInt(0xFF0F172A);
final PdfColor _pSlate = PdfColor.fromInt(0xFF475569);
final PdfColor _pSubtle = PdfColor.fromInt(0xFF64748B); // DashUi.subtle: secondary text that still prints clearly
final PdfColor _pMuted = PdfColor.fromInt(0xFF94A3B8); // only for zeros, which are meant to recede
final PdfColor _pLine = PdfColor.fromInt(0xFFE2E8F0);
final PdfColor _pFaint = PdfColor.fromInt(0xFFF1F5F9);
final PdfColor _pGreen = PdfColor.fromInt(0xFF047857); // DashUi.emeraldText
final PdfColor _pRed = PdfColor.fromInt(0xFFDC2626);
final PdfColor _pAmber = PdfColor.fromInt(0xFFB45309); // DashUi.amberText

/// Typographic punctuation the built-in fonts lack, swapped for plain equivalents ("O’Brien" prints as "O'Brien").
const Map<int, String> _pdfPlain = {
  0x2018: "'", 0x2019: "'", 0x201A: "'", 0x201B: "'", 0x2032: "'", // single quotes, prime
  0x201C: '"', 0x201D: '"', 0x201E: '"', 0x2033: '"', // double quotes
  0x2010: '-', 0x2011: '-', 0x2012: '-', 0x2013: '-', 0x2014: '-', 0x2015: '-', 0x2212: '-', // dashes, minus
  0x2026: '...', 0x2022: '-', 0x2009: ' ', 0x202F: ' ', 0x200B: '', // ellipsis, bullet, thin and zero-width spaces
};

/// The built-in PDF fonts only cover Latin-1. Common punctuation is swapped for a plain equivalent; anything else
/// prints as a question mark.
String _pdfSafe(String v) {
  final out = StringBuffer();
  for (final c in v.runes) {
    final plain = _pdfPlain[c];
    if (plain != null) {
      out.write(plain);
    } else {
      out.writeCharCode(c < 256 ? c : 0x3F);
    }
  }
  return out.toString();
}

pw.Widget _pt(
  String text, {
  double size = 9,
  bool bold = false,
  PdfColor? color,
  pw.TextAlign align = pw.TextAlign.left,
}) {
  return pw.Text(
    _pdfSafe(text),
    textAlign: align,
    style: pw.TextStyle(
      fontSize: size,
      fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
      color: color ?? _pInk,
    ),
  );
}

/// A table with a shaded header row that repeats at the top of every page it runs onto, right-aligned [right]
/// columns and an optional bold footer. Zero amounts in the body print light so the real figures stand out.
pw.Widget _pdfTable(
  List<String> heads,
  List<List<String>> rows, {
  required List<double> flex,
  Set<int> right = const {},
  List<String>? foot,
  double size = 8.5,
  double? headSize,
}) {
  final defaultSize = size;
  final zero = _fmt(0);
  pw.Widget cell(String text, int i, {bool bold = false, PdfColor? color, double? size}) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
    child: _pt(
      text,
      size: size ?? defaultSize,
      bold: bold,
      color: color,
      align: right.contains(i) ? pw.TextAlign.right : pw.TextAlign.left,
    ),
  );

  return pw.Table(
    columnWidths: {for (var i = 0; i < flex.length; i++) i: pw.FlexColumnWidth(flex[i])},
    border: pw.TableBorder(horizontalInside: pw.BorderSide(color: _pLine, width: 0.5)),
    children: [
      pw.TableRow(
        repeat: true,
        decoration: pw.BoxDecoration(color: _pFaint),
        children: [
          for (var i = 0; i < heads.length; i++) cell(heads[i], i, bold: true, color: _pSlate, size: headSize),
        ],
      ),
      for (final r in rows)
        pw.TableRow(children: [for (var i = 0; i < r.length; i++) cell(r[i], i, color: r[i] == zero ? _pMuted : null)]),
      if (foot != null)
        pw.TableRow(
          decoration: pw.BoxDecoration(color: _pFaint),
          children: [for (var i = 0; i < foot.length; i++) cell(foot[i], i, bold: true)],
        ),
    ],
  );
}

/// Who exported the PDF and when, printed on the cover and in every footer so a printed copy can be told apart from
/// a later one. [weekStatus] is each pay week's run status as the screen shows it ("Paid · run #9 · Oct 13",
/// "Not run yet"), keyed by week start; weeks with no known status are left out.
class _PdfMeta {
  final DateTime generatedAt;
  final String generatedBy;
  final Map<String, ({String label, bool paid})> weekStatus;

  const _PdfMeta({required this.generatedAt, this.generatedBy = '', this.weekStatus = const {}});

  String get stamp =>
      'Generated ${DateFormat('MMM d, yyyy h:mm a').format(generatedAt)}'
      '${generatedBy.trim().isEmpty ? '' : ' by ${generatedBy.trim()}'}';
}

/// One figure column of a register. The cover (one row per person) and each person's summary share these, so both
/// reconcile the same way.
class _PdfCol {
  final String head;
  final double Function(_Tech) value;
  const _PdfCol(this.head, this.value);
}

/// Column widths for the registers, relative to one figure column. Worked out from Helvetica's widths for the widest
/// case, eleven figure columns on Letter landscape: each figure column then fits "-$37,427.01" in bold at 8pt and
/// "commission" in bold at 7.2pt, and the name column fits "Montgomery-Alexander" at 8pt without breaking it.
const double _pdfNameFlex = 1.9;
const double _pdfJobsFlex = 0.55;

/// Registers with more figure columns than this print in the smaller sizes so every column keeps its words whole.
const int _pdfDenseAfter = 9;

double _weeksSum(_Tech t, double Function(_Week) f) => t.weeks.fold<double>(0, (s, w) => s + f(w));

/// The register's figure columns. Sales commission, retainage held and other adjustments only appear when someone
/// has them; with them in, the parts of every row add up to its gross.
List<_PdfCol> _pdfColumns(List<_Tech> techs) {
  bool any(double Function(_Tech) f) => techs.any((t) => f(t).abs() >= 0.005);
  double held(_Tech t) => _weeksSum(t, (w) => w.hurdleCredit);
  double other(_Tech t) => _weeksSum(t, (w) => w.otherAdjustments);
  return [
    _PdfCol('Closed-job net', (t) => t.jobNet),
    _PdfCol('Advances', (t) => t.totals.advancesPaid),
    _PdfCol('Callbacks', (t) => t.totals.callbackPay),
    if (any((t) => t.repPay)) _PdfCol('Sales commission', (t) => t.repPay),
    if (any(held)) _PdfCol('Retainage held', held),
    if (any(other)) _PdfCol('Other', other),
    _PdfCol('Gross', (t) => t.totals.weeklyGross),
    _PdfCol('Hurdle', (t) => -t.totals.hurdleApplied),
    _PdfCol('Cash pay', (t) => t.totals.cashPay),
    _PdfCol('Retainage released', (t) => t.totals.retainageReleased),
    _PdfCol('Total due', (t) => t.totals.totalDue),
  ];
}

Future<Uint8List> _buildPayrollPdf(_Report r, _PdfMeta meta) async {
  final doc = pw.Document(
    title: 'Payroll commission report, ${r.start} to ${r.end}',
    author: meta.generatedBy.trim().isEmpty ? 'IOHD' : meta.generatedBy.trim(),
    creator: 'IOHD Office',
  );
  final range = '${_day(r.start, year: true)} to ${_day(r.end, year: true)}';
  const margin = pw.EdgeInsets.fromLTRB(36, 30, 36, 30);

  pw.Widget footer(pw.Context ctx) => pw.Padding(
    padding: const pw.EdgeInsets.only(top: 8),
    child: pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        _pt('Payroll commission report  |  $range  |  ${meta.stamp}', size: 7.5, color: _pSubtle),
        _pt('Page ${ctx.pageNumber} of ${ctx.pagesCount}', size: 7.5, color: _pSubtle),
      ],
    ),
  );

  doc.addPage(
    pw.MultiPage(pageFormat: _pdfPageFormat, margin: margin, footer: footer, build: (_) => _pdfCover(r, range, meta)),
  );

  // Each person is a section of their own, starting on a new page. Pages after a section's first carry the person's
  // name, so a loose page can always be placed.
  for (final t in r.techs) {
    int? first;
    doc.addPage(
      pw.MultiPage(
        pageFormat: _pdfPageFormat,
        margin: margin,
        header: (ctx) {
          first ??= ctx.pageNumber;
          if (ctx.pageNumber == first) return pw.SizedBox();
          return pw.Container(
            margin: const pw.EdgeInsets.only(bottom: 10),
            padding: const pw.EdgeInsets.only(bottom: 4),
            decoration: pw.BoxDecoration(
              border: pw.Border(bottom: pw.BorderSide(color: _pLine, width: 0.5)),
            ),
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                _pt('${t.name} (continued)', size: 9, bold: true, color: _pSlate),
                _pt('Pay weeks $range', size: 8, color: _pSubtle),
              ],
            ),
          );
        },
        footer: footer,
        build: (_) => _pdfTech(t, r, meta),
      ),
    );
  }
  return doc.save();
}

/// US Letter, landscape: the paper office printers here take.
const PdfPageFormat _pdfPageFormat = PdfPageFormat(11 * PdfPageFormat.inch, 8.5 * PdfPageFormat.inch);

List<pw.Widget> _pdfCover(_Report r, String range, _PdfMeta meta) {
  final cols = _pdfColumns(r.techs);
  double sum(double Function(_Tech) f) => r.techs.fold<double>(0, (s, t) => s + f(t));

  return [
    pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      crossAxisAlignment: pw.CrossAxisAlignment.end,
      children: [
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            _pt('Payroll Commission Report', size: 22, bold: true),
            pw.SizedBox(height: 4),
            _pt('Pay weeks $range', size: 11, color: _pSlate),
          ],
        ),
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            _pt('Total due', size: 9, color: _pSlate),
            _pt(_fmt(sum((t) => t.totals.totalDue)), size: 20, bold: true, color: _pGreen),
          ],
        ),
      ],
    ),
    pw.SizedBox(height: 4),
    _pt(meta.stamp, size: 8.5, color: _pSubtle),
    pw.SizedBox(height: 3),
    _pt(
      'Pay weeks run Monday to Sunday. Weekly hurdle ${_fmt(r.weeklyThreshold)}, advance ${_fmt(r.dailyAdvance)} per day, '
      'callback pay ${_fmt(r.callbackPay)}, company pool ${_pct(r.companyPoolRate * 100)}, '
      'commercial retainage ${_pct(r.retainageRate * 100)}.',
      size: 8.5,
      color: _pSubtle,
    ),
    pw.SizedBox(height: 16),
    _pt('Payroll register', size: 13, bold: true),
    pw.SizedBox(height: 6),
    _pdfTable(
      ['Technician', 'Jobs', for (final c in cols) c.head],
      [
        for (final t in r.techs) [t.name, '${t.jobCount}', for (final c in cols) _fmt(c.value(t))],
      ],
      flex: [_pdfNameFlex, _pdfJobsFlex, for (final _ in cols) 1],
      size: cols.length > _pdfDenseAfter ? 8 : 8.5,
      headSize: cols.length > _pdfDenseAfter ? 7.2 : 8.5,
      right: {for (var i = 1; i < cols.length + 2; i++) i},
      foot: ['Total', '${r.techs.fold<int>(0, (n, t) => n + t.jobCount)}', for (final c in cols) _fmt(sum(c.value))],
    ),
    pw.SizedBox(height: 12),
    _pt(
      'Each row adds up across: the parts make the gross, the gross less the weekly hurdle is the cash pay, and the cash '
      'pay plus retainage released is the total due. Retainage held counts toward the hurdle but is not paid until it '
      'is released. This report does not record or pay a payroll run; a job pays in the week it is closed. The '
      'following pages break down every technician: pay weeks, closed jobs, commission line items, advances, '
      'callbacks and retainage releases.',
      size: 8.5,
      color: _pSubtle,
    ),
  ];
}

List<pw.Widget> _pdfTech(_Tech t, _Report r, _PdfMeta meta) {
  final tot = t.totals;
  final out = <pw.Widget>[];
  final cols = _pdfColumns([t]);

  out.add(
    pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: pw.BoxDecoration(color: _pFaint, borderRadius: pw.BorderRadius.circular(6)),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                _pt(t.name, size: 18, bold: true),
                pw.SizedBox(height: 2),
                _pt(
                  '${t.kindLabel}  |  ${t.weeks.length} ${t.weeks.length == 1 ? 'pay week' : 'pay weeks'}, '
                  '${t.jobCount} ${t.jobCount == 1 ? 'job' : 'jobs'} closed'
                  '${t.underHurdle ? '  |  Under the weekly hurdle in at least one week, no cash pay for it' : ''}',
                  size: 9,
                  color: _pSlate,
                ),
              ],
            ),
          ),
          pw.SizedBox(width: 12),
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              _pt('Total due', size: 9, color: _pSlate),
              _pt(_fmt(tot.totalDue), size: 20, bold: true, color: tot.totalDue < 0 ? _pRed : _pGreen),
            ],
          ),
        ],
      ),
    ),
  );
  out.add(pw.SizedBox(height: 8));

  out.add(
    _pdfTable(
      [for (final c in cols) c.head],
      [
        [for (final c in cols) _fmt(c.value(t))],
      ],
      flex: [for (final _ in cols) 1],
      right: {for (var i = 0; i < cols.length; i++) i},
    ),
  );

  if (t.weeks.isEmpty && t.releases.isEmpty) {
    out.add(pw.SizedBox(height: 12));
    out.add(_pt('Nothing to report for this person in these dates.', color: _pSlate));
  }

  for (final w in t.weeks) {
    out.add(pw.SizedBox(height: 18));
    out.addAll(_pdfWeek(w, r, meta));
  }

  if (t.releases.isNotEmpty) {
    out.add(pw.SizedBox(height: 18));
    final table = _pdfTable(
      const ['Date', 'Job', 'Type', 'Amount'],
      [
        for (final x in t.releases)
          [
            _day(x.releasedOn, year: true),
            x.jobId.isEmpty ? 'No job' : x.jobId,
            x.type == 'callback_deduction' ? 'Callback charge' : 'Retainage released',
            _fmt(x.amount),
          ],
      ],
      flex: const [1.4, 1.4, 3, 1.4],
      right: const {3},
      foot: ['', '', 'Total released', _fmt(tot.retainageReleased)],
    );
    // The heading stays with the table unless the table is longer than a page.
    out.add(_keepWithNext(_pt('Commercial retainage released', size: 12, bold: true), table, t.releases.length));
  }

  return out;
}

/// [heading] and the start of [table] on the same page: together they move to the next page when they don't fit.
/// A table with more than [_keepRows] rows is left free to break across pages (its header repeats), since a block
/// taller than a page can't be kept whole.
pw.Widget _keepWithNext(pw.Widget heading, pw.Widget table, int rows, {double gap = 4}) {
  final block = pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      heading,
      pw.SizedBox(height: gap),
      table,
    ],
  );
  return rows <= _keepRows ? pw.Inseparable(child: block) : block;
}

const int _keepRows = 16;

List<pw.Widget> _pdfWeek(_Week w, _Report r, _PdfMeta meta) {
  final out = <pw.Widget>[];
  final under = w.hurdleRule > 0 && w.weeklyGross < w.hurdleRule;
  final status = meta.weekStatus[w.weekStart];

  final ledger = <List<String>>[
    ['Closed-job commission (net to tech)', _fmt(w.jobNet)],
    if (w.hurdleCredit > 0) ['Retainage held this week (counts toward the hurdle, not paid now)', _fmt(w.hurdleCredit)],
    if (w.advancesPaid != 0) ['Advances paid', _fmt(w.advancesPaid)],
    if (w.callbackPay != 0) ['Callback pay', _fmt(w.callbackPay)],
    if (w.repPay != 0) ['Sales commission (closed jobs)', _fmt(w.repPay)],
    if (w.otherAdjustments != 0) ['Other adjustments', _fmt(w.otherAdjustments)],
    ['Weekly gross', _fmt(w.weeklyGross)],
    if (w.hurdleRule > 0)
      [under ? 'Under the ${_fmt(w.hurdleRule)} hurdle, no cash pay' : 'Weekly hurdle', _fmt(-w.hurdleApplied)],
    if (w.advanceShortfall > 0) ['Advance shortfall (recovered later)', _fmt(w.advanceShortfall)],
  ];

  // The week's heading and its ledger move to the next page together rather than leaving the heading stranded.
  out.add(
    _keepWithNext(
      pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        crossAxisAlignment: pw.CrossAxisAlignment.end,
        children: [
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              _pt('Pay week ${_day(w.weekStart)} to ${_day(w.weekEnd, year: true)}', size: 12.5, bold: true),
              if (status != null) ...[
                pw.SizedBox(width: 10),
                pw.Padding(
                  padding: const pw.EdgeInsets.only(bottom: 1),
                  child: _pt(status.label, size: 9, bold: true, color: status.paid ? _pGreen : _pAmber),
                ),
              ],
            ],
          ),
          _pt(
            'Cash pay ${_fmt(w.cashPay)}',
            size: 12.5,
            bold: true,
            color: w.cashPay < 0 ? _pRed : (w.cashPay > 0 ? _pGreen : _pSubtle),
          ),
        ],
      ),
      pw.SizedBox(
        width: 360,
        child: _pdfTable(
          const ['Pay week ledger', 'Amount'],
          ledger,
          flex: const [3.4, 1.2],
          right: const {1},
          foot: ['Cash pay for the week', _fmt(w.cashPay)],
        ),
      ),
      ledger.length,
    ),
  );

  for (final j in w.jobs) {
    out.add(pw.SizedBox(height: 10));
    out.add(_pdfJob(j, r));
  }

  if (w.advances.isNotEmpty || w.callbacks.isNotEmpty) {
    out.add(pw.SizedBox(height: 10));
    out.add(
      _pdfTable(
        const ['Date', 'Type', 'Job', 'Customer', 'Amount'],
        [
          for (final a in w.advances) [_day(a.date), 'Advance day', a.jobId, a.customer, _fmt(a.amount)],
          for (final c in w.callbacks) [_day(c.date), 'Callback', c.jobId, c.customer, _fmt(c.amount)],
        ],
        flex: const [1, 1.4, 1.6, 4, 1.2],
        right: const {4},
      ),
    );
  }
  if (w.repCommissions.isNotEmpty) {
    out.add(pw.SizedBox(height: 10));
    out.add(
      _pdfTable(
        const ['Closed', 'Estimate', 'Customer', 'Basis', 'Labor', 'Rate', 'Amount'],
        [
          for (final c in w.repCommissions)
            [_day(c.closedOn), c.jobId, c.customer, c.basisLabel, _fmt(c.labor), _pct(c.ratePct), _fmt(c.amount)],
        ],
        flex: const [1, 1.6, 3, 3, 1.2, 0.8, 1.2],
        right: const {4, 5, 6},
      ),
    );
  }
  return out;
}

pw.Widget _pdfJob(_Job j, _Report r) {
  final worked = j.firstWorked.isEmpty
      ? ''
      : (j.firstWorked == j.lastWorked
            ? 'Worked ${_day(j.firstWorked)}'
            : 'Worked ${_day(j.firstWorked)} to ${_day(j.lastWorked)}');
  final meta = [
    if (j.closedOn.isNotEmpty) 'Closed ${_day(j.closedOn, year: true)}',
    if (j.status.isNotEmpty) j.status,
    if (worked.isNotEmpty) '$worked (${j.daysWorked} ${j.daysWorked == 1 ? 'day' : 'days'})',
    if (j.jobRevenue > 0) 'Job total ${_fmt(j.jobRevenue)}',
    if (j.lines.isNotEmpty) 'Commission pool ${_fmt(j.poolTotal)}',
    'Split ${_pct(j.splitPct)}',
  ].join('  |  ');

  final rows = <List<String>>[
    for (final l in j.lines)
      [
        l.isPool ? 'Company pool (${_pct(r.companyPoolRate * 100)} of job commission)' : l.name,
        l.isPool ? '' : l.category,
        _fmt(l.jobAmount),
        _pct(j.splitPct),
        _fmt(l.techShare),
      ],
    if (j.adjustment != 0)
      [j.adjustment < 0 ? 'Pool cap: held back, not paid out' : 'Adjustment', '', '', '', _fmt(j.adjustment)],
    if (j.toCompanyPool > 0) ['Sent to company pool from this job', '', '', '', _fmt(j.toCompanyPool)],
  ];

  final showPayout = j.retainage != 0 || j.advancesRepaid != 0;
  final payout = StringBuffer('Net pool share ${_fmt(j.share)}');
  if (j.retainage != 0) payout.write('   less retainage held ${_fmt(j.retainage)}');
  if (j.advancesRepaid != 0) payout.write('   less advances repaid ${_fmt(j.advancesRepaid)}');
  payout.write('   =   Net to tech ${_fmt(j.net)}');

  final heading = pw.Row(
    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Expanded(
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            _pt('Job ${j.jobId}${j.customer.isEmpty ? '' : '  ${j.customer}'}', size: 10, bold: true),
            pw.SizedBox(height: 1),
            _pt(meta, size: 8, color: _pSlate),
          ],
        ),
      ),
      pw.SizedBox(width: 12),
      _pt('Net to tech ${_fmt(j.net)}', size: 10, bold: true, color: j.net < 0 ? _pRed : _pGreen),
    ],
  );

  final table = pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      if (rows.isNotEmpty)
        _pdfTable(
          const ['Line item', 'Category', 'Job line', 'Tech %', 'Tech share'],
          rows,
          flex: const [5, 3.2, 1.4, 1, 1.4],
          right: const {2, 3, 4},
          size: 8,
        ),
      // Only worth a line when something comes off the share; otherwise it just repeats the Net to tech in the header.
      if (showPayout) ...[pw.SizedBox(height: 3), _pt(payout.toString(), size: 8.5, bold: true, color: _pSlate)],
    ],
  );

  // A job's header stays on the same page as its line items.
  return _keepWithNext(heading, table, rows.length, gap: 3);
}

/// The PDF for a raw /api/payroll/commission-detail response, so tests can build and inspect the real document.
@visibleForTesting
Future<Uint8List> buildPayrollPdfForTest(
  Map<String, dynamic> report, {
  required DateTime generatedAt,
  String generatedBy = '',
  Map<String, ({String label, bool paid})> weekStatus = const {},
}) => _buildPayrollPdf(
  _Report(report),
  _PdfMeta(generatedAt: generatedAt, generatedBy: generatedBy, weekStatus: weekStatus),
);
