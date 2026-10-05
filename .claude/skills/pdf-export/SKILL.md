---
name: pdf-export
description: Generate, print or share PDF reports from the IOHD app with the pdf and printing packages (payroll registers, estimates, invoices, dashboard exports). Use when asked to add an export/print/download PDF button, change the payroll PDF, or fix PDF layout, fonts or missing characters.
---

# PDF export

Reference: `lib/payroll_pdf.dart` (a `part of 'payroll_screen.dart'`): cover register + one section
per technician, with helpers `_pt` (text), `_pdfTable` (striped table with right-aligned numeric
columns and a footer), a `PdfColor` palette mirroring `DashUi`, and `Printing.layoutPdf(...)` in `payroll_screen.dart`.

## Pattern

```dart
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

Future<void> exportThing(BuildContext context, Thing data) async {
  final doc = pw.Document(title: 'Invoice ${data.number}', author: 'IOHD');
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.letter,               // US company: Letter, not A4
    margin: const pw.EdgeInsets.all(36),
    header: (ctx) => _header(data),
    footer: (ctx) => pw.Align(
      alignment: pw.Alignment.centerRight,
      child: _pt('Page ${ctx.pageNumber} of ${ctx.pagesCount}', size: 8, color: _pMuted),
    ),
    build: (ctx) => [ /* sections, _pdfTable(...) */ ],
  ));
  await Printing.layoutPdf(name: 'invoice-${data.number}.pdf', onLayout: (_) => doc.save());
}
```

## Rules

- Use `MultiPage` for anything that can grow, so tables break across pages. Set `pw.Table` header rows
  to repeat (`repeatHeader` / put the header inside the table).
- **Fonts**: the built-in Helvetica only covers Latin-1. Run every string through `_pdfSafe` (as in
  `payroll_pdf.dart`) or embed a TTF via `PdfGoogleFonts`/an asset font if names can contain
  accents or symbols. Don't let a customer name print as `?` silently.
- Reuse the dashboard palette (ink/slate/muted/line + green/red for money) so exports look like the app.
- Right-align money columns, show totals in a bold footer row, and use the same money format as the UI (`dashMoney`).
- Every report shows: the title, the date range or period, "Generated <date> by <AuthSession.instance.name>", and page numbers.
- File names: `kebab-case-<period>.pdf` (e.g. `payroll-2026-09-29_2026-10-05.pdf`).
- Build the document off the UI path. Show a progress state on the export button (see `ux-states`)
  and catch errors with a snackbar.
- Payroll/commission PDFs contain pay data. Don't log them or write them to temp paths beyond what `printing` does.
