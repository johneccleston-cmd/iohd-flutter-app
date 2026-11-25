import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'config/api_config.dart';
import 'config/app_info.dart';
import 'config/auth_session.dart';

/// Stock Levels' data: the parts on the Inventory Google Sheet (backend GET /get_full_inventory), a part's history, the
/// checkout names that took nothing off stock, office corrections, and the CSV and PDF the page exports.
/// UI audit 2026-11-25: docs/stock-levels-ui-audit-2026-11-25.md (item numbers in the comments below).

// ---------------------------------------------------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------------------------------------------------

/// Ordered by how much it needs attention: the default sort puts these first. Every status is a stock level (C4, F6):
/// whether the warehouse keeps a minimum is the reorder point column, not the status.
enum StockStatus { negative, out, low, ok, none }

extension StockStatusText on StockStatus {
  /// The status in the table.
  String get label => switch (this) {
    StockStatus.negative => 'Below zero',
    StockStatus.out => 'Out of stock',
    StockStatus.low => 'Low stock',
    StockStatus.ok => 'In stock',
    StockStatus.none => 'None on hand',
  };

  /// The filter list's wording: the same as the table's, so one status has one name (C4).
  String get filterLabel => label;

  /// What the status means, for the part's page and the filter rows' hover text.
  String get meaning => switch (this) {
    StockStatus.negative => 'Below zero: the count on the sheet is wrong and needs checking.',
    StockStatus.out => 'Out of stock: none on hand, and the warehouse keeps a minimum of it.',
    StockStatus.low => 'Low stock: at or below its reorder point.',
    StockStatus.ok => 'In stock: above its reorder point, or on hand with no reorder point set.',
    StockStatus.none => "None on hand, and no reorder point is set: the warehouse doesn't keep a minimum of it, so this is not a shortage.",
  };

  bool get needsAttention => this == StockStatus.negative || this == StockStatus.out || this == StockStatus.low;
}

/// The statuses of the "Needs attention" view.
const Set<StockStatus> kAttention = {StockStatus.negative, StockStatus.out, StockStatus.low};

/// Part numbers the Sheet uses as placeholders (F5): "N/A", "na1"…"na11", "TBD", "-", "Discontinued".
final RegExp _placeholderPart = RegExp(r'^(n/?a\d*|tbd|none|-+|discontinued)$', caseSensitive: false);

class StockItem {
  final String name;
  final String category;

  /// What the page shows ('' for none or a placeholder such as "na3").
  final String partNumber;

  /// What the Sheet holds, sent back with an office correction so the right row is found.
  final String sheetPartNumber;
  final String location; // '' when the sheet has none
  final int qty;

  /// 0 = no reorder point set. Null = the server is older than the field (no reorder points to go by).
  final int? reorderPoint;

  /// Unit cost, only for people who may see costs (null otherwise, or blank on the Sheet).
  final double? cost;

  /// The Sheet marks it "Discontinued" in the part number column.
  final bool discontinued;

  const StockItem({
    required this.name,
    required this.category,
    this.partNumber = '',
    String? sheetPartNumber,
    this.location = '',
    required this.qty,
    this.reorderPoint = 0,
    this.cost,
    this.discontinued = false,
  }) : sheetPartNumber = sheetPartNumber ?? partNumber;

  static int? _int(Object? v) {
    if (v is num) return v.toInt();
    final s = '${v ?? ''}'.replaceAll(RegExp(r'[,\s]'), '');
    if (s.isEmpty) return null;
    return int.tryParse(s) ?? double.tryParse(s)?.toInt();
  }

  static double? _money(Object? v) {
    if (v is num) return v.toDouble();
    final s = '${v ?? ''}'.replaceAll(RegExp(r'[$,\s]'), '');
    return s.isEmpty ? null : double.tryParse(s);
  }

  factory StockItem.fromJson(Map<String, dynamic> j) {
    final raw = '${j['partNumber'] ?? ''}'.trim();
    final cat = '${j['category'] ?? ''}'.trim();
    final placeholder = _placeholderPart.hasMatch(raw);
    return StockItem(
      name: '${j['name'] ?? ''}'.trim(),
      category: cat.isEmpty ? 'Uncategorized' : cat,
      partNumber: placeholder ? '' : raw,
      sheetPartNumber: raw.toUpperCase() == 'N/A' ? '' : raw,
      location: '${j['location'] ?? ''}'.trim(),
      qty: _int(j['qty']) ?? 0,
      reorderPoint: j.containsKey('reorderPoint') ? math.max(0, _int(j['reorderPoint']) ?? 0) : null,
      cost: _money(j['cost']),
      discontinued: raw.toLowerCase() == 'discontinued',
    );
  }

  StockStatus get status {
    if (qty < 0) return StockStatus.negative;
    final rp = reorderPoint ?? 0;
    if (rp > 0) {
      if (qty == 0) return StockStatus.out;
      if (qty <= rp) return StockStatus.low;
      return StockStatus.ok;
    }
    return qty > 0 ? StockStatus.ok : StockStatus.none;
  }

  /// How many to order (G3): back up to the reorder point, at least 1 while it needs attention; 0 otherwise.
  int get toOrder {
    if (!status.needsAttention) return 0;
    final rp = reorderPoint ?? 0;
    return math.max(1, rp - qty);
  }

  /// On-hand value at unit cost, or null without a cost.
  double? get value => cost == null ? null : math.max(0, qty) * cost!;

  /// Everything the search box looks in (F9): name, part number, shelf, category, status and "discontinued".
  String get searchText => '$name $partNumber $location $category ${status.label}${discontinued ? ' discontinued' : ''}'.toLowerCase();
}

/// One load of the list: the parts and when the server read the Sheet (null from an older server).
class StockLoad {
  final List<StockItem> items;
  final DateTime? sheetReadAt;
  const StockLoad(this.items, {this.sheetReadAt});
}

// ---------------------------------------------------------------------------------------------------------------------
// Requests
// ---------------------------------------------------------------------------------------------------------------------

/// A request that failed, with a sentence fit to show (never repeating the page's own title, U11).
class StockApiError implements Exception {
  final String message;
  final int? status;

  /// The quantity the Sheet holds now, when a correction was refused because it changed meanwhile.
  final int? current;
  const StockApiError(this.message, {this.status, this.current});
  @override
  String toString() => message;
}

String? _serverSaid(http.Response res) {
  try {
    final d = jsonDecode(utf8.decode(res.bodyBytes));
    if (d is Map && d['error'] is String && (d['error'] as String).trim().isNotEmpty) return (d['error'] as String).trim();
  } catch (_) {}
  return null;
}

Future<http.Response> _send(Future<http.Response> Function() call) async {
  final http.Response res;
  try {
    res = await call().timeout(const Duration(seconds: 25));
  } on TimeoutException {
    throw const StockApiError('The server took too long to answer. Try again.');
  } catch (_) {
    throw const StockApiError('Could not reach the server. Check your connection and try again.');
  }
  if (res.statusCode == 401) {
    AuthSession.instance.logout(); // sends the app back to the sign-in screen
    throw const StockApiError('Your session expired. Please sign in again.', status: 401);
  }
  if (res.statusCode == 403) throw StockApiError(_serverSaid(res) ?? 'You do not have access to this.', status: 403);
  return res;
}

/// GET /get_full_inventory. Throws a [StockApiError].
Future<StockLoad> fetchStockLoad() async {
  final res = await _send(() => http.get(Uri.parse('$kApiBaseUrl/get_full_inventory'), headers: AuthSession.instance.headers()));
  if (res.statusCode != 200) {
    throw StockApiError(_serverSaid(res) ?? 'The server had a problem reading the inventory sheet. Try again in a minute.', status: res.statusCode);
  }
  final Object? data;
  try {
    data = jsonDecode(utf8.decode(res.bodyBytes));
  } catch (_) {
    throw const StockApiError('The server sent a list the app could not read. Try again in a minute.');
  }
  if (data is! List) throw const StockApiError('The server sent a list the app could not read. Try again in a minute.');
  final items = [
    for (final e in data)
      if (e is Map) StockItem.fromJson(Map<String, dynamic>.from(e)),
  ].where((i) => i.name.isNotEmpty && i.name.toLowerCase() != 'part name').toList();
  return StockLoad(items, sheetReadAt: DateTime.tryParse(res.headers['x-stock-read-at'] ?? '')?.toLocal());
}

/// The older entry point (tests and callers that only want the parts).
Future<List<StockItem>> fetchStockLevels() async => (await fetchStockLoad()).items;

/// One movement of a part (PickedItems).
class StockMovement {
  final String date;
  final String kind; // checkout, scan_add, scan_out, count, office_receive, office_remove, office_count
  final String label;
  final String job;
  final num? qty;
  final num? change;
  final String person;
  final String note;
  const StockMovement({required this.date, required this.kind, required this.label, this.job = '', this.qty, this.change, this.person = '', this.note = ''});

  factory StockMovement.fromJson(Map<String, dynamic> j) => StockMovement(
    date: '${j['date'] ?? ''}',
    kind: '${j['kind'] ?? ''}',
    label: '${j['label'] ?? ''}',
    job: '${j['job'] ?? ''}',
    qty: j['qty'] is num ? j['qty'] as num : null,
    change: j['change'] is num ? j['change'] as num : null,
    person: '${j['person'] ?? ''}',
    note: '${j['note'] ?? ''}',
  );
}

class StockHistory {
  final List<StockMovement> movements;
  final ({int counted, int expected, String by, DateTime? at})? lastCount;
  final int? catalogProductId;
  const StockHistory({this.movements = const [], this.lastCount, this.catalogProductId});
}

/// GET /stock_part_history?name=… (G1).
Future<StockHistory> fetchStockHistory(String name) async {
  final uri = Uri.parse('$kApiBaseUrl/stock_part_history').replace(queryParameters: {'name': name});
  final res = await _send(() => http.get(uri, headers: AuthSession.instance.headers()));
  if (res.statusCode == 404) throw const StockApiError('The server is older than this page: part history is not available yet.', status: 404);
  if (res.statusCode != 200) throw StockApiError(_serverSaid(res) ?? 'Could not load this part\'s history. Try again.', status: res.statusCode);
  final d = jsonDecode(utf8.decode(res.bodyBytes));
  if (d is! Map) throw const StockApiError('The server sent a history the app could not read.');
  final lc = d['lastCount'];
  return StockHistory(
    movements: [
      for (final m in (d['movements'] as List? ?? const []))
        if (m is Map) StockMovement.fromJson(Map<String, dynamic>.from(m)),
    ],
    lastCount: lc is Map
        ? (
            counted: (lc['counted'] as num?)?.toInt() ?? 0,
            expected: (lc['expected'] as num?)?.toInt() ?? 0,
            by: '${lc['by'] ?? ''}',
            at: DateTime.tryParse('${lc['at'] ?? ''}')?.toLocal(),
          )
        : null,
    catalogProductId: (d['catalogProductId'] as num?)?.toInt(),
  );
}

/// A checkout name that took nothing off stock but probably means a shelf part (G6).
class UnmatchedCheckout {
  final String name;
  final int lines;
  final num units;
  final String lastDate;
  final List<String> jobs;
  final String? probablePart;
  final String probablePartNumber;
  final String probableShelf;
  const UnmatchedCheckout({
    required this.name,
    required this.lines,
    required this.units,
    this.lastDate = '',
    this.jobs = const [],
    this.probablePart,
    this.probablePartNumber = '',
    this.probableShelf = '',
  });
}

/// GET /stock_unmatched_checkouts (G6).
Future<List<UnmatchedCheckout>> fetchUnmatchedCheckouts() async {
  final res = await _send(() => http.get(Uri.parse('$kApiBaseUrl/stock_unmatched_checkouts'), headers: AuthSession.instance.headers()));
  if (res.statusCode == 404) throw const StockApiError('The server is older than this page: this list is not available yet.', status: 404);
  if (res.statusCode != 200) throw StockApiError(_serverSaid(res) ?? 'Could not load the checkout names. Try again.', status: res.statusCode);
  final d = jsonDecode(utf8.decode(res.bodyBytes));
  final list = d is Map ? d['names'] : null;
  if (list is! List) throw const StockApiError('The server sent a list the app could not read.');
  return [
    for (final e in list)
      if (e is Map)
        UnmatchedCheckout(
          name: '${e['name'] ?? ''}',
          lines: (e['lines'] as num?)?.toInt() ?? 0,
          units: (e['units'] as num?) ?? 0,
          lastDate: '${e['lastDate'] ?? ''}',
          jobs: [for (final j in (e['jobs'] as List? ?? const [])) '$j'],
          probablePart: e['probablePart'] is Map ? '${e['probablePart']['name'] ?? ''}' : null,
          probablePartNumber: e['probablePart'] is Map ? '${e['probablePart']['partNumber'] ?? ''}' : '',
          probableShelf: e['probablePart'] is Map ? '${e['probablePart']['location'] ?? ''}' : '',
        ),
  ];
}

enum StockAdjustAction { receive, remove, set }

/// POST /stock_adjust (G2): admins only. [expected] is the quantity the person saw; the server refuses the change when
/// the Sheet says something else. Never retried by the app. Returns the new quantity and a warning, if any.
Future<({int after, String? warning})> adjustStock({
  required StockItem item,
  required StockAdjustAction action,
  required int qty,
  required String reason,
}) async {
  final res = await _send(
    () => http.post(
      Uri.parse('$kApiBaseUrl/stock_adjust'),
      headers: {...AuthSession.instance.headers(), 'Content-Type': 'application/json'},
      body: jsonEncode({'action': action.name, 'name': item.name, 'partNumber': item.sheetPartNumber, 'qty': qty, 'reason': reason, 'expected': item.qty}),
    ),
  );
  Map? d;
  try {
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (decoded is Map) d = decoded;
  } catch (_) {}
  if (res.statusCode == 404 && d == null) throw const StockApiError('The server is older than this page: corrections are not available yet.', status: 404);
  if (res.statusCode != 200) {
    throw StockApiError(_serverSaid(res) ?? 'The change could not be saved. Refresh to see the current number before trying again.',
        status: res.statusCode, current: (d?['current'] as num?)?.toInt());
  }
  return (after: (d?['after'] as num?)?.toInt() ?? qty, warning: d?['warning'] as String?);
}

// ---------------------------------------------------------------------------------------------------------------------
// Export (G4)
// ---------------------------------------------------------------------------------------------------------------------

String _csvCell(String v) {
  // A text cell a spreadsheet would read as a formula gets a quote in front, so opening the file never runs anything.
  var t = v;
  if (t.isNotEmpty && '=+-@\t\r'.contains(t[0]) && double.tryParse(t) == null) t = "'$t";
  if (t.contains(RegExp(r'[",\r\n]'))) t = '"${t.replaceAll('"', '""')}"';
  return t;
}

/// The parts as a CSV file (UTF-8 with a byte order mark, so Excel reads symbols right).
Uint8List stockCsvBytes(List<StockItem> items, {required bool withCost}) {
  final b = StringBuffer();
  void line(List<String> cells) => b.write('${cells.map(_csvCell).join(',')}\r\n');
  line(['Part', 'Part #', 'Shelf', 'Category', 'On hand', 'Reorder point', 'To order', 'Status', if (withCost) ...['Unit cost', 'Value']]);
  for (final i in items) {
    line([
      i.name,
      i.discontinued ? 'Discontinued' : i.partNumber,
      i.location,
      i.category,
      '${i.qty}',
      (i.reorderPoint ?? 0) > 0 ? '${i.reorderPoint}' : '',
      i.toOrder > 0 ? '${i.toOrder}' : '',
      i.status.label,
      if (withCost) ...[i.cost == null ? '' : i.cost!.toStringAsFixed(2), i.value == null ? '' : i.value!.toStringAsFixed(2)],
    ]);
  }
  return Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(b.toString())]);
}

const Map<int, String> _plain = {
  0x2018: "'", 0x2019: "'", 0x201C: '"', 0x201D: '"', 0x2032: "'", 0x2033: '"', //
  0x2013: '-', 0x2014: '-', 0x2212: '-', 0x2026: '...', 0x2022: '-', 0x00D7: 'x', 0x00A0: ' ',
};

/// Text the PDF's built-in font can draw.
String _pdfSafe(String v) {
  final out = StringBuffer();
  for (final c in v.runes) {
    final p = _plain[c];
    if (p != null) {
      out.write(p);
    } else {
      out.writeCharCode(c < 256 ? c : 0x3F);
    }
  }
  return out.toString();
}

/// A printable list of [items] (the warehouse's reorder or walk list), sorted as given. [title] heads the page.
Future<Uint8List> buildStockListPdf(List<StockItem> items, {required String title, String? note, DateTime? printed, bool compress = true}) async {
  final doc = pw.Document(compress: compress, title: title, author: kCompanyName, creator: '$kAppName $kAppVersion');
  final when = DateFormat('MMMM d, y h:mm a').format(printed ?? DateTime.now());
  final ink = PdfColor.fromInt(0xFF111111);
  final slate = PdfColor.fromInt(0xFF505050);
  final faint = PdfColor.fromInt(0xFFF2F2F2);
  final count = NumberFormat.decimalPattern();
  pw.Widget t(String s, {bool bold = false, double size = 9, PdfColor? color, pw.TextAlign align = pw.TextAlign.left}) => pw.Text(
    _pdfSafe(s),
    textAlign: align,
    style: pw.TextStyle(fontSize: size, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal, color: color ?? ink),
  );
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.letter.landscape,
      margin: const pw.EdgeInsets.all(28),
      header: (ctx) => pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 10),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            pw.Expanded(child: t(title, bold: true, size: 15)),
            t('$kCompanyName  ·  $when  ·  page ${ctx.pageNumber} of ${ctx.pagesCount}'.replaceAll('·', '-'), size: 8.5, color: slate),
          ],
        ),
      ),
      build: (ctx) => [
        if (note != null) pw.Padding(padding: const pw.EdgeInsets.only(bottom: 8), child: t(note, size: 9, color: slate)),
        pw.TableHelper.fromTextArray(
          headers: ['Part', 'Part #', 'Shelf', 'On hand', 'Reorder point', 'To order', 'Status', 'Picked'],
          data: [
            for (final i in items)
              [
                _pdfSafe(i.name),
                i.discontinued ? 'Discontinued' : i.partNumber,
                i.location,
                count.format(i.qty),
                (i.reorderPoint ?? 0) > 0 ? count.format(i.reorderPoint) : '',
                i.toOrder > 0 ? count.format(i.toOrder) : '',
                i.status.label,
                '',
              ],
          ],
          headerStyle: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold, color: slate),
          cellStyle: pw.TextStyle(fontSize: 9, color: ink),
          headerDecoration: pw.BoxDecoration(color: faint),
          cellAlignments: {3: pw.Alignment.centerRight, 4: pw.Alignment.centerRight, 5: pw.Alignment.centerRight},
          columnWidths: {
            0: const pw.FlexColumnWidth(5),
            1: const pw.FlexColumnWidth(1.4),
            2: const pw.FlexColumnWidth(0.9),
            3: const pw.FlexColumnWidth(0.9),
            4: const pw.FlexColumnWidth(1.1),
            5: const pw.FlexColumnWidth(0.9),
            6: const pw.FlexColumnWidth(1.4),
            7: const pw.FlexColumnWidth(0.8),
          },
          cellPadding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
          oddRowDecoration: pw.BoxDecoration(color: PdfColor.fromInt(0xFFFAFAFA)),
        ),
      ],
    ),
  );
  return doc.save();
}
