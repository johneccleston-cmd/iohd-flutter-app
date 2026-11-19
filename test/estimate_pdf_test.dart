// The customer's proposal PDF (lib/estimate_pdf.dart): every option as an alternative, the right totals, and never
// an internal cost, profit or margin. Saves the PDFs to build/estimate_pdf/ to look at.
//   flutter test test/estimate_pdf_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/estimate_pdf.dart';
import 'package:iohd_desktop/utils/line_item_math.dart';

/// The text drawn on the pages, as one run of words: with compression off and the built-in fonts, the pdf package
/// draws each word as its own "[(word)]TJ".
String _printed(List<int> bytes) {
  final raw = latin1.decode(bytes);
  return [
    for (final m in RegExp(r'\[\(((?:\\.|[^\\)])*)\)\]TJ').allMatches(raw)) m.group(1)!.replaceAllMapped(RegExp(r'\\(.)'), (x) => x.group(1)!),
  ].join(' ');
}

void main() {
  final out = Directory('build/estimate_pdf')..createSync(recursive: true);

  const standard = ProposalOption(
    name: 'Standard',
    taxRate: 10.5,
    lines: [
      LineDraft(name: 'SMH | Gallery Steel | GD5S | Complete Door | Sandtone (Clay)', description: '16x7 GD5S complete door', quantity: 1, rate: 527.72, cost: 507.16, taxable: true),
      LineDraft(name: 'Stop Mold | 7\' Sandtone', quantity: 2, rate: 4.46, cost: 4.46, taxable: true),
      LineDraft(name: 'SMH Installation | Gallery Steel | 16x7 | Sandtone', quantity: 1, rate: 300, cost: 211.11),
    ],
  );
  final premium = ProposalOption(
    name: 'Premium',
    recommended: true,
    taxRate: 10.5,
    notes: 'Includes the smart opener and a 10-year labor warranty.',
    lines: [
      ...standard.lines,
      const LineDraft(name: 'LiftMaster 87504 Smart Opener', quantity: 1, rate: 689, cost: 401.37, taxable: true),
      const LineDraft(name: 'Loyal customer discount', kind: LineKind.discount, rate: 50),
    ],
  );

  ProposalInput input(List<ProposalOption> options) => ProposalInput(
    estimateId: '1093839956',
    customer: 'Schuber Mitchell Homes',
    contact: 'Dana Whitfield',
    location: '1204 W Poplar St, Rogers, AR 72756',
    description: 'Replace the garage door on lot 14.',
    preparedBy: 'Heather Vera',
    date: DateTime(2026, 11, 3),
    options: options,
  );

  test('two options: comparison, each option, the right totals, and no cost anywhere', () async {
    final bytes = await buildProposalPdf(input([standard, premium]), compress: false);
    File('${out.path}/two_options.pdf').writeAsBytesSync(await buildProposalPdf(input([standard, premium])));
    expect(utf8.decode(bytes.take(5).toList()), '%PDF-');
    final text = _printed(bytes);

    expect(text, contains('Your options'));
    expect(text, contains('alternative packages for the same project'));
    expect(text, contains('Option 1: Standard'));
    expect(text, contains('Option 2: Premium'));
    expect(text, contains('RECOMMENDED'));
    // Standard: 527.72 + 8.92 + 300 = 836.64; tax 10.5% of 536.64 = 56.35 -> 892.99.
    final s = computeLineTotals(standard.lines, 10.5);
    expect(centsMoney(s.totalCents), r'$892.99');
    expect(text, contains(r'$892.99'));
    // Premium: + 689 taxable, - 50 not taxable: 1525.64 - 50 + 10.5% of 1225.64 (128.69) = 1604.33.
    final p = computeLineTotals(premium.lines, 10.5);
    expect(centsMoney(p.totalCents), r'$1,604.33');
    expect(text, contains(r'$1,604.33'));
    expect(text, contains(r'-$50.00'));
    expect(text, contains('Sales tax (10.5%)'));
    expect(text, contains('Includes the smart opener'));

    // Internal figures never print: not the words, not the unit costs, not the cost or profit totals.
    for (final hidden in ['Cost', 'cost', 'Profit', 'profit', 'Margin', 'margin', r'$507.16', r'$211.11', r'$401.37', centsMoney(s.costCents), centsMoney(p.profitCents!)]) {
      expect(text.contains(hidden), isFalse, reason: '"$hidden" must not be on the customer PDF');
    }
  });

  test('one option: no comparison table, an accepted badge', () async {
    final accepted = ProposalOption(name: 'Standard', accepted: true, taxRate: 10.5, lines: standard.lines);
    final bytes = await buildProposalPdf(input([accepted]), compress: false);
    File('${out.path}/one_option.pdf').writeAsBytesSync(await buildProposalPdf(input([accepted])));
    final text = _printed(bytes);
    expect(text, isNot(contains('Your options')));
    expect(text, contains('ACCEPTED'));
    expect(text, contains(r'$892.99'));
  });

  test('characters the built-in fonts lack do not break the PDF', () async {
    const odd = ProposalOption(name: 'Clopay® “Gallery” – 16’', lines: [LineDraft(name: 'Door — white', description: 'Line 1\r\nLine 2', quantity: 1, rate: 10)]);
    final text = _printed(await buildProposalPdf(input([odd]), compress: false));
    expect(text, contains('Clopay(R) "Gallery" - 16\''));
    expect(text, contains('Door - white'));
  });

  test('an estimate with no lines says so', () async {
    final text = _printed(await buildProposalPdf(input(const []), compress: false));
    expect(text, contains('This estimate has no line items yet.'));
  });

  // The old 9,999.999 quantity cap: Service Fusion's percentage lines carry the dollar base as the quantity, and a return
  // is -1. The Qty column (68 pt since 2026-11-13) shows them whole, on one line, with two decimals, and the totals follow.
  test('quantities above 9,999.999, negative and fractional print whole, with the right amounts', () async {
    const big = ProposalOption(
      name: 'Standard',
      taxRate: 10,
      lines: [
        LineDraft(name: 'Clopay Canyon Ridge | CR13 | 16x7 | Complete Door', quantity: 1, rate: 36000, taxable: true),
        LineDraft(name: '10% Discount (Doors & Openers)', quantity: 35125.3, rate: -0.1),
        LineDraft(name: '5% Discount', quantity: 49376.125, rate: -0.05),
        LineDraft(name: 'Return: Weather Seal | Stop Mold', quantity: -1, rate: 10, taxable: true),
        LineDraft(name: 'Stop Mold | Install New Standard Color', quantity: 68.57, rate: 0.61, taxable: true),
        LineDraft(name: 'Wire rope (per foot)', quantity: 999999.99, rate: 0.01),
        // The widest a quantity can be: typed (two decimals) and stored (a third).
        LineDraft(name: 'Credit', quantity: -999999.99, rate: 0.01),
        LineDraft(name: 'Stored credit', quantity: -999999.999, rate: 0.01),
      ],
    );
    final bytes = await buildProposalPdf(input([big]), compress: false);
    File('${out.path}/big_quantities.pdf').writeAsBytesSync(bytes);
    final words = _printed(bytes).split(' ');
    // Whole words: a quantity broken over two lines prints as two ("-999,999.9" and "9").
    for (final q in ['35,125.30', '49,376.125', '-1.00', '68.57', '999,999.99', '-999,999.99', '-999,999.999']) {
      expect(words, contains(q), reason: 'quantity $q on one line');
    }
    for (final a in [r'-$3,512.53', r'-$2,468.81', r'-$10.00', r'$41.83', r'$10,000.00', r'-$10,000.00']) {
      expect(words, contains(a), reason: 'amount $a');
    }
    // 36,000.00 - 3,512.53 - 2,468.81 - 10.00 + 41.83 + 10,000.00 - 10,000.00 - 10,000.00 = 20,050.49 (-9,999.99999 is
    // -$10,000.00 to the cent); 10% of the 36,031.83 taxed = 3,603.18.
    expect(words, contains(r'$23,653.67'), reason: 'the total');
  });
}
