// Builds the real payroll PDF from fake reports and saves it to build/payroll_pdf/ (gitignored) so the pages can be
// looked at. Run:  flutter test test/payroll_pdf_test.dart
//
// To see the pages as images, render the saved PDFs with any PDF viewer (or PyMuPDF). The checks here are structural;
// the money in the PDF comes straight from the report and is checked against it by text in the page content.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/payroll_screen.dart';

import 'payroll_fixture.dart';

void main() {
  final out = Directory('build/payroll_pdf')..createSync(recursive: true);
  final at = DateTime(2026, 10, 21, 9, 30);

  Future<List<int>> build(
    String name,
    Map<String, dynamic> report, {
    Map<String, ({String label, bool paid})>? status,
  }) async {
    final bytes = await buildPayrollPdfForTest(
      report,
      generatedAt: at,
      generatedBy: 'Heather Vera',
      weekStatus: status ?? const {},
    );
    File('${out.path}/$name.pdf').writeAsBytesSync(bytes);
    return bytes;
  }

  Map<String, dynamic> report(int weeks) =>
      jsonDecode(payrollReport(DateTime(2026, 10, 18), weeks)) as Map<String, dynamic>;

  test('one pay week, with run statuses and typographic punctuation in names', () async {
    final r = report(1);
    // Service Fusion names often carry smart quotes and dashes; they must not print as question marks.
    final first = ((r['techs'] as List).first as Map)['weeks'][0]['jobs'][0] as Map;
    first['customer'] = 'Shannon O’Brien – “Main St” garage';
    final bytes = await build('one_week', r, status: {'2026-10-12': (label: 'Not run yet', paid: false)});
    expect(utf8.decode(bytes.take(5).toList()), '%PDF-');
  });

  test('eleven pay weeks', () async {
    final bytes = await build(
      'eleven_weeks',
      report(11),
      status: {
        '2026-10-05': (label: 'Paid · run #9 · Oct 13', paid: true),
        '2026-10-12': (label: 'Not run yet', paid: false),
      },
    );
    expect(bytes.length, greaterThan(1000));
  });

  test('a person with nothing in range, and an empty report', () async {
    final r = report(1);
    final t = (r['techs'] as List).first as Map;
    t['weeks'] = <dynamic>[];
    t['retainageReleases'] = <dynamic>[];
    t['totals'] = <String, dynamic>{};
    await build('sparse', r);
    await build('empty', {...report(1), 'techs': <dynamic>[]});
  });
}
