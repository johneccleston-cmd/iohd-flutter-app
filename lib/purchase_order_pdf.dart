import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'config/app_info.dart';
import 'config/auth_session.dart';
import 'purchase_orders_api.dart';
import 'utils/line_item_math.dart' show centsMoney;
import 'widgets/app_ribbon.dart';
import 'widgets/dashboard_kit.dart';

// The vendor's copy of a purchase order: who it is from, what is ordered at what cost, the totals and any notes.
// Letter size, laid out like the customer proposal (estimate_pdf.dart) so the company's printouts match.

final PdfColor _ink = PdfColor.fromInt(0xFF111111);
final PdfColor _slate = PdfColor.fromInt(0xFF505050);
final PdfColor _subtle = PdfColor.fromInt(0xFF6B6B6B);
final PdfColor _line = PdfColor.fromInt(0xFFE4E4E4);
final PdfColor _faint = PdfColor.fromInt(0xFFF2F2F2);
final PdfColor _brand = PdfColor.fromInt(0xFFCC0007);

/// Typographic punctuation the built-in fonts lack, swapped for plain equivalents.
const Map<int, String> _plain = {
  0x2018: "'", 0x2019: "'", 0x201C: '"', 0x201D: '"', 0x2032: "'", 0x2033: '"', //
  0x2013: '-', 0x2014: '-', 0x2212: '-', 0x2026: '...', 0x2022: '-', 0x00D7: 'x', 0x00AE: '(R)', 0x2122: '(TM)', 0x00A0: ' ',
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

String purchaseOrderPdfFileName(PurchaseOrder po) => '${po.poNumber.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '-')}.pdf';

/// Builds the PDF. [compress] is only turned off by tests, so the printed text can be read back.
Future<Uint8List> buildPurchaseOrderPdf(PurchaseOrder po, {String? preparedBy, DateTime? printed, bool compress = true}) async {
  final doc = pw.Document(compress: compress, title: 'Purchase order ${po.poNumber}', author: kCompanyName, creator: '$kAppName $kAppVersion');
  final date = DateFormat('MMMM d, y');
  final by = (preparedBy ?? AuthSession.instance.name).trim();

  pw.Widget header(pw.Context ctx) => pw.Container(
    padding: const pw.EdgeInsets.only(bottom: 10),
    margin: const pw.EdgeInsets.only(bottom: 16),
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
              _t(po.isDraft ? 'Purchase order (draft)' : 'Purchase order', size: 10, color: _slate),
            ],
          ),
        ),
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            _t(po.poNumber, size: 13, bold: true),
            if (po.orderDate != null) _t('Ordered ${date.format(po.orderDate!)}', size: 9.5, color: _slate),
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
        _t('${po.poNumber}  -  Page ${ctx.pageNumber} of ${ctx.pagesCount}', size: 8, color: _subtle),
      ],
    ),
  );

  pw.Widget fact(String label, String value) => value.trim().isEmpty
      ? pw.SizedBox()
      : pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 3),
          child: pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.SizedBox(width: 92, child: _t(label, size: 9, color: _subtle)),
              pw.Expanded(child: _t(value.trim(), size: 9.5, bold: true)),
            ],
          ),
        );

  pw.Widget cell(String s, {bool right = false, bool bold = false, PdfColor? color, double size = 9.5}) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 5),
    child: _t(s, size: size, bold: bold, color: color, align: right ? pw.TextAlign.right : pw.TextAlign.left),
  );

  pw.Widget sum(String label, int cents, {bool strong = false}) => pw.Padding(
    padding: const pw.EdgeInsets.only(top: 3),
    child: pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.end,
      children: [
        pw.SizedBox(width: 150, child: _t(label, size: strong ? 11 : 9.5, bold: strong, color: strong ? _ink : _slate, align: pw.TextAlign.right)),
        pw.SizedBox(width: 90, child: _t(centsMoney(cents), size: strong ? 11.5 : 9.5, bold: strong, align: pw.TextAlign.right)),
      ],
    ),
  );

  final partsCents = po.lines.fold<int>(0, (s, l) => s + l.amountCents);
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
                  _t('Vendor', size: 9, bold: true, color: _subtle),
                  pw.SizedBox(height: 3),
                  _t(po.vendor, size: 13, bold: true),
                  if (po.vendorRef.trim().isNotEmpty) _t('Your order # ${po.vendorRef.trim()}', size: 9.5, color: _slate),
                ],
              ),
            ),
            pw.SizedBox(width: 24),
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  fact('PO number', po.poNumber),
                  if (po.orderDate != null) fact('Order date', date.format(po.orderDate!)),
                  if (po.expectedDate != null) fact('Needed by', date.format(po.expectedDate!)),
                  fact('Our job #', po.jobNumber),
                  fact('Ordered by', by),
                ],
              ),
            ),
          ],
        ),
        pw.SizedBox(height: 18),
        if (po.lines.isEmpty) ...[
          _t('No parts are listed on this purchase order.', size: 10, color: _slate),
          pw.SizedBox(height: 8),
          sum('Total', (po.total * 100).round(), strong: true),
        ] else ...[
          pw.Table(
            border: pw.TableBorder(horizontalInside: pw.BorderSide(color: _line, width: 0.6), bottom: pw.BorderSide(color: _line)),
            columnWidths: const {
              0: pw.FixedColumnWidth(22),
              1: pw.FlexColumnWidth(6),
              2: pw.FixedColumnWidth(58),
              3: pw.FixedColumnWidth(74),
              4: pw.FixedColumnWidth(80),
            },
            children: [
              pw.TableRow(
                decoration: pw.BoxDecoration(color: _faint),
                children: [
                  cell('#', bold: true, color: _slate),
                  cell('Item', bold: true, color: _slate),
                  cell('Qty', right: true, bold: true, color: _slate),
                  cell('Unit cost', right: true, bold: true, color: _slate),
                  cell('Amount', right: true, bold: true, color: _slate),
                ],
              ),
              for (var i = 0; i < po.lines.length; i++)
                pw.TableRow(
                  verticalAlignment: pw.TableCellVerticalAlignment.top,
                  children: [
                    cell('${i + 1}', color: _subtle),
                    pw.Padding(
                      padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 5),
                      child: pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: [
                          _t(po.lines[i].name, size: 9.5, bold: true),
                          if (po.lines[i].sku.trim().isNotEmpty)
                            pw.Padding(padding: const pw.EdgeInsets.only(top: 1), child: _t('Part # ${po.lines[i].sku.trim()}', size: 8.5, color: _slate)),
                        ],
                      ),
                    ),
                    cell(poQty(po.lines[i].qty), right: true),
                    cell(centsMoney((po.lines[i].unitCost * 100).round()), right: true),
                    cell(centsMoney(po.lines[i].amountCents), right: true, bold: true),
                  ],
                ),
            ],
          ),
          pw.SizedBox(height: 4),
          sum('Parts', partsCents),
          if (po.shipping > 0) sum('Shipping & fees', (po.shipping * 100).round()),
          sum('Total', (po.total * 100).round(), strong: true),
        ],
        if (po.notes.trim().isNotEmpty) ...[
          pw.SizedBox(height: 16),
          _t('Notes', size: 9, bold: true, color: _subtle),
          pw.SizedBox(height: 3),
          _t(po.notes.trim(), size: 9.5, color: _slate, height: 1.5),
        ],
        pw.SizedBox(height: 22),
        _t(
          'Please confirm this order and its delivery date, and put ${po.poNumber} on the packing slip and invoice.',
          size: 9,
          color: _slate,
        ),
        _t('Printed ${date.format(printed ?? DateTime.now())}${by.isEmpty ? '' : ' by $by'}', size: 8, color: _subtle),
      ],
    ),
  );
  return doc.save();
}

/// The PO in a preview window, with Save as PDF and Print.
Future<void> showPurchaseOrderPdf(BuildContext context, PurchaseOrder po) {
  final fileName = purchaseOrderPdfFileName(po);
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
              title: 'PURCHASE ORDER',
              kind: po.poNumber.toUpperCase(),
              icon: Icons.picture_as_pdf_outlined,
              controls: [
                IconButton(
                  tooltip: 'Save as PDF',
                  color: Colors.white,
                  icon: const Icon(Icons.download_rounded),
                  onPressed: () async {
                    final bytes = await buildPurchaseOrderPdf(po);
                    await FilePicker.saveFile(fileName: fileName, bytes: bytes, type: FileType.custom, allowedExtensions: const ['pdf']);
                  },
                ),
                IconButton(
                  tooltip: 'Print',
                  color: Colors.white,
                  icon: const Icon(Icons.print_rounded),
                  onPressed: () => Printing.layoutPdf(name: fileName, onLayout: (_) => buildPurchaseOrderPdf(po)),
                ),
                IconButton(tooltip: 'Close', color: Colors.white, icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.of(ctx).pop()),
              ],
            ),
            Expanded(
              child: PdfPreview(
                build: (_) => buildPurchaseOrderPdf(po),
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
