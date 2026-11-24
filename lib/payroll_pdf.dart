part of 'payroll_screen.dart';

// ---------------------------------------------------------------------------
// PDF export: a cover register for everyone, then one section per technician
// with every pay week, closed job, commission line item, advance, callback and
// retainage release for the report dates.
//
// US Letter, landscape. The registers use the screen's own column list (_registerColumns), so the PDF and the
// screen show the same figures, and every row adds across: the pieces make the gross; the gross less the hurdle and
// any advances recovered is the cash pay; the cash pay plus retainage released, less any owed recovered, is the
// total due. Each week's ledger adds down the same way. The figures are the server's; this file only lays them out.
// ---------------------------------------------------------------------------

final PdfColor _pInk = PdfColor.fromInt(0xFF111111);
final PdfColor _pSlate = PdfColor.fromInt(0xFF505050);
final PdfColor _pSubtle = PdfColor.fromInt(0xFF6B6B6B); // DashUi.subtle: secondary text that still prints clearly
final PdfColor _pMuted = PdfColor.fromInt(0xFF9E9E9E); // only for zeros, which are meant to recede
final PdfColor _pLine = PdfColor.fromInt(0xFFE4E4E4);
final PdfColor _pRule = PdfColor.fromInt(0xFFD4D4D4); // the rule above a subtotal: a step darker than the row lines
final PdfColor _pFaint = PdfColor.fromInt(0xFFF2F2F2);
final PdfColor _pGreen = PdfColor.fromInt(0xFF047857); // DashUi.emeraldText
final PdfColor _pRed = PdfColor.fromInt(0xFFDC2626);
final PdfColor _pAmber = PdfColor.fromInt(0xFFB45309); // DashUi.amberText

/// The built-in PDF fonts use WinAnsi, which has these typographic characters at 0x80-0x9F. The pdf package writes
/// a string's Latin-1 bytes, so each one is written as the code point with that byte value and prints as itself.
const Map<int, int> _winAnsi = {
  0x20AC: 0x80, 0x201A: 0x82, 0x0192: 0x83, 0x201E: 0x84, 0x2026: 0x85, 0x2020: 0x86, 0x2021: 0x87, // € ‚ ƒ „ … † ‡
  0x02C6: 0x88, 0x2030: 0x89, 0x0160: 0x8A, 0x2039: 0x8B, 0x0152: 0x8C, 0x017D: 0x8E, // ˆ ‰ Š ‹ Œ Ž
  0x2018: 0x91, 0x2019: 0x92, 0x201C: 0x93, 0x201D: 0x94, 0x2022: 0x95, 0x2013: 0x96, 0x2014: 0x97, // ‘ ’ “ ” • – —
  0x02DC: 0x98, 0x2122: 0x99, 0x0161: 0x9A, 0x203A: 0x9B, 0x0153: 0x9C, 0x017E: 0x9E, 0x0178: 0x9F, // ˜ ™ š › œ ž Ÿ
};

/// Characters the fonts have no glyph for, swapped for a plain equivalent.
const Map<int, String> _pdfPlain = {
  0x201B: "'", 0x2032: "'", 0x2033: '"', // reversed quote, primes
  0x2010: '-', 0x2011: '-', 0x2012: '-', 0x2015: '-', 0x2212: '-', // hyphens, figure dash, minus
  0x2009: ' ', 0x202F: ' ', 0x200B: '', 0x200C: '', 0x200D: '', 0xFEFF: '', // thin and zero-width spaces
  0x0132: 'IJ', 0x0133: 'ij', 0x0149: "'n", 0x01A0: 'O', 0x01A1: 'o', 0x01AF: 'U', 0x01B0: 'u',
};

/// Latin Extended-A (U+0100 to U+017F) without accents, one letter per character; '#' = handled elsewhere. So
/// "Łukasz Wójcik" prints as "Lukasz Wójcik" rather than "?ukasz Wójcik".
const String _latinExtA =
    'AaAaAaCcCcCcCcDdDdEeEeEeEeEeGgGgGgGgHhHhIiIiIiIiIi' // U+0100-0131
    '##JjKkkLlLlLlLlLlNnNnNn#NnOoOoOo##RrRrRrSsSsSsSsTtTtTtUuUuUuUuUuUuWwYyYZzZzZzs'; // U+0132-017F

/// Vietnamese letters with stacked accents (U+1EA0 to U+1EF9) without them: "Nguyễn" prints as "Nguyen".
final String _latinVietnamese = '${'Aa' * 12}${'Ee' * 8}${'Ii' * 2}${'Oo' * 12}${'Uu' * 7}${'Yy' * 4}';

/// Makes [v] printable in the built-in fonts: Latin-1 as is, typographic punctuation through WinAnsi, accented letters
/// outside Latin-1 as their plain letter, combining accents dropped. Anything else prints as a question mark.
String _pdfSafe(String v) {
  final out = StringBuffer();
  for (final c in v.runes) {
    if (c < 0x80 || (c >= 0xA0 && c < 0x100)) {
      out.writeCharCode(c);
      continue;
    }
    final win = _winAnsi[c];
    if (win != null) {
      out.writeCharCode(win);
      continue;
    }
    final plain = _pdfPlain[c];
    if (plain != null) {
      out.write(plain);
    } else if (c >= 0x100 && c <= 0x17F && _latinExtA[c - 0x100] != '#') {
      out.write(_latinExtA[c - 0x100]);
    } else if (c >= 0x1EA0 && c <= 0x1EF9) {
      out.write(_latinVietnamese[c - 0x1EA0]);
    } else if (c >= 0x300 && c <= 0x36F) {
      // A combining accent (a name typed as "e" + accent): keep the letter, drop the mark.
    } else {
      out.write('?');
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
  double? letterSpacing,
}) {
  return pw.Text(
    _pdfSafe(text),
    textAlign: align,
    style: pw.TextStyle(
      fontSize: size,
      fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
      color: color ?? _pInk,
      letterSpacing: letterSpacing,
    ),
  );
}

/// A table with a shaded header row that repeats at the top of every page it runs onto, right-aligned [right]
/// columns and an optional bold footer. [boldCols] prints those body columns bold (subtotals); [boldRows] prints those
/// body rows bold under a darker rule (a running subtotal inside a ledger). With [dashZeros] a zero amount in the body
/// prints as a light dash, as on the screen, so the real figures stand out.
pw.Widget _pdfTable(
  List<String> heads,
  List<List<String>> rows, {
  required List<double> flex,
  Set<int> right = const {},
  List<String>? foot,
  double size = 8.5,
  double? headSize,
  double padH = 5,
  Set<int> boldCols = const {},
  Set<int> boldRows = const {},
  bool dashZeros = false,
}) {
  final defaultSize = size;
  final zero = _fmt(0);
  pw.Widget cell(String text, int i, {bool bold = false, PdfColor? color, double? size}) => pw.Padding(
    padding: pw.EdgeInsets.symmetric(horizontal: padH, vertical: 4),
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
      for (var n = 0; n < rows.length; n++)
        pw.TableRow(
          decoration: boldRows.contains(n)
              ? pw.BoxDecoration(border: pw.Border(top: pw.BorderSide(color: _pRule, width: 0.8)))
              : null,
          children: [
            for (var i = 0; i < rows[n].length; i++)
              rows[n][i] == zero && dashZeros
                  ? cell('—', i, color: _pMuted)
                  : cell(
                      rows[n][i],
                      i,
                      bold: boldRows.contains(n) || boldCols.contains(i),
                      color: rows[n][i] == zero || rows[n][i] == '—' ? _pMuted : null,
                    ),
          ],
        ),
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

/// The register's type sizes and widths for its number of figure columns (Letter landscape, 720 pt across, a Jobs
/// column of 0.55). Worked out from Helvetica's widths: each figure column must fit "-$12,345.67" in bold (5.34 em)
/// and its heading's longest word ("commission", 5.84 em bold) unbroken, and the name column "Montgomery-Alexander"
/// (10.3 em). At 13 figure columns (every optional column present) a unit is 46.5 pt: 40.5 pt of text at 3 pt padding.
({double size, double head, double pad, double nameFlex}) _registerType(int figures) {
  if (figures <= 9) return (size: 8.5, head: 8.5, pad: 5, nameFlex: 1.9);
  if (figures <= 11) return (size: 8, head: 7.2, pad: 4, nameFlex: 1.9);
  return (size: 7.4, head: 6.8, pad: 3, nameFlex: 1.95);
}

/// The export's file name: what it is and which pay weeks, e.g. "IOHD Payroll Commission Report Oct 12-18, 2026.pdf",
/// "... Oct 26 - Nov 1, 2026.pdf", "... Dec 28, 2026 - Jan 3, 2027.pdf". Only characters Windows allows in a file name.
String payrollPdfFileName(String start, String end) {
  final a = DateTime.tryParse(start);
  final b = DateTime.tryParse(end);
  const base = 'IOHD Payroll Commission Report';
  if (a == null || b == null) return '$base.pdf';
  final String dates;
  if (a.year != b.year) {
    dates = '${DateFormat('MMM d, yyyy').format(a)} - ${DateFormat('MMM d, yyyy').format(b)}';
  } else if (a.month != b.month) {
    dates = '${DateFormat('MMM d').format(a)} - ${DateFormat('MMM d, yyyy').format(b)}';
  } else if (a.day != b.day) {
    dates = '${DateFormat('MMM d').format(a)}-${b.day}, ${b.year}';
  } else {
    dates = DateFormat('MMM d, yyyy').format(a);
  }
  return '$base $dates.pdf';
}

/// [_buildPayrollPdf] for `compute`: one argument, so it can run on a background isolate.
Future<Uint8List> _buildPayrollPdfJob((_Report, _PdfMeta) job) => _buildPayrollPdf(job.$1, job.$2);

Future<Uint8List> _buildPayrollPdf(_Report r, _PdfMeta meta) async {
  final doc = pw.Document(
    title: payrollPdfFileName(r.start, r.end).replaceAll(RegExp(r'\.pdf$'), ''),
    author: meta.generatedBy.trim().isEmpty ? kCompanyName : meta.generatedBy.trim(),
    creator: '$kAppName $kAppVersion',
  );
  final range = '${_day(r.start, year: true)} to ${_day(r.end, year: true)}';
  const margin = pw.EdgeInsets.fromLTRB(36, 30, 36, 30);

  pw.Widget footer(pw.Context ctx) => pw.Padding(
    padding: const pw.EdgeInsets.only(top: 8),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.end,
      children: [
        pw.Expanded(child: _pt('Payroll commission report  |  $range  |  ${meta.stamp}', size: 7.5, color: _pSubtle)),
        pw.SizedBox(width: 12),
        _pt('${copyrightLine()}  |  Confidential  |  Page ${ctx.pageNumber} of ${ctx.pagesCount}',
            size: 7.5, color: _pSubtle),
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

/// A register (the cover's, one row per person, or a person's own one-row summary) from the shared columns.
pw.Widget _pdfRegister(List<_Tech> techs, List<_RegCol> cols, {bool names = true, bool total = true}) {
  final figures = cols.where((c) => !c.count).length;
  final type = _registerType(figures + (names ? 0 : -2)); // a summary row has no name column: more room per figure
  double sum(double Function(_Tech) f) => techs.fold<double>(0, (s, t) => s + f(t));
  // A zero count is a dash, like a zero amount (and like the screen's register).
  String cellFor(_RegCol c, double v) => c.count ? (v.round() == 0 ? '—' : '${v.round()}') : _fmt(v);
  final offset = names ? 1 : 0;
  return _pdfTable(
    [if (names) 'Technician', for (final c in cols) c.pdfHead],
    [
      for (final t in techs) [if (names) t.name, for (final c in cols) cellFor(c, c.value(t))],
    ],
    flex: [if (names) type.nameFlex, for (final c in cols) c.count ? 0.55 : 1],
    size: type.size,
    headSize: type.head,
    padH: type.pad,
    right: {for (var i = 0; i < cols.length; i++) i + offset},
    boldCols: {
      for (var i = 0; i < cols.length; i++)
        if (cols[i].kind == _ColKind.subtotal || cols[i].kind == _ColKind.total) i + offset,
    },
    dashZeros: true,
    foot: total ? [if (names) 'Total', for (final c in cols) cellFor(c, sum(c.value))] : null,
  );
}

List<pw.Widget> _pdfCover(_Report r, String range, _PdfMeta meta) {
  final cols = _registerColumns(r.techs);
  final due = r.techs.fold<double>(0, (s, t) => s + t.totals.totalDue);
  final jobs = r.techs.fold<int>(0, (n, t) => n + t.jobCount);
  final weeks = r.start.isEmpty || r.end.isEmpty
      ? 0
      : (_daysBetween(_parseDay(r.start)!, _parseDay(r.end)!) + 1) ~/ 7;
  bool has(String head) => cols.any((c) => c.head == head);

  final notes = <String>[
    if (has('Retainage Held')) 'Retainage held counts toward the hurdle but is not paid until it is released.',
    if (has('Other')) 'Other is pay the commission engine counted in the gross that is not one of the columns before it.',
    'A payroll run pays the cash pay less any owed recovered'
        '${has('Retainage Released') ? '; retainage released is listed here but is not part of the run' : ''}. '
        'This report does not record or pay a run, and a job pays in the week it is closed.',
    'The following pages break down every technician: pay weeks, closed jobs, commission line items, advances, '
        'callbacks and retainage releases.',
  ];

  return [
    pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      crossAxisAlignment: pw.CrossAxisAlignment.end,
      children: [
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            _pt(kCompanyName.toUpperCase(), size: 8.5, bold: true, color: _pSlate, letterSpacing: 0.8),
            pw.SizedBox(height: 4),
            _pt('Payroll Commission Report', size: 22, bold: true),
            pw.SizedBox(height: 4),
            _pt('Pay weeks $range', size: 11, color: _pSlate),
          ],
        ),
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            _pt('Total due', size: 9, color: _pSlate),
            _pt(_fmt(due), size: 20, bold: true, color: due < 0 ? _pRed : _pGreen),
          ],
        ),
      ],
    ),
    pw.SizedBox(height: 6),
    _pt(
      [
        '${r.techs.length} ${r.techs.length == 1 ? 'person' : 'people'}',
        '$jobs closed ${jobs == 1 ? 'job' : 'jobs'}',
        if (weeks > 0) '$weeks pay ${weeks == 1 ? 'week' : 'weeks'}',
        meta.stamp,
      ].join('   •   '),
      size: 8.5,
      color: _pSubtle,
    ),
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
    _pdfRegister(r.techs, cols),
    pw.SizedBox(height: 12),
    for (final n in notes) ...[
      _pt(n, size: 8.5, color: _pSubtle),
      pw.SizedBox(height: 3),
    ],
  ];
}

List<pw.Widget> _pdfTech(_Tech t, _Report r, _PdfMeta meta) {
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
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                _pt(t.name, size: 18, bold: true),
                pw.SizedBox(height: 2),
                _pt(
                  '${t.kindLabel.isEmpty ? 'Technician' : t.kindLabel}  |  '
                  '${t.weeks.length} ${t.weeks.length == 1 ? 'pay week' : 'pay weeks'}, '
                  '${t.jobCount} ${t.jobCount == 1 ? 'job' : 'jobs'} closed',
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
  // The person's line of the cover register, with the same columns (those that are zero for them are left out).
  out.add(_pdfRegister([t], _registerColumns([t], jobs: false), names: false, total: false));

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
  final status = meta.weekStatus[w.weekStart];

  // Adds down: the pieces make the weekly gross; the gross less the hurdle and any advances recovered is the cash pay.
  final rest = w.unexplained;
  final ledger = <List<String>>[
    ['Closed-job commission (net to tech)', _fmt(w.jobNet)],
    if (w.hurdleCredit > 0) ['Retainage held this week (counts toward the hurdle, not paid now)', _fmt(w.hurdleCredit)],
    if (w.advancesPaid != 0) ['Advances paid', _fmt(w.advancesPaid)],
    if (w.callbackPay != 0) ['Callback pay', _fmt(w.callbackPay)],
    if (w.repPay != 0) ['Sales commission (closed jobs)', _fmt(w.repPay)],
    if (rest.abs() >= 0.05) ['Other adjustments', _fmt(rest)],
  ];
  final grossRow = ledger.length;
  ledger.add(['Weekly gross', _fmt(w.weeklyGross)]);
  if (w.hurdleRule > 0 || w.hurdleApplied != 0) ledger.add(['Weekly hurdle', _fmt(-w.hurdleApplied)]);
  if (w.advanceRecovered > 0) {
    ledger.add(["Advances recovered (a job's share didn't cover its advance days)", _fmt(-w.advanceRecovered)]);
  }

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
        width: 380,
        child: _pdfTable(
          const ['Pay week ledger', 'Amount'],
          ledger,
          flex: const [3.6, 1.2],
          right: const {1},
          boldRows: {grossRow},
          foot: ['Cash pay for the week', _fmt(w.cashPay)],
        ),
      ),
      ledger.length,
    ),
  );

  // Advance shortfall still owed from earlier weeks comes out of this week's run, as on the screen.
  if (w.carryRecovered > 0) {
    out.add(pw.SizedBox(height: 6));
    out.add(
      pw.SizedBox(
        width: 380,
        child: _pdfTable(
          const ['After earlier weeks', 'Amount'],
          [
            ['Cash pay for the week', _fmt(w.cashPay)],
            [
              'Owed from earlier weeks (${_fmt(w.carryIn)} coming in), '
                  '${w.carryProjected ? "recovered by this week's run (projected until finalized)" : "recovered in this week's run"}',
              _fmt(-w.carryRecovered),
            ],
          ],
          flex: const [3.6, 1.2],
          right: const {1},
          foot: ['Paid after recovery', _fmt(w.cashPay - w.carryRecovered)],
        ),
      ),
    );
  }

  // Balances that are not part of this week's sum, said in words so nobody adds them in.
  final owedNotes = [
    if (w.carryIn > 0 && w.carryRecovered <= 0)
      'Owed from earlier weeks: ${_fmt(w.carryIn)}. Nothing could be taken this week; a later run with pay recovers it.',
    if (w.advanceShortfall > 0)
      'Advance shortfall carried forward: ${_fmt(w.advanceShortfall)}. Not part of this week\'s pay; a later payroll '
          'run recovers it.',
  ];
  for (final n in owedNotes) {
    out.add(pw.SizedBox(height: 4));
    out.add(_pt(n, size: 8.5, bold: true, color: _pAmber));
  }

  // Oldest finished job first: ordered by the last day worked (completion), not the day the job was closed.
  String completedOn(_Job j) =>
      j.lastWorked.isNotEmpty ? j.lastWorked : (j.firstWorked.isNotEmpty ? j.firstWorked : j.closedOn);
  final jobsInOrder = [...w.jobs]
    ..sort((a, b) {
      final ca = completedOn(a), cb = completedOn(b);
      // Jobs with no work date go last.
      if (ca.isEmpty != cb.isEmpty) return ca.isEmpty ? 1 : -1;
      final c = ca.compareTo(cb);
      if (c != 0) return c;
      final f = a.firstWorked.compareTo(b.firstWorked);
      return f != 0 ? f : a.jobId.compareTo(b.jobId);
    });
  for (final j in jobsInOrder) {
    out.add(pw.SizedBox(height: 10));
    out.add(_pdfJob(j, r));
  }

  if (w.advances.isNotEmpty || w.callbacks.isNotEmpty) {
    out.add(pw.SizedBox(height: 10));
    final days = [...w.advances, ...w.callbacks];
    out.add(
      _pdfTable(
        const ['Date', 'Type', 'Job', 'Customer', 'Amount'],
        [
          for (final a in w.advances) [_day(a.date), 'Advance day', a.jobId, a.customer, _fmt(a.amount)],
          for (final c in w.callbacks) [_day(c.date), 'Callback', c.jobId, c.customer, _fmt(c.amount)],
        ],
        flex: const [1, 1.4, 1.6, 4, 1.2],
        right: const {4},
        foot: [
          '',
          '',
          '',
          days.length == 1 ? 'Total' : 'Total, ${days.length} days',
          _fmt(days.fold<double>(0, (s, d) => s + d.amount)),
        ],
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
        foot: ['', '', '', 'Sales commission', '', '', _fmt(w.repPay)],
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
        l.isPool ? l.poolLabel(r.companyPoolRate) : l.name,
        l.isPool ? '' : l.category,
        _fmt(l.jobAmount),
        _pct(j.splitPct),
        _fmt(l.techShare),
      ],
    if (j.adjustment != 0)
      [j.adjustment < 0 ? 'Pool cap: held back, not paid out' : 'Adjustment', '', '', '', _fmt(j.adjustment)],
    // The whole job's deposit (every tech's slice), so it goes under Job line: under Tech share it read as pay.
    if (j.toCompanyPool > 0) ['Sent to company pool from this job', '', _fmt(j.toCompanyPool), '', ''],
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

/// [_pdfSafe] for tests: what a string turns into in the PDF's built-in fonts.
@visibleForTesting
String payrollPdfSafeForTest(String v) => _pdfSafe(v);
