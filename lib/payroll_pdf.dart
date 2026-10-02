part of 'payroll_screen.dart';

// ---------------------------------------------------------------------------
// PDF export: a cover register for everyone, then one section per technician
// with every pay week, closed job, commission line item, advance, callback and
// retainage release for the report dates.
// ---------------------------------------------------------------------------

final PdfColor _pInk = PdfColor.fromInt(0xFF0F172A);
final PdfColor _pSlate = PdfColor.fromInt(0xFF475569);
final PdfColor _pMuted = PdfColor.fromInt(0xFF94A3B8);
final PdfColor _pLine = PdfColor.fromInt(0xFFE2E8F0);
final PdfColor _pFaint = PdfColor.fromInt(0xFFF1F5F9);
final PdfColor _pGreen = PdfColor.fromInt(0xFF059669);
final PdfColor _pRed = PdfColor.fromInt(0xFFDC2626);

/// The built-in PDF fonts only cover Latin-1; anything else prints as a question mark.
String _pdfSafe(String v) => String.fromCharCodes(v.runes.map((c) => c < 256 ? c : 0x3F));

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

pw.Widget _pdfTable(
  List<String> heads,
  List<List<String>> rows, {
  required List<double> flex,
  Set<int> right = const {},
  List<String>? foot,
  double size = 8.5,
}) {
  pw.Widget cell(String text, int i, {bool bold = false, PdfColor? color}) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    child: _pt(
      text,
      size: size,
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
        decoration: pw.BoxDecoration(color: _pFaint),
        children: [for (var i = 0; i < heads.length; i++) cell(heads[i], i, bold: true, color: _pSlate)],
      ),
      for (final r in rows) pw.TableRow(children: [for (var i = 0; i < r.length; i++) cell(r[i], i)]),
      if (foot != null)
        pw.TableRow(
          decoration: pw.BoxDecoration(color: _pFaint),
          children: [for (var i = 0; i < foot.length; i++) cell(foot[i], i, bold: true)],
        ),
    ],
  );
}

Future<Uint8List> _buildPayrollPdf(_Report r, {required bool sample}) async {
  final doc = pw.Document(title: 'Payroll commission report', author: 'IOHD');
  final range = '${_day(r.start, year: true)} to ${_day(r.end, year: true)}';

  final children = <pw.Widget>[
    ..._pdfCover(r, range, sample),
    for (final t in r.techs) ...[pw.NewPage(), ..._pdfTech(t, r)],
  ];

  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4.landscape,
      margin: const pw.EdgeInsets.fromLTRB(32, 30, 32, 34),
      footer: (ctx) => pw.Padding(
        padding: const pw.EdgeInsets.only(top: 8),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            _pt('Payroll commission report  |  $range${sample ? '  |  SAMPLE DATA' : ''}', size: 8, color: _pMuted),
            _pt('Page ${ctx.pageNumber} of ${ctx.pagesCount}', size: 8, color: _pMuted),
          ],
        ),
      ),
      build: (_) => children,
    ),
  );
  return doc.save();
}

List<pw.Widget> _pdfCover(_Report r, String range, bool sample) {
  double sum(double Function(_Tech) f) => r.techs.fold<double>(0, (s, t) => s + f(t));

  return [
    _pt('Payroll Commission Report', size: 22, bold: true),
    pw.SizedBox(height: 4),
    _pt('Pay weeks $range${sample ? '   (sample data)' : ''}', size: 11, color: _pSlate),
    pw.SizedBox(height: 3),
    _pt(
      'Pay weeks run Monday to Sunday. Weekly hurdle ${_fmt(r.weeklyThreshold)}, advance ${_fmt(r.dailyAdvance)} per day, '
      'callback pay ${_fmt(r.callbackPay)}, company pool ${_pct(r.companyPoolRate * 100)}, '
      'commercial retainage ${_pct(r.retainageRate * 100)}.',
      size: 9,
      color: _pMuted,
    ),
    pw.SizedBox(height: 16),
    _pt('Payroll register', size: 13, bold: true),
    pw.SizedBox(height: 6),
    _pdfTable(
      const [
        'Technician',
        'Jobs',
        'Closed-job net',
        'Advances',
        'Callbacks',
        'Gross',
        'Hurdle',
        'Cash pay',
        'Retainage released',
        'Total due',
      ],
      [
        for (final t in r.techs)
          [
            t.name,
            '${t.jobCount}',
            _fmt(t.jobNet),
            _fmt(t.totals.advancesPaid),
            _fmt(t.totals.callbackPay),
            _fmt(t.totals.weeklyGross),
            _fmt(-t.totals.hurdleApplied),
            _fmt(t.totals.cashPay),
            _fmt(t.totals.retainageReleased),
            _fmt(t.totals.totalDue),
          ],
      ],
      flex: const [3.2, 0.9, 1.6, 1.4, 1.4, 1.5, 1.4, 1.5, 1.8, 1.6],
      right: const {1, 2, 3, 4, 5, 6, 7, 8, 9},
      foot: [
        'Total',
        '${r.techs.fold<int>(0, (n, t) => n + t.jobCount)}',
        _fmt(sum((t) => t.jobNet)),
        _fmt(sum((t) => t.totals.advancesPaid)),
        _fmt(sum((t) => t.totals.callbackPay)),
        _fmt(sum((t) => t.totals.weeklyGross)),
        _fmt(-sum((t) => t.totals.hurdleApplied)),
        _fmt(sum((t) => t.totals.cashPay)),
        _fmt(sum((t) => t.totals.retainageReleased)),
        _fmt(sum((t) => t.totals.totalDue)),
      ],
      size: 9,
    ),
    pw.SizedBox(height: 12),
    _pt(
      'This report does not record or pay a payroll run. A job pays in the week it is closed. '
      'The following pages break down every technician: pay weeks, closed jobs, commission line items, '
      'advances, callbacks and retainage releases.',
      size: 8.5,
      color: _pMuted,
    ),
  ];
}

List<pw.Widget> _pdfTech(_Tech t, _Report r) {
  final tot = t.totals;
  final out = <pw.Widget>[];

  out.add(
    pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: pw.BoxDecoration(color: _pFaint, borderRadius: pw.BorderRadius.circular(6)),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              _pt(t.name, size: 18, bold: true),
              pw.SizedBox(height: 2),
              _pt(
                '${t.kindLabel}  |  ${t.weeks.length} ${t.weeks.length == 1 ? 'pay week' : 'pay weeks'}, '
                '${t.jobCount} ${t.jobCount == 1 ? 'job' : 'jobs'} closed',
                size: 9,
                color: _pSlate,
              ),
            ],
          ),
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
      const [
        'Closed-job net',
        'Advances',
        'Callbacks',
        'Weekly gross',
        'Hurdle',
        'Cash pay',
        'Retainage released',
        'Total due',
      ],
      [
        [
          _fmt(t.jobNet),
          _fmt(tot.advancesPaid),
          _fmt(tot.callbackPay),
          _fmt(tot.weeklyGross),
          _fmt(-tot.hurdleApplied),
          _fmt(tot.cashPay),
          _fmt(tot.retainageReleased),
          _fmt(tot.totalDue),
        ],
      ],
      flex: const [1, 1, 1, 1, 1, 1, 1.2, 1],
      right: const {0, 1, 2, 3, 4, 5, 6, 7},
    ),
  );

  if (t.weeks.isEmpty && t.releases.isEmpty) {
    out.add(pw.SizedBox(height: 12));
    out.add(_pt('Nothing to report for this person in these dates.', color: _pSlate));
  }

  for (final w in t.weeks) {
    out.add(pw.SizedBox(height: 18));
    out.addAll(_pdfWeek(w, r));
  }

  if (t.releases.isNotEmpty) {
    out.add(pw.SizedBox(height: 18));
    out.add(_pt('Commercial retainage released', size: 12, bold: true));
    out.add(pw.SizedBox(height: 4));
    out.add(
      _pdfTable(
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
      ),
    );
  }

  return out;
}

List<pw.Widget> _pdfWeek(_Week w, _Report r) {
  final out = <pw.Widget>[];
  final under = w.hurdleRule > 0 && w.weeklyGross < w.hurdleRule;

  out.add(
    pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        _pt('Pay week ${_day(w.weekStart)} to ${_day(w.weekEnd, year: true)}', size: 12.5, bold: true),
        _pt('Cash pay ${_fmt(w.cashPay)}', size: 12.5, bold: true, color: w.cashPay > 0 ? _pGreen : _pMuted),
      ],
    ),
  );
  out.add(pw.SizedBox(height: 4));

  final ledger = <List<String>>[
    ['Closed-job commission (net to tech)', _fmt(w.jobNet)],
    if (w.advancesPaid != 0) ['Advances paid', _fmt(w.advancesPaid)],
    if (w.callbackPay != 0) ['Callback pay', _fmt(w.callbackPay)],
    if (w.otherAdjustments != 0) ['Other adjustments', _fmt(w.otherAdjustments)],
    ['Weekly gross', _fmt(w.weeklyGross)],
    if (w.hurdleRule > 0)
      [under ? 'Under the ${_fmt(w.hurdleRule)} hurdle, no cash pay' : 'Weekly hurdle', _fmt(-w.hurdleApplied)],
    if (w.advanceShortfall > 0) ['Advance shortfall (recovered later)', _fmt(w.advanceShortfall)],
  ];
  out.add(
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
  );

  for (final j in w.jobs) {
    out.add(pw.SizedBox(height: 10));
    out.addAll(_pdfJob(j, r));
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
  return out;
}

List<pw.Widget> _pdfJob(_Job j, _Report r) {
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
    'Split ${_pct(j.splitPct)}',
  ].join('  |  ');

  final rows = <List<String>>[
    for (final l in j.lines)
      [
        l.isPool ? 'Company pool (${_pct(r.companyPoolRate * 100)} of revenue)' : l.name,
        l.isPool ? '' : l.category,
        _fmt(l.jobAmount),
        _pct(j.splitPct),
        _fmt(l.techShare),
      ],
    if (j.adjustment != 0) ['Adjustment', '', '', '', _fmt(j.adjustment)],
  ];

  final payout = StringBuffer('Net pool share ${_fmt(j.share)}');
  if (j.retainage != 0) payout.write('   less retainage held ${_fmt(j.retainage)}');
  if (j.advancesRepaid != 0) payout.write('   less advances repaid ${_fmt(j.advancesRepaid)}');
  payout.write('   =   Net to tech ${_fmt(j.net)}');

  return [
    pw.Row(
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
        _pt('Net to tech ${_fmt(j.net)}', size: 10, bold: true, color: _pGreen),
      ],
    ),
    pw.SizedBox(height: 3),
    if (rows.isNotEmpty)
      _pdfTable(
        const ['Line item', 'Category', 'Job line', 'Tech %', 'Tech share'],
        rows,
        flex: const [5, 3.2, 1.4, 1, 1.4],
        right: const {2, 3, 4},
        size: 8,
      ),
    pw.SizedBox(height: 3),
    _pt(payout.toString(), size: 8.5, bold: true, color: _pSlate),
  ];
}
