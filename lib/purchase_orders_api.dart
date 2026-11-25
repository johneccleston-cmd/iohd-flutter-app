import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import 'config/api_config.dart';
import 'config/auth_session.dart';
import 'widgets/dashboard_kit.dart';

// Purchase orders: the model, the calls to the backend (integrity-backend/src/purchase_orders.js) and the words and
// colours a PO's state is shown in. The list (purchase_orders_screen.dart), the PO page
// (purchase_order_detail_screen.dart) and the printed PO (purchase_order_pdf.dart) all read them from here.
//
// Money is worked out in whole cents, one line at a time (quantity x unit cost, rounded once), exactly as the server
// does, so the total on screen is the total saved.

/// One part on a PO: what it is, how many were ordered at what unit cost, and how many have arrived.
@immutable
class PoLine {
  final String name;
  final String sku;

  /// The catalog product it came from (its page is `/inventory/catalog/<id>`). Null for a line typed in by hand.
  final int? productId;
  final double qty;
  final double unitCost;
  final double received;

  const PoLine({required this.name, this.sku = '', this.productId, required this.qty, required this.unitCost, this.received = 0});

  factory PoLine.fromJson(Map<String, dynamic> j) => PoLine(
    name: '${j['name'] ?? ''}',
    sku: '${j['sku'] ?? ''}',
    productId: (j['productId'] as num?)?.toInt(),
    qty: (j['qty'] as num?)?.toDouble() ?? 0,
    unitCost: (j['unitCost'] as num?)?.toDouble() ?? 0,
    received: (j['received'] as num?)?.toDouble() ?? 0,
  );

  Map<String, dynamic> toJson() => {'name': name, 'sku': sku, 'productId': productId, 'qty': qty, 'unitCost': unitCost, 'received': received};

  PoLine copyWith({double? received}) =>
      PoLine(name: name, sku: sku, productId: productId, qty: qty, unitCost: unitCost, received: received ?? this.received);

  /// The line's amount in whole cents, as the server works it out.
  int get amountCents => (qty * unitCost * 100).round();

  /// Still to arrive, never below none.
  double get remaining => math.max(0, qty - received);
  bool get complete => received >= qty - 1e-9;
}

/// Where a PO stands, worked out from its status, its lines and today's date. [late] and [partial] are both still
/// Open on the server (on order), so they count in the warehouse page's Open POs.
enum PoStage { draft, open, partial, late, received, canceled }

extension PoStageText on PoStage {
  String get label => switch (this) {
    PoStage.draft => 'Draft',
    PoStage.open => 'Open',
    PoStage.partial => 'Partly received',
    PoStage.late => 'Past due',
    PoStage.received => 'Received',
    PoStage.canceled => 'Canceled',
  };

  /// A colour that is safe for small text on white (the status column, tags).
  Color get tone => switch (this) {
    PoStage.draft => DashUi.slate,
    PoStage.open => DashUi.blue,
    PoStage.partial => DashUi.amberText,
    PoStage.late => DashUi.redText,
    PoStage.received => DashUi.emeraldText,
    PoStage.canceled => DashUi.subtle,
  };

  IconData get icon => switch (this) {
    PoStage.draft => Icons.edit_note_rounded,
    PoStage.open => Icons.local_shipping_outlined,
    PoStage.partial => Icons.inventory_2_outlined,
    PoStage.late => Icons.schedule_rounded,
    PoStage.received => Icons.task_alt_rounded,
    PoStage.canceled => Icons.block_rounded,
  };
}

/// The PO statuses the server stores. Draft: being put together, not sent. Open: ordered, not all in yet.
const kPoStatuses = ['Draft', 'Open', 'Received', 'Canceled'];

@immutable
class PurchaseOrder {
  final int id;
  final String poNumber;
  final String vendor;
  final String status;
  final String notes;
  final String vendorRef;
  final String jobNumber;
  final DateTime? orderDate;
  final DateTime? expectedDate;
  final DateTime? receivedDate;
  final double total;
  final double shipping;
  final List<PoLine> lines;
  final String createdBy;
  final String updatedBy;
  final DateTime? createdAt;

  /// The server's own text for when it last changed, sent back with an edit so a stale copy is refused (409).
  final String? updatedAt;

  const PurchaseOrder({
    required this.id,
    required this.poNumber,
    required this.vendor,
    required this.status,
    this.notes = '',
    this.vendorRef = '',
    this.jobNumber = '',
    this.orderDate,
    this.expectedDate,
    this.receivedDate,
    this.total = 0,
    this.shipping = 0,
    this.lines = const [],
    this.createdBy = '',
    this.updatedBy = '',
    this.createdAt,
    this.updatedAt,
  });

  factory PurchaseOrder.fromJson(Map<String, dynamic> j) => PurchaseOrder(
    id: (j['id'] as num).toInt(),
    poNumber: '${j['poNumber'] ?? ''}',
    vendor: '${j['vendor'] ?? ''}',
    status: '${j['status'] ?? ''}',
    notes: '${j['notes'] ?? ''}',
    vendorRef: '${j['vendorRef'] ?? ''}',
    jobNumber: '${j['jobNumber'] ?? ''}',
    orderDate: poDay(j['orderDate']),
    expectedDate: poDay(j['expectedDate']),
    receivedDate: poDay(j['receivedDate']),
    total: (j['total'] as num?)?.toDouble() ?? 0,
    shipping: (j['shipping'] as num?)?.toDouble() ?? 0,
    lines: [for (final l in (j['lines'] as List? ?? const []).whereType<Map>()) PoLine.fromJson(Map<String, dynamic>.from(l))],
    createdBy: '${j['createdBy'] ?? ''}',
    updatedBy: '${j['updatedBy'] ?? ''}',
    createdAt: DateTime.tryParse('${j['createdAt'] ?? ''}')?.toLocal(),
    updatedAt: j['updatedAt']?.toString(),
  );

  bool get isDraft => status == 'Draft';
  bool get isOpen => status == 'Open';
  bool get isReceived => status == 'Received';
  bool get isCanceled => status == 'Canceled';

  /// Ordered and not everything is in: what the warehouse is waiting for.
  bool get onOrder => isOpen;

  double get unitsOrdered => lines.fold(0, (s, l) => s + l.qty);
  double get unitsReceived => lines.fold(0, (s, l) => s + math.min(l.received, l.qty));
  bool get anyReceived => lines.any((l) => l.received > 0);
  bool get allReceived => lines.isNotEmpty && lines.every((l) => l.complete);

  /// Days past the expected date (positive), or until it (negative). Null without one.
  int? daysLate(DateTime today) {
    final e = expectedDate;
    return e == null ? null : poDaysBetween(e, today);
  }

  PoStage stage(DateTime today) {
    if (isDraft) return PoStage.draft;
    if (isReceived) return PoStage.received;
    if (isCanceled) return PoStage.canceled;
    if ((daysLate(today) ?? 0) > 0) return PoStage.late;
    if (anyReceived) return PoStage.partial;
    return PoStage.open;
  }

  /// Everything a search box looks through: the numbers, the vendor, the job and every line's name and part number.
  String get searchText => [poNumber, vendor, vendorRef, jobNumber, for (final l in lines) ...[l.name, l.sku]].join(' ').toLowerCase();

  /// The body a save sends, with [status], [lines] and the dates as given (an action such as Receive changes only those).
  Map<String, dynamic> toBody({
    String? status,
    List<PoLine>? lines,
    DateTime? orderDate,
    DateTime? receivedDate,
    bool clearReceived = false,
  }) {
    final s = status ?? this.status;
    final rd = clearReceived ? null : (receivedDate ?? this.receivedDate);
    return {
      'poNumber': poNumber,
      'vendor': vendor,
      'status': s,
      'orderDate': poIso(orderDate ?? this.orderDate ?? DateTime.now()),
      'expectedDate': expectedDate == null ? '' : poIso(expectedDate!),
      'receivedDate': s == 'Received' ? poIso(rd ?? DateTime.now()) : '',
      'notes': notes,
      'vendorRef': vendorRef,
      'jobNumber': jobNumber,
      'shipping': shipping,
      'total': total,
      'lines': [for (final l in lines ?? this.lines) l.toJson()],
      'updatedAt': ?updatedAt,
    };
  }
}

/// A YYYY-MM-DD from the server as that calendar day (no time zone shift).
DateTime? poDay(Object? v) {
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch('${v ?? ''}');
  return m == null ? null : DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
}

String poIso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime poToday([DateTime? now]) {
  final n = now ?? DateTime.now();
  return DateTime(n.year, n.month, n.day);
}

/// Whole calendar days from [a] to [b] (DST-safe: counted in UTC dates).
int poDaysBetween(DateTime a, DateTime b) =>
    DateTime.utc(b.year, b.month, b.day).difference(DateTime.utc(a.year, a.month, a.day)).inDays;

final DateFormat poDate = DateFormat('MMM d, y');
final DateFormat poShortDate = DateFormat('MMM d');

/// "3 days", "1 day", "2 weeks", "3 months": how a span reads in a sentence.
String poSpan(int days) {
  final d = days.abs();
  if (d < 14) return d == 1 ? '1 day' : '$d days';
  if (d < 60) return '${(d / 7).round()} weeks';
  final m = (d / 30.4).round();
  return m == 1 ? '1 month' : '$m months';
}

/// "In 3 days", "Tomorrow", "Today", "5 days late": the expected date against today, for an order still on its way.
String poDueText(int daysLate) {
  if (daysLate == 0) return 'Due today';
  if (daysLate == -1) return 'Due tomorrow';
  if (daysLate < 0) return 'In ${poSpan(daysLate)}';
  return '${poSpan(daysLate)} late';
}

/// A count shown as it is everywhere ("1", "2.5"): no trailing zeros for whole units.
String poQty(double q) {
  final r = (q * 1000).round() / 1000;
  if (r == r.roundToDouble()) return NumberFormat.decimalPattern().format(r.round());
  return NumberFormat('#,##0.###').format(r);
}

/// A failed call, with a message fit to show.
class PoApiError implements Exception {
  final String message;
  final int? status;
  final bool conflict;
  const PoApiError(this.message, {this.status, this.conflict = false});
  bool get forbidden => status == 403;
  bool get notFound => status == 404;
  @override
  String toString() => message;
}

/// What the list endpoint answered: the POs, and whether this server keeps line items (one from before 2026-11-25
/// does not, and would drop them).
typedef PoListResult = ({List<PurchaseOrder> orders, bool linesSupported});

class PoApi {
  PoApi._();

  /// Goes up after every save or delete, so a list left open under the PO page reloads itself.
  static final changes = ValueNotifier<int>(0);

  static Future<Map<String, dynamic>> _send(String method, String path, {Map<String, dynamic>? body, Duration? timeout}) async {
    final uri = Uri.parse('$kApiBaseUrl/api$path');
    final headers = AuthSession.instance.headers();
    final encoded = body == null ? null : json.encode(body);
    http.Response res;
    try {
      res = await switch (method) {
        'GET' => http.get(uri, headers: headers),
        'POST' => http.post(uri, headers: headers, body: encoded),
        'PUT' => http.put(uri, headers: headers, body: encoded),
        _ => http.delete(uri, headers: headers),
      }.timeout(timeout ?? const Duration(seconds: 40));
    } on TimeoutException {
      throw const PoApiError('The server is taking too long to respond. It may be waking up. Try again in a moment.');
    } on http.ClientException {
      throw const PoApiError("Couldn't reach the server. Check your connection and try again.");
    }
    if (res.statusCode == 401) {
      AuthSession.instance.logout(); // back to the sign-in screen
      throw const PoApiError('Your sign-in has ended. Sign in again.', status: 401);
    }
    Map<String, dynamic> data = const {};
    try {
      final decoded = json.decode(utf8.decode(res.bodyBytes));
      if (decoded is Map<String, dynamic>) data = decoded;
    } catch (_) {}
    if (res.statusCode == 403) throw const PoApiError("Your account doesn't have access to purchase orders.", status: 403);
    if (res.statusCode >= 400) {
      final said = data['error'];
      throw PoApiError(
        said is String && said.trim().isNotEmpty ? said : 'Something went wrong on the server (error ${res.statusCode}). Try again.',
        status: res.statusCode,
        conflict: data['conflict'] == true,
      );
    }
    return data;
  }

  static Future<PoListResult> list() async {
    final d = await _send('GET', '/purchase-orders');
    final raw = d['purchaseOrders'];
    if (raw is! List) throw const PoApiError('The server sent purchase orders the app could not read. Try again.');
    return (
      orders: [for (final j in raw.whereType<Map>()) PurchaseOrder.fromJson(Map<String, dynamic>.from(j))],
      linesSupported: (d['features'] as List?)?.contains('lines') ?? false,
    );
  }

  /// One PO. A server from before 2026-11-25 has no such route (a bare 404, or no PO in the answer), so the list is
  /// read instead and the PO found in it.
  static Future<({PurchaseOrder order, bool linesSupported})> get(int id) async {
    Map<String, dynamic>? d;
    try {
      d = await _send('GET', '/purchase-orders/$id');
    } on PoApiError catch (e) {
      if (!e.notFound || e.message.contains('not on file')) rethrow;
    }
    final one = d?['purchaseOrder'];
    if (one is Map) {
      return (order: PurchaseOrder.fromJson(Map<String, dynamic>.from(one)), linesSupported: (d!['features'] as List?)?.contains('lines') ?? false);
    }
    final all = await list();
    final hit = all.orders.where((o) => o.id == id);
    if (hit.isEmpty) throw const PoApiError('That PO is not on file. It may have been deleted.', status: 404);
    return (order: hit.first, linesSupported: all.linesSupported);
  }

  static Future<PurchaseOrder> create(Map<String, dynamic> body) async {
    final d = await _send('POST', '/purchase-orders', body: body);
    changes.value++;
    return PurchaseOrder.fromJson(Map<String, dynamic>.from(d['purchaseOrder'] as Map));
  }

  static Future<PurchaseOrder> update(int id, Map<String, dynamic> body) async {
    final d = await _send('PUT', '/purchase-orders/$id', body: body);
    changes.value++;
    return PurchaseOrder.fromJson(Map<String, dynamic>.from(d['purchaseOrder'] as Map));
  }

  static Future<void> delete(int id) async {
    await _send('DELETE', '/purchase-orders/$id');
    changes.value++;
  }
}
