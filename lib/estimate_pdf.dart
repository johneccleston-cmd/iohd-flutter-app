import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'config/app_info.dart';
import 'utils/line_item_math.dart';
import 'widgets/app_ribbon.dart';
import 'widgets/dashboard_kit.dart';

// The customer's copy of an estimate: one PDF with every option as an alternative package for the same project,
// a side-by-side comparison first when there is more than one, then each option's lines and totals.
//
// Only selling figures are printed. This file never reads a line's cost (or anything worked out from it), so internal
// cost, profit and margin cannot reach a customer. test/estimate_pdf_test.dart checks the printed text for them.

/// One option as the customer sees it.
class ProposalOption {
  final String name;
  final bool recommended;
  final bool accepted;
  final List<LineDraft> lines;
  final double? taxRate;
  final String notes;
  const ProposalOption({required this.name, required this.lines, this.taxRate, this.recommended = false, this.accepted = false, this.notes = ''});
}

class ProposalInput {
  final String estimateId;
  final String customer;
  final String contact;
  final String location;
  final String description;
  final String preparedBy;
  final DateTime date;
  final List<ProposalOption> options;
  const ProposalInput({
    required this.estimateId,
    required this.customer,
    this.contact = '',
    this.location = '',
    this.description = '',
    this.preparedBy = '',
    required this.date,
    required this.options,
  });
}

final PdfColor _ink = PdfColor.fromInt(0xFF0F172A);
final PdfColor _slate = PdfColor.fromInt(0xFF475569);
final PdfColor _subtle = PdfColor.fromInt(0xFF64748B);
final PdfColor _line = PdfColor.fromInt(0xFFE2E8F0);
final PdfColor _faint = PdfColor.fromInt(0xFFF1F5F9);
final PdfColor _red = PdfColor.fromInt(0xFFB91C1C);
final PdfColor _green = PdfColor.fromInt(0xFF047857);
final PdfColor _brand = PdfColor.fromInt(0xFFCC0007);

/// Typographic punctuation the built-in fonts lack, swapped for plain equivalents.
const Map<int, String> _plain = {
  0x2018: "'", 0x2019: "'", 0x201C: '"', 0x201D: '"', 0x2032: "'", 0x2033: '"', //
  0x2013: '-', 0x2014: '-', 0x2212: '-', 0x2026: '...', 0x2022: '-', 0x00AE: '(R)', 0x2122: '(TM)', 0x00A0: ' ',
};

String _safe(String v) {
  final out = StringBuffer();
  for (final c in v.runes) {
    final p = _plain[c];
    if (p != null) {
      out.write(p);
    } else if (c == 0x0D) {
      continue;
    } else {
      out.writeCharCode(c < 256 ? c : 0x3F);
    }
  }
  return out.toString();
}

pw.Widget _t(String text, {double size = 9.5, bool bold = false, PdfColor? color, pw.TextAlign align = pw.TextAlign.left, double? height}) => pw.Text(
  _safe(text),
  textAlign: align,
  style: pw.TextStyle(fontSize: size, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal, color: color ?? _ink, lineSpacing: height),
);

String _rate(double r) => r.toStringAsFixed(4).replaceFirst(RegExp(r'\.?0+$'), '');

/// Builds the PDF. [compress] is only turned off by tests, so the printed text can be read back.
Future<Uint8List> buildProposalPdf(ProposalInput input, {bool compress = true}) async {
  final doc = pw.Document(
    compress: compress,
    title: 'Estimate ${input.estimateId}',
    author: kCompanyName,
    creator: '$kAppName $kAppVersion',
  );
  final options = input.options.where((o) => o.lines.isNotEmpty).toList();
  final many = options.length > 1;
  final dateText = DateFormat('MMMM d, y').format(input.date);

  pw.Widget header(pw.Context ctx) => pw.Container(
    padding: const pw.EdgeInsets.only(bottom: 10),
    margin: const pw.EdgeInsets.only(bottom: 14),
    decoration: pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: _brand, width: 2))),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.end,
      children: [
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              _t(kCompanyBrand, size: 17, bold: true),
              pw.SizedBox(height: 2),
              _t(many ? 'Proposal with ${options.length} options' : 'Proposal', size: 10, color: _slate),
            ],
          ),
        ),
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            _t('Estimate #${input.estimateId}', size: 11, bold: true),
            _t(dateText, size: 9.5, color: _slate),
            if (input.preparedBy.trim().isNotEmpty) _t('Prepared by ${input.preparedBy.trim()}', size: 9.5, color: _slate),
          ],
        ),
      ],
    ),
  );

  pw.Widget footer(pw.Context ctx) => pw.Padding(
    padding: const pw.EdgeInsets.only(top: 10),
    child: pw.Row(
      children: [
        pw.Expanded(child: _t(copyrightLine(), size: 8, color: _subtle)),
        _t('Page ${ctx.pageNumber} of ${ctx.pagesCount}', size: 8, color: _subtle),
      ],
    ),
  );

  pw.Widget field(String label, String value) => value.trim().isEmpty
      ? pw.SizedBox()
      : pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 3),
          child: pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.SizedBox(width: 78, child: _t(label, size: 9, color: _subtle)),
              pw.Expanded(child: _t(value.trim(), size: 9.5)),
            ],
          ),
        );

  pw.Widget badge(String text, PdfColor color) => pw.Container(
    margin: const pw.EdgeInsets.only(left: 6),
    padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: pw.BoxDecoration(border: pw.Border.all(color: color, width: 0.8), borderRadius: pw.BorderRadius.circular(8)),
    child: _t(text, size: 7.5, bold: true, color: color),
  );

  pw.Widget comparison() => pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      _t('Your options', size: 12, bold: true),
      pw.SizedBox(height: 3),
      _t(
        'These are alternative packages for the same project. Choose the one that suits you best; you only pay for the option you choose.',
        size: 9.5,
        color: _slate,
      ),
      pw.SizedBox(height: 8),
      pw.Table(
        border: pw.TableBorder(horizontalInside: pw.BorderSide(color: _line), bottom: pw.BorderSide(color: _line), top: pw.BorderSide(color: _line)),
        columnWidths: const {0: pw.FlexColumnWidth(5), 1: pw.FlexColumnWidth(2), 2: pw.FlexColumnWidth(2.2)},
        children: [
          pw.TableRow(
            decoration: pw.BoxDecoration(color: _faint),
            children: [
              pw.Padding(padding: const pw.EdgeInsets.all(6), child: _t('Option', size: 9, bold: true, color: _slate)),
              pw.Padding(padding: const pw.EdgeInsets.all(6), child: _t('Lines', size: 9, bold: true, color: _slate, align: pw.TextAlign.right)),
              pw.Padding(padding: const pw.EdgeInsets.all(6), child: _t('Total', size: 9, bold: true, color: _slate, align: pw.TextAlign.right)),
            ],
          ),
          for (final o in options)
            pw.TableRow(
              children: [
                pw.Padding(
                  padding: const pw.EdgeInsets.all(6),
                  child: pw.Row(
                    children: [
                      pw.Flexible(child: _t(o.name, size: 10, bold: true)),
                      if (o.accepted) badge('ACCEPTED', _green),
                      if (o.recommended && !o.accepted) badge('RECOMMENDED', _brand),
                    ],
                  ),
                ),
                pw.Padding(
                  padding: const pw.EdgeInsets.all(6),
                  child: _t('${o.lines.where((l) => !l.isDiscount).length}', size: 10, align: pw.TextAlign.right, color: _slate),
                ),
                pw.Padding(
                  padding: const pw.EdgeInsets.all(6),
                  child: _t(centsMoney(computeLineTotals(o.lines, o.taxRate).totalCents), size: 10.5, bold: true, align: pw.TextAlign.right),
                ),
              ],
            ),
        ],
      ),
      pw.SizedBox(height: 18),
    ],
  );

  List<pw.Widget> optionSection(ProposalOption o, int i) {
    final t = computeLineTotals(o.lines, o.taxRate);
    pw.Widget cell(String s, {bool right = false, bool bold = false, PdfColor? color}) =>
        pw.Padding(padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 5), child: _t(s, size: 9.5, bold: bold, color: color, align: right ? pw.TextAlign.right : pw.TextAlign.left));
    pw.Widget sum(String label, int cents, {bool strong = false, PdfColor? color}) => pw.Padding(
      padding: const pw.EdgeInsets.only(top: 3),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.end,
        children: [
          pw.SizedBox(width: 150, child: _t(label, size: strong ? 11 : 9.5, bold: strong, color: strong ? _ink : _slate, align: pw.TextAlign.right)),
          pw.SizedBox(width: 90, child: _t(centsMoney(cents), size: strong ? 11.5 : 9.5, bold: strong, color: color, align: pw.TextAlign.right)),
        ],
      ),
    );
    return [
      pw.Container(
        margin: pw.EdgeInsets.only(top: i == 0 ? 0 : 16, bottom: 6),
        padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: pw.BoxDecoration(color: _faint, borderRadius: pw.BorderRadius.circular(4)),
        child: pw.Row(
          children: [
            pw.Expanded(child: _t(many ? 'Option ${i + 1}: ${o.name}' : o.name, size: 11.5, bold: true)),
            if (o.accepted) badge('ACCEPTED', _green),
            if (o.recommended && !o.accepted) badge('RECOMMENDED', _brand),
          ],
        ),
      ),
      pw.Table(
        border: pw.TableBorder(horizontalInside: pw.BorderSide(color: _line, width: 0.6), bottom: pw.BorderSide(color: _line)),
        columnWidths: const {0: pw.FlexColumnWidth(6), 1: pw.FixedColumnWidth(46), 2: pw.FixedColumnWidth(72), 3: pw.FixedColumnWidth(80)},
        children: [
          pw.TableRow(
            children: [
              cell('Item', bold: true, color: _slate),
              cell('Qty', right: true, bold: true, color: _slate),
              cell('Rate', right: true, bold: true, color: _slate),
              cell('Amount', right: true, bold: true, color: _slate),
            ],
          ),
          for (var k = 0; k < o.lines.length; k++)
            pw.TableRow(
              verticalAlignment: pw.TableCellVerticalAlignment.top,
              children: [
                pw.Padding(
                  padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 5),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      _t(o.lines[k].name, size: 9.5, bold: true, color: o.lines[k].isDiscount ? _red : _ink),
                      if (o.lines[k].description.trim().isNotEmpty)
                        pw.Padding(padding: const pw.EdgeInsets.only(top: 2), child: _t(o.lines[k].description.trim(), size: 8.5, color: _slate, height: 1.5)),
                    ],
                  ),
                ),
                cell(o.lines[k].isDiscount ? '' : qtyText(o.lines[k].quantity), right: true),
                cell(o.lines[k].isDiscount || o.lines[k].rate == null ? '' : centsMoney((o.lines[k].rate! * 100).round()), right: true),
                cell(centsMoney(t.lines[k].amountCents), right: true, bold: true, color: o.lines[k].isDiscount ? _red : null),
              ],
            ),
        ],
      ),
      pw.SizedBox(height: 4),
      sum('Subtotal', t.itemsCents),
      if (t.discountCents > 0) sum('Discounts', -t.discountCents, color: _red),
      if (o.taxRate != null) sum('Sales tax (${_rate(o.taxRate!)}%)', t.taxCents),
      sum('Total', t.totalCents, strong: true),
      if (o.notes.trim().isNotEmpty) ...[pw.SizedBox(height: 8), _t(o.notes.trim(), size: 9.5, color: _slate, height: 1.5)],
    ];
  }

  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.letter,
      margin: const pw.EdgeInsets.fromLTRB(40, 34, 40, 30),
      header: header,
      footer: footer,
      build: (ctx) => [
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  _t('Prepared for', size: 9, bold: true, color: _subtle),
                  pw.SizedBox(height: 3),
                  _t(input.customer, size: 12, bold: true),
                  if (input.contact.trim().isNotEmpty) _t(input.contact.trim(), size: 9.5, color: _slate),
                ],
              ),
            ),
            pw.SizedBox(width: 20),
            pw.Expanded(child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [field('Job site', input.location)])),
          ],
        ),
        if (input.description.trim().isNotEmpty) ...[pw.SizedBox(height: 10), field('Project', input.description)],
        pw.SizedBox(height: 16),
        if (options.isEmpty) _t('This estimate has no line items yet.', size: 10, color: _slate),
        if (many) comparison(),
        for (var i = 0; i < options.length; i++) ...optionSection(options[i], i),
      ],
    ),
  );
  return doc.save();
}

/// The proposal in a preview window, with Print and Save as PDF.
Future<void> showProposalPdf(BuildContext context, ProposalInput input) {
  final fileName = 'Estimate-${input.estimateId}.pdf';
  return showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.all(24),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 980),
        child: Column(
          children: [
            AppRibbon(
              title: 'CUSTOMER PROPOSAL',
              kind: 'ESTIMATE ${input.estimateId}',
              icon: Icons.picture_as_pdf_outlined,
              controls: [
                IconButton(
                  tooltip: 'Save as PDF',
                  icon: const Icon(Icons.download_rounded),
                  onPressed: () async {
                    final bytes = await buildProposalPdf(input);
                    await FilePicker.saveFile(fileName: fileName, bytes: bytes, type: FileType.custom, allowedExtensions: const ['pdf']);
                  },
                ),
                IconButton(
                  tooltip: 'Print',
                  icon: const Icon(Icons.print_rounded),
                  onPressed: () => Printing.layoutPdf(name: fileName, onLayout: (_) => buildProposalPdf(input)),
                ),
                IconButton(tooltip: 'Close', icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.of(ctx).pop()),
              ],
            ),
            Expanded(
              child: PdfPreview(
                build: (_) => buildProposalPdf(input),
                useActions: false,
                canChangePageFormat: false,
                canChangeOrientation: false,
                canDebug: false,
                pdfFileName: fileName,
                scrollViewDecoration: const BoxDecoration(color: DashUi.line),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
