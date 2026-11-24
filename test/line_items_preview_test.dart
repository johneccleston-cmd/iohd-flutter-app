// The Line Items block on the job and estimate pages, and the ribbon's Edit Job / Edit Estimate preview: the lines can be
// changed on screen and the totals follow, but nothing is ever sent to the server, and Cancel puts the original back.
// Run:  flutter test test/line_items_preview_test.dart   (review pictures go to build/line_items_shots/)

import 'dart:convert';
import 'dart:io';
import 'dart:ui' show ImageByteFormat;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/job_detail_screen.dart';
import 'package:iohd_desktop/widgets/line_items_editor.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    if (File(p).existsSync()) loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
  }
  await loader.load();
}

const _id = '1096183137';

// Service Fusion's descriptions are one fact to a line.
const _longText = 'SIZE : 10\' 0" X 10\' 0"\r\nMODEL : 3150 | R-Value 6.5 | 27 Ga Steel\r\n\r\nASSEMBLY TYPE : COMPLETE DOOR\r\nPANEL INSULATION : POLYSTYRENE (EPS)\r\n';

Map<String, dynamic> _item(int i, String name, {double qty = 1, double? rate, double? cost, String description = '', bool tax = true, bool show = true}) => {
      'is_show_rate_items': show,
      'name': name,
      'description': description,
      'multiplier': qty,
      'rate': ?rate,
      'cost': ?cost,
      'total': rate == null ? 0 : (qty * rate * 100).round() / 100,
      'tax': tax ? _rogers : null,
      'item_index': i,
    };

/// Three lines, $1,450.00 of items ($1,150.00 taxable), 10% sales tax = $115.00, total $1,565.00.
List<Map<String, dynamic>> _threeItems() => [
      _item(1, 'SMH | Gallery Steel | GD5S | Complete Door | White', rate: 900, cost: 610, description: _longText),
      // (the weather seal below is hidden from the customer, like Service Fusion's crossed-out eye)
      _item(2, 'Weather Seal | Stop Mold | 7\' White', qty: 2, rate: 125, show: false, cost: 80), // Service Fusion's cost is for the whole line
      _item(3, 'SMH Installation | Gallery Steel | 16x7 | White', rate: 300, cost: 0, tax: false),
    ];

Map<String, dynamic> _record({required List<Map<String, dynamic>> items, bool estimate = false, String? total, List<Map<String, dynamic>>? charges}) => {
      'job': {
        'job_id': _id,
        'customer_name': 'Schuber Mitchell Homes',
        'status': estimate ? 'Estimate Provided' : 'Scheduled',
        'is_estimate': estimate,
        'location': '1204 W Poplar St, Rogers, AR 72756',
        'description': 'Replace the garage door.',
        'start_date': '2026-10-06',
        'total_revenue': ?total,
        'raw_items': items,
        'other_charges': charges ?? const [],
      },
      'visits': [],
      'payments': [],
      'history': [],
    };

const _rogers = 'Sales Tax (State, County, & Local Use Tax, Rogers)';

const _tax = [
  {'name': _rogers, 'total': 115.0, 'is_discount': false, 'is_percentage': true, 'rate': 10},
];

Map<String, dynamic> _options({bool canEdit = true, bool canSeeCost = false, List<Map<String, dynamic>> options = const []}) =>
    {'recordKind': 'job', 'canSeeCost': canSeeCost, 'canEdit': canEdit, 'options': options, 'history': []};

Map<String, dynamic> _option(String id, String name, List<Map<String, dynamic>> items, {bool recommended = false}) => {
      'id': id,
      'kind': 'estimate',
      'name': name,
      'position': 0,
      'isRecommended': recommended,
      'taxRate': 10,
      'notes': '',
      'version': 3,
      'source': 'service_fusion',
      'items': items,
    };

Map<String, dynamic> _line(String id, String name, {double qty = 1, double? rate, double? cost, bool taxable = true, String description = ''}) =>
    {'id': id, 'kind': 'item', 'name': name, 'description': description, 'quantity': qty, 'rate': rate, 'cost': cost, 'taxable': taxable, 'source': 'service_fusion'};

/// Every request the page makes, as "METHOD path".
final List<String> _requests = [];

http.Client _server(Map<String, dynamic> record, Map<String, dynamic> options) => MockClient((req) async {
      final path = req.url.path;
      _requests.add('${req.method} $path');
      if (req.method != 'GET') return http.Response(jsonEncode({'error': 'The test server takes no writes.'}), 500);
      if (path.endsWith('/options')) return http.Response(jsonEncode(options), 200);
      if (path.endsWith('/notes-tasks')) return http.Response(jsonEncode({'notes': [], 'tasks': []}), 200);
      if (path.endsWith('/files')) return http.Response(jsonEncode({'enabled': true, 'files': []}), 200);
      if (path == '/api/catalog/search') return http.Response(jsonEncode({'results': []}), 200);
      if (path == '/api/jobs/$_id') return http.Response(jsonEncode(record), 200);
      return http.Response('{}', 404);
    });

Future<void> _open(WidgetTester t, http.Client client, {Size size = const Size(1500, 1500)}) async {
  _requests.clear();
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await http.runWithClient(() async {
    await t.pumpWidget(RepaintBoundary(
      key: const ValueKey('shot'),
      child: MaterialApp(
        theme: ThemeData(useMaterial3: true, fontFamily: 'Segoe UI'),
        home: const JobDetailScreen(jobId: _id),
      ),
    ));
    await t.pumpAndSettle();
  }, () => client);
  expect(t.takeException(), isNull);
}

/// Saves the screen to build/line_items_shots/[name].png for review. (These were goldens; the block was redesigned on
/// 2026-11-12 and goldens are only regenerated with the user's OK, so they are review pictures, not pixel checks.)
Future<void> _shot(WidgetTester t, String name) async {
  await t.pumpAndSettle();
  expect(t.takeException(), isNull);
  final boundary = t.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('shot')));
  await t.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ImageByteFormat.png);
    final dir = Directory('build/line_items_shots')..createSync(recursive: true);
    File('${dir.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

/// Opens line [index]'s fields by clicking its name, then types into one of them.
Future<void> _type(WidgetTester t, int index, String name, String field, String value) async {
  await t.ensureVisible(find.text(name));
  await t.tap(find.text(name));
  await t.pumpAndSettle();
  if (field == 'description') {
    // The description field is behind the line's toggle here too.
    expect(find.byKey(ValueKey('line-$index-description')), findsNothing);
    await t.tap(_more(index));
    await t.pumpAndSettle();
  }
  await t.enterText(find.byKey(ValueKey('line-$index-$field')), value);
  await t.pumpAndSettle();
}

/// [text] inside the line items (the page has a "Description" of its own, in Details).
Finder _inTable(String text) => find.descendant(of: find.byType(LineItemsEditor), matching: find.text(text));

/// Line [index]'s description toggle ("Description"; while editing on every line, inside the name box).
Finder _more(int index) => find.byKey(ValueKey('line-$index-more'));

/// Ctrl+S, as the office presses it from habit.
Future<void> _ctrlS(WidgetTester t) async {
  await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await t.sendKeyEvent(LogicalKeyboardKey.keyS);
  await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await t.pumpAndSettle();
}

Iterable<String> get _writes => _requests.where((r) => !r.startsWith('GET '));

/// A server whose record can change between loads (as Service Fusion's copy does between two Refreshes), serving a
/// second record at [otherId] for moving between a job and its estimate.
const _otherId = '1093839956';

http.Client _liveServer(Map<String, dynamic> Function() record, Map<String, dynamic> options, {Map<String, dynamic>? other}) => MockClient((req) async {
      final path = req.url.path;
      _requests.add('${req.method} $path');
      if (req.method != 'GET') return http.Response(jsonEncode({'error': 'The test server takes no writes.'}), 500);
      if (path.endsWith('/options')) return http.Response(jsonEncode(options), 200);
      if (path.endsWith('/notes-tasks')) return http.Response(jsonEncode({'notes': [], 'tasks': []}), 200);
      if (path.endsWith('/files')) return http.Response(jsonEncode({'enabled': true, 'files': []}), 200);
      if (path == '/api/jobs/$_id') return http.Response(jsonEncode(record()), 200);
      if (path == '/api/jobs/$_otherId' && other != null) return http.Response(jsonEncode(other), 200);
      return http.Response('{}', 404);
    });

/// The page for [id], under a host that can switch it to another record the way the router does.
class _Switcher extends StatefulWidget {
  const _Switcher();

  @override
  State<_Switcher> createState() => _SwitcherState();
}

class _SwitcherState extends State<_Switcher> {
  String id = _id;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          TextButton(onPressed: () => setState(() => id = _otherId), child: const Text('Go to the estimate')),
          Expanded(child: JobDetailScreen(jobId: id)),
        ],
      );
}

/// The quantity in line [index]'s box (closed) or field (open).
String _qtyShown(WidgetTester t, int index) {
  final field = find.byKey(ValueKey('line-$index-qty'));
  if (field.evaluate().isNotEmpty) return t.widget<TextField>(field).controller!.text;
  throw StateError('line $index is not open');
}

void main() {
  setUpAll(() async {
    await _loadFont('Segoe UI', ['C:/Windows/Fonts/segoeui.ttf', 'C:/Windows/Fonts/segoeuib.ttf']);
    final flutter = File(Platform.resolvedExecutable).parent.path; // .../bin/cache/artifacts/engine/<platform>
    await _loadFont('MaterialIcons', ['$flutter/../../material_fonts/MaterialIcons-Regular.otf']);
  });

  // Quantities always show two decimals, read-only and while editing, and the preview never leaves a trace: what shows
  // after Exit preview, after a Refresh, or on another record is what was loaded (user 2026-11-13).
  group('quantities and the way in and out of the preview', () {
    List<Map<String, dynamic>> fractional() => [
          _item(1, 'Stop Mold | Install New Standard Color', qty: 68.57, rate: 0.61, cost: 20),
          _item(2, 'Tek Screws | Retail Accessories', qty: 2400, rate: 0.21, cost: 100),
          _item(3, 'Spring Replacement | Labor', qty: 1.5, rate: 150, tax: false),
        ];

    testWidgets('job: two decimals in both views; a change, Exit preview, and Edit Job again shows the loaded values', (t) async {
      // 41.83 + 504.00 + 225.00 = 770.83 items; 545.83 taxable at 10% = 54.58; total 825.41.
      final client = _server(_record(items: fractional(), total: '825.41', charges: const [
        {'name': _rogers, 'total': 54.58, 'is_discount': false, 'is_percentage': true, 'rate': 10},
      ]), _options());
      await _open(t, client);
      for (final q in ['68.57', '2,400.00', '1.50']) {
        expect(_inTable(q), findsOneWidget, reason: 'read-only $q');
      }
      expect(_inTable(r'$41.83'), findsOneWidget, reason: '68.57 x 0.61, not rounded to a whole quantity');
      expect(_inTable(r'$825.41'), findsNWidgets(2), reason: 'the job total and the balance due (nothing paid)');
      await http.runWithClient(() async {
        await t.tap(find.text('Edit Job'));
        await t.pumpAndSettle();
        for (final q in ['68.57', '2,400.00', '1.50']) {
          expect(_inTable(q), findsOneWidget, reason: 'editing, closed box $q');
        }
        // Open the labor line at its quantity, change it, leave the field: tidied to two decimals; the totals follow.
        await t.tap(_inTable('1.50'));
        await t.pumpAndSettle();
        expect(_qtyShown(t, 2), '1.50');
        await t.enterText(find.byKey(const ValueKey('line-2-qty')), '3.5');
        await t.pumpAndSettle();
        expect(_inTable(r'$525.00'), findsOneWidget, reason: '3.5 x 150');
        await t.testTextInput.receiveAction(TextInputAction.done); // Enter keeps; Esc cancels since decision A1 (2026-11-23)
        await t.pumpAndSettle();
        expect(_inTable('3.50'), findsOneWidget);
        expect(find.text('Changed, not saved'), findsOneWidget);
        // Exit preview: the loaded values, figures and total are back.
        await t.tap(find.text('Exit preview'));
        await t.pumpAndSettle();
        expect(_inTable('1.50'), findsOneWidget);
        expect(_inTable('3.50'), findsNothing);
        expect(_inTable(r'$825.41'), findsNWidgets(2), reason: 'the job total and the balance due (nothing paid)');
        // In again: no trace of the last preview.
        await t.tap(find.text('Edit Job'));
        await t.pumpAndSettle();
        expect(_inTable('1.50'), findsOneWidget);
        expect(find.text('Changed, not saved'), findsNothing);
        await _shot(t, 'line_items_job_quantities_editing');
      }, () => client);
      expect(_writes, isEmpty, reason: 'nothing is ever sent: $_requests');
    });

    // The old 9,999.999 cap (and its 0 floor): Service Fusion's percentage lines carry the dollar base as the quantity
    // (estimate 1044450930: 35,125.3 x -$0.10) and a return is -1 (job 1083198614, with its cost extended: -$7 on -1).
    testWidgets('Service Fusion\'s quantities above 9,999.999 and below 0: shown as it has them, costed per unit, editable', (t) async {
      // Items 36,000.00 - 3,512.53 - 10.00 = 32,477.47; taxed 35,990.00 at 10% = 3,599.00; total 36,076.47.
      // Cost 21,000.00 + 0 + (-1 x 7.00) = 20,993.00.
      final client = _server(
        _record(
          items: [
            _item(1, 'Clopay Classic Steel | Complete Door', rate: 36000, cost: 21000),
            _item(2, '10% Discount (Doors & Openers)', qty: 35125.3, rate: -0.1, cost: 0, tax: false),
            _item(3, 'CALLBACK (Used one 7\' doorstop)', qty: -1, rate: 10, cost: -7),
          ],
          total: '36076.47',
          charges: const [{'name': _rogers, 'total': 3599.00, 'is_discount': false, 'is_percentage': true, 'rate': 10}],
        ),
        _options(canSeeCost: true),
      );
      await _open(t, client);
      expect(_inTable('35,125.30'), findsOneWidget, reason: 'the quantity, not cut to 9,999.999');
      expect(_inTable('-1.00'), findsOneWidget, reason: 'a return, not 0');
      expect(_inTable(r'-$3,512.53'), findsOneWidget);
      expect(_inTable(r'-$10.00'), findsOneWidget);
      expect(_inTable(r'$7.00'), findsOneWidget, reason: 'the return\'s -\$7 extended cost is \$7 a unit');
      expect(_inTable(r'-$7.00'), findsNothing, reason: 'it used to show -\$7 a unit, so +\$7 extended');
      expect(_inTable(r'$20,993.00'), findsOneWidget, reason: 'job cost: the return gives its \$7 back');
      expect(_inTable(r'$36,076.47'), findsNWidgets(2), reason: 'the job total and the balance due (nothing paid)');
      await _shot(t, 'line_items_job_big_negative_qty');
      await http.runWithClient(() async {
        await t.tap(find.text('Edit Job'));
        await t.pumpAndSettle();
        expect(_inTable('35,125.30'), findsOneWidget, reason: 'editing, closed box');
        expect(_inTable('-1.00'), findsOneWidget, reason: 'editing, closed box');
        await t.tap(_inTable('35,125.30'));
        await t.pumpAndSettle();
        expect(_qtyShown(t, 1), '35,125.30');
        await t.enterText(find.byKey(const ValueKey('line-1-qty')), '49376');
        await t.pumpAndSettle();
        expect(_inTable(r'-$4,937.60'), findsOneWidget, reason: '49,376 x -\$0.10');
        await t.testTextInput.receiveAction(TextInputAction.done); // Enter keeps; Esc cancels since decision A1 (2026-11-23)
        await t.pumpAndSettle();
        expect(_inTable('49,376.00'), findsOneWidget);
        expect(find.byIcon(Icons.error_outline_rounded), findsNothing, reason: 'a good quantity, not marked');
        await _shot(t, 'line_items_job_big_negative_qty_editing');
        await t.tap(find.text('Exit preview'));
        await t.pumpAndSettle();
        expect(_inTable('35,125.30'), findsOneWidget, reason: 'Exit preview puts Service Fusion\'s quantity back');
      }, () => client);
      expect(_writes, isEmpty, reason: 'nothing is ever sent: $_requests');
    });

    // User 2026-11-13: no lock icon by Cost or Job cost, and nothing on the block shows helper text on hover.
    testWidgets('no lock icons, and hovering anything on the block shows no helper text', (t) async {
      final client = _server(_record(items: _threeItems(), total: '1565.00', charges: _tax), _options(canSeeCost: true));
      await _open(t, client);
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      Future<void> hoverAll() async {
        expect(find.byIcon(Icons.lock_outline_rounded), findsNothing);
        // Hover each tooltip-bearing widget on the block: its message must never appear as text.
        final tips = find.descendant(of: find.byKey(const ValueKey('shot')), matching: find.byType(Tooltip));
        var hovered = 0;
        for (final e in tips.evaluate().toList()) {
          final tip = e.widget as Tooltip;
          final msg = tip.message;
          final box = e.renderObject;
          if (msg == null || msg.isEmpty || box is! RenderBox || !box.attached || !box.hasSize) continue;
          if (find.descendant(of: find.byType(LineItemsEditor), matching: find.byWidget(tip)).evaluate().isEmpty &&
              find.ancestor(of: find.byWidget(tip), matching: find.byWidgetPredicate((w) => w is TooltipVisibility)).evaluate().isEmpty) {
            continue; // not on the block (the ribbon, Details, Job Info)
          }
          final before = find.text(msg).evaluate().length;
          await mouse.moveTo(box.localToGlobal(box.size.center(Offset.zero)));
          await t.pump(const Duration(seconds: 2));
          expect(find.text(msg).evaluate().length, before, reason: 'hover text "$msg"');
          await mouse.moveTo(Offset.zero);
          await t.pump(const Duration(seconds: 1));
          hovered++;
        }
        // (Round 4 dropped tooltips that could never show: the tax cell's and the tab marks'. Fewer to try, same rule.)
        expect(hovered, greaterThan(3), reason: 'the tooltips on the block were all tried');
      }

      await hoverAll();
      await http.runWithClient(() async {
        await t.tap(find.text('Edit Job'));
        await t.pumpAndSettle();
        await hoverAll();
      }, () => client);
    });

    testWidgets('a Refresh during the preview: unchanged lines follow what was loaded; a changed draft is kept', (t) async {
      var items = fractional();
      final client = _liveServer(() => _record(items: items), _options());
      _requests.clear();
      t.view.physicalSize = const Size(1500, 1500);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await http.runWithClient(() async {
        await t.pumpWidget(MaterialApp(theme: ThemeData(useMaterial3: true, fontFamily: 'Segoe UI'), home: const JobDetailScreen(jobId: _id)));
        await t.pumpAndSettle();
        await t.tap(find.text('Edit Job'));
        await t.pumpAndSettle();
        // Service Fusion's copy changes (the office edited it there); a Refresh shows it in the preview at once.
        items = [...fractional()..removeLast(), _item(3, 'Spring Replacement | Labor, two springs', qty: 2, rate: 150, tax: false)];
        await t.tap(find.byTooltip('Refresh'));
        await t.pumpAndSettle();
        expect(_inTable('Spring Replacement | Labor, two springs'), findsOneWidget, reason: 'the table is not left on the old lines');
        expect(_inTable('2.00'), findsOneWidget);
        expect(find.text('Editing preview only'), findsOneWidget, reason: 'still in the preview');
        // Now change a line in the preview, and Refresh again: the draft stays as it was typed.
        await t.tap(_inTable('2.00'));
        await t.pumpAndSettle();
        await t.enterText(find.byKey(const ValueKey('line-2-qty')), '4');
        await t.testTextInput.receiveAction(TextInputAction.done); // Enter keeps; Esc cancels since decision A1 (2026-11-23)
        await t.pumpAndSettle();
        await t.tap(find.byTooltip('Refresh'));
        await t.pumpAndSettle();
        expect(_inTable('4.00'), findsOneWidget, reason: 'a changed draft survives a Refresh');
        expect(_inTable(r'$600.00'), findsOneWidget);
        // Service Fusion changes again while the draft is kept; then the change is undone by hand. With nothing changed
        // any more, the table shows what was last loaded, not the lines the draft was made from.
        items = [_item(1, 'Stop Mold | Install New Standard Color, 70 ft', qty: 70, rate: 0.61, cost: 20), ...items.skip(1)];
        await t.tap(find.byTooltip('Refresh'));
        await t.pumpAndSettle();
        expect(_inTable('Stop Mold | Install New Standard Color, 70 ft'), findsNothing, reason: 'the draft is kept while it has changes');
        await t.tap(_inTable('4.00'));
        await t.pumpAndSettle();
        await t.enterText(find.byKey(const ValueKey('line-2-qty')), '2');
        await t.testTextInput.receiveAction(TextInputAction.done); // Enter keeps; Esc cancels since decision A1 (2026-11-23)
        await t.pumpAndSettle();
        expect(find.text('Changed, not saved'), findsNothing);
        expect(_inTable('Stop Mold | Install New Standard Color, 70 ft'), findsOneWidget, reason: 'back in step with the last load');
        expect(_inTable('70.00'), findsOneWidget);
      }, () => client);
      expect(_writes, isEmpty);
    });

    testWidgets('moving to another record while previewing leaves nothing behind', (t) async {
      final client = _liveServer(() => _record(items: fractional()), _options(), other: _record(items: _threeItems(), estimate: true, total: '1565.00', charges: _tax));
      _requests.clear();
      t.view.physicalSize = const Size(1500, 1600);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await http.runWithClient(() async {
        await t.pumpWidget(MaterialApp(theme: ThemeData(useMaterial3: true, fontFamily: 'Segoe UI'), home: const Scaffold(body: _Switcher())));
        await t.pumpAndSettle();
        await t.tap(find.text('Edit Job'));
        await t.pumpAndSettle();
        await t.tap(_inTable('1.50'));
        await t.pumpAndSettle();
        await t.enterText(find.byKey(const ValueKey('line-2-qty')), '9');
        await t.testTextInput.receiveAction(TextInputAction.done); // Enter keeps; Esc cancels since decision A1 (2026-11-23)
        await t.pumpAndSettle();
        await t.tap(find.text('Go to the estimate'));
        await t.pumpAndSettle();
        expect(find.text('Editing preview only'), findsNothing, reason: 'the preview belonged to the job');
        expect(_inTable('9.00'), findsNothing);
        expect(_inTable('SMH | Gallery Steel | GD5S | Complete Door | White'), findsOneWidget, reason: 'the estimate\'s own lines');
        expect(_inTable('2.00'), findsOneWidget, reason: 'its weather seal, two of them');
        expect(_inTable(r'$1,565.00'), findsOneWidget);
      }, () => client);
      expect(_writes, isEmpty);
    });
  });

  group('job', () {
    // Every text box shows the I-beam (user 2026-11-23; it replaced the 2026-11-16 rule that only the description did);
    // the buttons beside them keep the pointer.
    testWidgets('every text box and its hint text show the I-beam; the description toggle the pointer', (t) async {
      final client = _server(_record(items: _threeItems(), total: '1565.00', charges: _tax), _options());
      await _open(t, client);
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      Future<MouseCursor?> cursorOver(Finder f) async {
        await mouse.moveTo(t.getCenter(f));
        await t.pump();
        return RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1);
      }

      expect(await cursorOver(_more(0)), SystemMouseCursors.click, reason: 'Description, read-only');
      await http.runWithClient(() async {
        await t.tap(find.text('Edit Job'));
        await t.pumpAndSettle();
        expect(await cursorOver(_more(1)), SystemMouseCursors.click, reason: 'Description on a line with none, editing');
        expect(await cursorOver(find.text('SMH Installation | Gallery Steel | 16x7 | White')), SystemMouseCursors.text, reason: 'a closed box');
        expect(await cursorOver(find.text('Add a line: search products and services by name or SKU')), SystemMouseCursors.text, reason: 'search hint');
        // An open row: its real fields and the description's hint text.
        await t.tap(find.text('SMH Installation | Gallery Steel | 16x7 | White'));
        await t.pumpAndSettle();
        expect(await cursorOver(find.byKey(const ValueKey('line-2-name'))), SystemMouseCursors.text, reason: 'an open field');
        await t.tap(_more(2));
        await t.pumpAndSettle();
        expect(await cursorOver(find.text('Description or notes (optional)')), SystemMouseCursors.text, reason: 'description hint text');
        expect(await cursorOver(_more(2)), SystemMouseCursors.click, reason: 'the toggle beside an open row');
      }, () => client);
    });

    testWidgets('read-only: Service Fusion\'s lines and figures, no old edit button, Edit Job on the ribbon', (t) async {
      final client = _server(_record(items: _threeItems(), total: '1565.00', charges: _tax), _options());
      await _open(t, client);
      expect(find.text('Edit Job'), findsOneWidget);
      expect(find.text('Edit line items here'), findsNothing);
      expect(find.text('Editing preview only'), findsNothing);
      expect(find.byType(TextField), findsNothing, reason: 'nothing can be typed into before Edit Job');
      expect(find.text('3 line items'), findsNothing);
      expect(find.text('Internal: not on customer documents'), findsNothing);
      expect(find.text(r'$900.00'), findsNWidgets(2)); // rate and amount of line 1
      expect(find.text(r'$250.00'), findsOneWidget); // 2 x $125.00
      // The summary (USER RULE 2026-11-24): no Items line; the tax is a line of the table, under the rule, and the
      // summary's "Taxes, fees & discounts"; the job total, then the payments (none) and the balance due.
      expect(find.text(r'$1,450.00'), findsNothing);
      expect(find.text('Sales tax Rogers'), findsOneWidget, reason: 'the tax by its place (user 2026-11-24)');
      expect(_inTable('Sales tax Rogers'), findsOneWidget);
      expect(find.text(r'$115.00'), findsNWidgets(2));
      expect(find.text('Taxes, fees & discounts'), findsOneWidget);
      expect(find.text(r'$1,565.00'), findsNWidgets(2));
      expect(find.text('Payments/Deposits'), findsOneWidget);
      expect(find.text('Balance due'), findsOneWidget);
      // The description is behind its toggle, one line of it to a line, and opens in place.
      expect(_inTable('Description'), findsOneWidget);
      expect(find.textContaining('SIZE : 10'), findsNothing);
      await _shot(t, 'line_items_job');
      await t.tap(_inTable('Description'));
      await t.pumpAndSettle();
      expect(find.byIcon(Icons.expand_less_rounded), findsOneWidget, reason: 'the toggle now closes it');
      expect(find.text('SIZE : 10\' 0" X 10\' 0"\nMODEL : 3150 | R-Value 6.5 | 27 Ga Steel\n\nASSEMBLY TYPE : COMPLETE DOOR\nPANEL INSULATION : POLYSTYRENE (EPS)'), findsOneWidget);
      await _shot(t, 'line_items_job_description_open');
    });

    testWidgets('Edit Job: warning, fields, live totals; no Save; Ctrl+S saves nothing; Exit preview restores; no request but GETs', (t) async {
      final client = _server(_record(items: _threeItems(), total: '1565.00', charges: _tax), _options());
      await _open(t, client);
      await http.runWithClient(() async {
        await t.tap(find.text('Edit Job'));
        await t.pumpAndSettle();
        expect(find.text('Editing preview only'), findsOneWidget);
        expect(find.textContaining('will NOT overwrite or update Service Fusion'), findsOneWidget);
        expect(find.text('Editing'), findsOneWidget, reason: 'the ribbon button shows the state and is off');
        expect(find.text('Edit Job'), findsNothing);
        expect(find.text('Save'), findsNothing, reason: 'nothing can be saved yet, so nothing offers to');
        expect(find.text('Cancel'), findsNothing);
        expect(find.text('Exit preview'), findsOneWidget);
        expect(find.text('Changed, not saved'), findsNothing);
        expect(find.text(r'$1,565.00'), findsNWidgets(2), reason: 'nothing changed yet: Service Fusion\'s own total (and the balance due)');
        await _shot(t, 'line_items_job_editing');

        // The description field is laid out like the opened description: one fact to a line, growing with its text.
        await t.tap(find.text('SMH | Gallery Steel | GD5S | Complete Door | White'));
        await t.pumpAndSettle();
        await t.tap(_more(0));
        await t.pumpAndSettle();
        final desc = t.widget<TextField>(find.byKey(const ValueKey('line-0-description')));
        expect(desc.controller!.text, 'SIZE : 10\' 0" X 10\' 0"\nMODEL : 3150 | R-Value 6.5 | 27 Ga Steel\n\nASSEMBLY TYPE : COMPLETE DOOR\nPANEL INSULATION : POLYSTYRENE (EPS)');
        expect(desc.maxLines, isNull, reason: 'grows instead of scrolling');
        expect(desc.keyboardType, TextInputType.multiline);
        expect(find.text('Changed, not saved'), findsNothing, reason: 'opening the field changes nothing');
        await _shot(t, 'line_items_job_editing_description');
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await t.pumpAndSettle();

        // Quantity 2 -> 5 on the weather seal: 5 x $125 = $625; items $1,825; taxable $1,525 -> tax $152.50; total $1,977.50.
        await _type(t, 1, 'Weather Seal | Stop Mold | 7\' White', 'qty', '5');
        expect(find.text(r'$625.00'), findsOneWidget);
        expect(find.text(r'$1,825.00'), findsNothing, reason: 'no Items line in the summary (USER RULE 2026-11-24)');
        expect(find.text(r'$152.50'), findsNWidgets(2), reason: 'the tax line in the table, and Taxes, fees & discounts');
        expect(find.text(r'$1,977.50'), findsNWidgets(2), reason: 'the job total and the balance due');
        expect(find.text('Changed, not saved'), findsOneWidget);

        // Price $300 -> $450 on the untaxed installation: items $1,975; tax unchanged; total $2,127.50.
        await _type(t, 2, 'SMH Installation | Gallery Steel | 16x7 | White', 'rate', '450');
        expect(find.text(r'$1,975.00'), findsNothing);
        expect(find.text(r'$152.50'), findsNWidgets(2), reason: 'the tax line in the table, and Taxes, fees & discounts');
        expect(find.text(r'$2,127.50'), findsNWidgets(2), reason: 'the job total and the balance due');

        // The description can be changed too.
        await _type(t, 2, 'SMH Installation | Gallery Steel | 16x7 | White', 'description', 'Two installers, half a day.');
        expect(find.byType(TextField), findsWidgets, reason: 'the toggle kept the row open');
        // A description box keeps what was typed when the keyboard moves on (Tab); Esc then closes the line
        // with nothing left to undo (Esc cancels the box being edited since decision A1, 2026-11-23).
        await t.sendKeyEvent(LogicalKeyboardKey.tab);
        await t.pump();
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await t.pumpAndSettle();
        expect(find.text('Two installers, half a day.'), findsOneWidget, reason: 'it was left open');
        await _shot(t, 'line_items_job_edited');

        // Ctrl+S from a field: the strip says it can't, and nothing is sent.
        await t.tap(find.text('Weather Seal | Stop Mold | 7\' White'));
        await t.pumpAndSettle();
        await _ctrlS(t);
        expect(find.textContaining('Not saved: saving isn\'t available yet'), findsOneWidget);
        expect(find.text(r'$2,127.50'), findsNWidgets(2), reason: 'the draft is still there after Ctrl+S (job total and balance due)');
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await t.pumpAndSettle();
        expect(_writes, isEmpty);
        await _shot(t, 'line_items_job_save_unavailable');

        // Exit preview: the original lines and Service Fusion's own figures are back.
        await t.tap(find.text('Exit preview'));
        await t.pumpAndSettle();
        expect(find.text('Editing preview only'), findsNothing);
        expect(find.text('Edit Job'), findsOneWidget);
        expect(find.byType(TextField), findsNothing);
        expect(find.text('Two installers, half a day.'), findsNothing);
        expect(find.text(r'$250.00'), findsOneWidget);
        expect(find.text(r'$300.00'), findsNWidgets(2));
        expect(find.text(r'$115.00'), findsNWidgets(2), reason: 'the tax line in the table, and Taxes, fees & discounts');
        expect(find.text(r'$1,565.00'), findsNWidgets(2), reason: 'the job total and the balance due');
        expect(find.text(r'$2,127.50'), findsNothing);

        // Editing again starts from the original, not from the abandoned draft.
        await t.tap(find.text('Edit Job'));
        await t.pumpAndSettle();
        expect(find.text('Changed, not saved'), findsNothing);
        expect(find.text(r'$1,565.00'), findsNWidgets(2), reason: 'the job total and the balance due');
      }, () => client);
      expect(_writes, isEmpty, reason: 'only GETs: $_requests');
      expect(_requests.where((r) => r.contains('/items')), isEmpty);
    });

    testWidgets('no line numbers; every line has its eye, and while editing it hides or shows the line', (t) async {
      final client = _server(_record(items: _threeItems(), total: '1565.00', charges: _tax), _options());
      await _open(t, client);
      expect(find.text('#'), findsNothing);
      expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget, reason: 'the weather seal is hidden from the customer');
      expect(find.text('Hidden from customer'), findsNothing, reason: 'the eye says it, not words (user 2026-11-13)');
      expect(find.byIcon(Icons.visibility_outlined), findsNWidgets(2), reason: 'the two shown lines (no eye in the column headings: user 2026-11-16)');
      // No hover text on the block (user 2026-11-13): the eyes are named for screen readers, so find them by that.
      Finder said(String label, {bool? toggled}) => find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == label && (toggled == null || w.properties.toggled == toggled),
      );
      expect(said('Hidden from the customer'), findsOneWidget, reason: 'read-only: it says so, nothing to click');
      await http.runWithClient(() async {
        await t.tap(find.text('Edit Job'));
        await t.pumpAndSettle();
        await t.tap(said('Show to the customer', toggled: false));
        await t.pumpAndSettle();
        expect(find.byIcon(Icons.visibility_off_outlined), findsNothing);
        expect(find.text('Changed, not saved'), findsOneWidget);
        expect(find.text(r'$1,565.00'), findsNWidgets(2), reason: 'hiding or showing a line does not change what is charged');
        await t.tap(said('Show to the customer', toggled: true).first);
        await t.pumpAndSettle();
        await _shot(t, 'line_items_job_eye');
        await t.tap(find.text('Exit preview'));
        await t.pumpAndSettle();
        expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget, reason: 'Exit preview puts the original back');
        expect(said('Hidden from the customer'), findsOneWidget);
      }, () => client);
      expect(_writes, isEmpty);
    });

    testWidgets('while editing every line has a description toggle, so a line with no description can be given one', (t) async {
      final client = _server(_record(items: _threeItems(), total: '1565.00', charges: _tax), _options());
      await _open(t, client);
      expect(_more(0), findsOneWidget, reason: 'read-only: only the line that has a description');
      expect(_more(1), findsNothing);
      expect(_more(2), findsNothing);
      await http.runWithClient(() async {
        await t.tap(find.text('Edit Job'));
        await t.pumpAndSettle();
        for (final i in [0, 1, 2]) {
          expect(_more(i), findsOneWidget);
        }
        expect(_inTable('Add description'), findsNothing, reason: 'every line says Description (user 2026-11-13)');
        expect(_inTable('Description'), findsNWidgets(3));
        // Description on the weather seal (it has none) opens an empty description box, ready to type in.
        await t.tap(_more(1));
        await t.pumpAndSettle();
        expect(find.byKey(const ValueKey('line-1-description')), findsOneWidget);
        await t.enterText(find.byKey(const ValueKey('line-1-description')), 'Black, 10 ft.');
        await t.pumpAndSettle();
        // A description box keeps what was typed when the keyboard moves on (Tab); Esc then closes the line
        // with nothing left to undo (Esc cancels the box being edited since decision A1, 2026-11-23).
        await t.sendKeyEvent(LogicalKeyboardKey.tab);
        await t.pump();
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        await t.pumpAndSettle();
        expect(find.text('Black, 10 ft.'), findsOneWidget);
        await _shot(t, 'line_items_job_description_added');
      }, () => client);
      expect(_writes, isEmpty);
    });

    testWidgets('the quantity arrows step it up and down, the totals follow, through 0 into a return', (t) async {
      final client = _server(_record(items: _threeItems(), total: '1565.00', charges: _tax), _options());
      await _open(t, client);
      expect(find.byTooltip('One more'), findsNothing, reason: 'read-only: no arrows');
      await http.runWithClient(() async {
        await t.tap(find.text('Edit Job'));
        await t.pumpAndSettle();
        expect(find.byTooltip('One more'), findsNWidgets(3));
        // The weather seal: 2 -> 3 from the closed row: 3 x $125 = $375.00.
        await t.tap(find.byTooltip('One more').at(1));
        await t.pumpAndSettle();
        expect(find.text(r'$375.00'), findsOneWidget);
        expect(find.text('Changed, not saved'), findsOneWidget);
        // The installation, from its open row: 1 -> 2, then down to 0 and on to -1 (a credit for the install; round 4).
        await t.tap(find.text('SMH Installation | Gallery Steel | 16x7 | White'));
        await t.pumpAndSettle();
        await t.tap(find.byTooltip('One more').at(2));
        await t.pumpAndSettle();
        // Two decimals, always (user 2026-11-13).
        expect(t.widget<TextField>(find.byKey(const ValueKey('line-2-qty'))).controller!.text, '2.00');
        expect(find.byKey(const ValueKey('line-2-qty')), findsOneWidget, reason: 'the row stayed open');
        expect(find.text(r'$600.00'), findsOneWidget);
        await t.tap(find.byTooltip('One less').at(2));
        await t.pumpAndSettle();
        await t.tap(find.byTooltip('One less').at(2));
        await t.pumpAndSettle();
        await t.tap(find.byTooltip('One less').at(2));
        await t.pumpAndSettle();
        expect(t.widget<TextField>(find.byKey(const ValueKey('line-2-qty'))).controller!.text, '-1.00');
        expect(find.text(r'-$300.00'), findsOneWidget, reason: 'the line\'s amount follows, sign and all');
        await _shot(t, 'line_items_job_qty_arrows');
      }, () => client);
      expect(_writes, isEmpty);
    });

    testWidgets('each line is either taxed at the record\'s own tax line or not taxed', (t) async {
      final client = _server(_record(items: _threeItems(), total: '1565.00', charges: _tax), _options());
      await _open(t, client);
      // Read-only: the line's tax by its place and rate; no SKU column.
      expect(find.text('Rogers'), findsNWidgets(2));
      expect(find.text('No tax'), findsOneWidget);
      expect(find.text('SKU'), findsNothing);
      await http.runWithClient(() async {
        await t.tap(find.text('Edit Job'));
        await t.pumpAndSettle();
        // The menu offers exactly the record's tax line (Rogers) and No tax.
        await t.tap(find.text('Rogers').at(1));
        await t.pumpAndSettle();
        expect(find.text('Rogers'), findsNWidgets(3), reason: 'the two lines, and the menu');
        expect(find.text('No tax'), findsNWidgets(2), reason: 'the installation line, and the menu');
        expect(find.text('Bentonville'), findsNothing, reason: 'no taxes the record does not charge');
        await _shot(t, 'line_items_job_tax_menu');
        // The weather seal ($250) to No tax: Rogers is now on the door only, $90.00.
        await t.tap(find.text('No tax').last);
        await t.pumpAndSettle();
        expect(find.text(r'$90.00'), findsNWidgets(2), reason: 'the tax line in the table, and Taxes, fees & discounts');
        expect(find.text(r'$1,540.00'), findsNWidgets(2), reason: 'the job total and the balance due');
        // The installation ($300) to Rogers: Rogers on $1,200, $120.00.
        await t.tap(find.text('No tax').last);
        await t.pumpAndSettle();
        await t.tap(find.text('Rogers').last);
        await t.pumpAndSettle();
        expect(find.text('Sales tax Rogers'), findsOneWidget);
        expect(find.text(r'$120.00'), findsNWidgets(2), reason: 'the tax line in the table, and Taxes, fees & discounts');
        expect(find.text(r'$1,570.00'), findsNWidgets(2), reason: 'the job total and the balance due');
        await _shot(t, 'line_items_job_tax_picked');
        await t.tap(find.text('Exit preview'));
        await t.pumpAndSettle();
        expect(find.text('Rogers'), findsNWidgets(2));
        expect(find.text(r'$1,565.00'), findsNWidgets(2), reason: 'the job total and the balance due');
      }, () => client);
      expect(_writes, isEmpty);
    });

    testWidgets('an estimate option (one tax rate of its own) offers that rate or No tax', (t) async {
      final client = _server(
        _record(items: _threeItems(), estimate: true, total: '1565.00', charges: _tax),
        _options(options: [
          {
            'id': '21', 'kind': 'estimate', 'name': 'Option 1', 'position': 0, 'isRecommended': false, 'taxRate': 9.5, 'notes': '',
            'version': 1, 'source': 'blank',
            'items': [
              {'id': 'x', 'kind': 'item', 'name': 'Opener', 'quantity': 1, 'rate': 500, 'taxable': true, 'source': 'manual'},
            ],
          },
        ]),
      );
      await _open(t, client);
      expect(find.text('Taxable'), findsOneWidget);
      await http.runWithClient(() async {
        await t.tap(find.text('Edit Estimate'));
        await t.pumpAndSettle();
        await t.tap(find.text('Taxable'));
        await t.pumpAndSettle();
        expect(find.text('Taxable'), findsNWidgets(2), reason: 'the line, and the menu');
        expect(find.text('No tax'), findsOneWidget);
        await t.tap(find.text('No tax'));
        await t.pumpAndSettle();
        expect(find.text(r'$500.00'), findsWidgets);
        expect(find.text(r'$47.50'), findsNothing, reason: 'no tax once the line is not taxed');
      }, () => client);
      expect(_writes, isEmpty);
    });

    testWidgets('Ctrl+S in the table is the same "not saved"', (t) async {
      final client = _server(_record(items: _threeItems(), total: '1565.00', charges: _tax), _options());
      await _open(t, client);
      await http.runWithClient(() async {
        await t.tap(find.text('Edit Job'));
        await t.pumpAndSettle();
        await _type(t, 1, 'Weather Seal | Stop Mold | 7\' White', 'rate', '130');
        await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await t.sendKeyEvent(LogicalKeyboardKey.keyS);
        await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await t.pumpAndSettle();
        expect(find.textContaining('Not saved: saving isn\'t available yet'), findsOneWidget);
      }, () => client);
      expect(_writes, isEmpty);
    });

    testWidgets('a line can be removed and a discount added in the preview, and Exit preview brings everything back', (t) async {
      final client = _server(_record(items: _threeItems(), total: '1565.00', charges: _tax), _options());
      await _open(t, client);
      await http.runWithClient(() async {
        await t.tap(find.text('Edit Job'));
        await t.pumpAndSettle();
        await t.tap(find.byKey(const ValueKey('line-2-actions')));
        await t.pumpAndSettle();
        // Decision A2 (2026-11-23): the rates table's words, and no item that can never be used.
        expect(find.text('Copy'), findsOneWidget);
        expect(find.text('Move up'), findsOneWidget);
        expect(find.text('Move down'), findsOneWidget);
        expect(find.text('Remove from group'), findsNothing);
        await t.tap(find.text('Delete').last); // (the ribbon has its own Delete)
        await t.pumpAndSettle();
        expect(find.text('SMH Installation | Gallery Steel | 16x7 | White'), findsNothing);
        expect(find.textContaining('from the preview'), findsOneWidget);
        expect(find.text(r'$1,265.00'), findsNWidgets(2)); // $1,150 + $115 tax: the job total and the balance due
        await t.tap(find.text('Exit preview'));
        await t.pumpAndSettle();
        expect(find.text('SMH Installation | Gallery Steel | 16x7 | White'), findsOneWidget);
        expect(find.text(r'$1,565.00'), findsNWidgets(2), reason: 'the job total and the balance due');
      }, () => client);
      expect(_writes, isEmpty);
    });

    testWidgets('one line', (t) async {
      final client = _server(
        _record(items: [_item(1, 'Service Call | Residential', rate: 89, tax: false)], total: '89.00'),
        _options(),
      );
      await _open(t, client, size: const Size(1500, 1100));
      expect(find.text(r'$89.00'), findsNWidgets(4)); // rate, amount, Items, Total
      await _shot(t, 'line_items_job_one');
    });

    testWidgets('many lines, some with long descriptions', (t) async {
      final items = [
        for (var i = 1; i <= 24; i++)
          _item(i, i % 5 == 0 ? 'Custom carriage house door with arched glass, wrought iron hardware and a matching side entry door, painted on site' : 'Door part $i | Hinge #$i | 14 ga',
              qty: (i % 4) + 1, rate: 12.5 * i, description: i % 6 == 0 ? _longText : (i % 4 == 0 ? 'Zinc plated.' : '')),
      ];
      final client = _server(_record(items: items), _options());
      await _open(t, client, size: const Size(1500, 2600));
      expect(_inTable('Description'), findsNWidgets(8));
      await _shot(t, 'line_items_job_many');
      await http.runWithClient(() async {
        await t.tap(find.text('Edit Job'));
        await t.pumpAndSettle();
        await _shot(t, 'line_items_job_many_editing');
      }, () => client);
      expect(_writes, isEmpty);
    });

    testWidgets('no lines: the empty state, and the preview can try one', (t) async {
      final client = _server(_record(items: [], total: '0.00'), _options());
      await _open(t, client, size: const Size(1500, 1100));
      expect(find.text('No products or services'), findsOneWidget);
      expect(find.text('Service Fusion has no items on this job.'), findsOneWidget);
      await _shot(t, 'line_items_job_empty');
      await http.runWithClient(() async {
        await t.tap(find.text('Edit Job'));
        await t.pumpAndSettle();
        expect(find.text('Search the catalog below to try a line.'), findsOneWidget);
        await _shot(t, 'line_items_job_empty_editing');
      }, () => client);
      expect(_writes, isEmpty);
    });

    testWidgets('someone who can\'t edit gets no Edit Job', (t) async {
      final client = _server(_record(items: _threeItems(), total: '1565.00', charges: _tax), _options(canEdit: false));
      await _open(t, client);
      expect(find.text('Edit Job'), findsNothing);
      expect(find.text('Weather Seal | Stop Mold | 7\' White'), findsOneWidget);
    });

    testWidgets('narrow window: lines stack, and edit there too', (t) async {
      final client = _server(_record(items: _threeItems(), total: '1565.00', charges: _tax), _options(canSeeCost: true));
      await _open(t, client, size: const Size(620, 1900));
      await _shot(t, 'line_items_job_narrow');
      await http.runWithClient(() async {
        await t.tap(find.byIcon(Icons.edit_outlined));
        await t.pumpAndSettle();
        expect(find.text('Editing preview only'), findsOneWidget);
        await _shot(t, 'line_items_job_narrow_editing');
      }, () => client);
      expect(_writes, isEmpty);
    });

    testWidgets('with costs (admins): the cost columns follow the preview, with no separate cost panel', (t) async {
      final client = _server(_record(items: _threeItems(), total: '1565.00', charges: _tax), _options(canSeeCost: true));
      await _open(t, client);
      expect(find.text('Internal: not on customer documents'), findsNothing);
      expect(find.text('COST'), findsOneWidget);
      expect(find.text('EXT. COST'), findsNothing);
      expect(find.text('MARGIN'), findsNothing, reason: 'no margin per line (user 2026-11-13); the summary keeps the gross profit %');
      expect(find.text(r'$40.00'), findsOneWidget); // the weather seal's unit cost
      await _shot(t, 'line_items_job_costs');
      await http.runWithClient(() async {
        await t.tap(find.text('Edit Job'));
        await t.pumpAndSettle();
        await _type(t, 1, 'Weather Seal | Stop Mold | 7\' White', 'qty', '5');
        expect(find.text('EXT. COST'), findsNothing);
        expect(find.text(r'$625.00'), findsOneWidget);
        await _shot(t, 'line_items_job_costs_editing');
      }, () => client);
      expect(_writes, isEmpty);
    });
  });

  group('estimate', () {
    Map<String, dynamic> twoOptions() => _options(
          canSeeCost: true,
          options: [
            _option('11', 'Standard', [
              _line('a', 'Gallery Steel | 16x7 | Insulated', rate: 1200, cost: 800, description: 'White, short panel.'),
              _line('b', 'Installation', rate: 300, cost: 120, taxable: false),
            ]),
            _option('12', 'Premium', recommended: true, [
              _line('c', 'Canyon Ridge | 16x7 | Faux wood', rate: 3400, cost: 2300, description: _longText),
              _line('d', 'LiftMaster 8500W wall mount opener', rate: 650, cost: 410),
              _line('e', 'Installation', qty: 1.5, rate: 300, cost: 120, taxable: false),
            ]),
          ],
        );

    testWidgets('options: read-only until Edit Estimate, then a preview with live totals that Exit preview throws away', (t) async {
      final client = _server(_record(items: _threeItems(), estimate: true, total: '1565.00', charges: _tax), twoOptions());
      await _open(t, client);
      expect(find.text('Edit Estimate'), findsOneWidget);
      expect(find.text('Edit Job'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      // Premium is recommended, so it shows first: 3,400 + 650 + 450 = 4,500; tax 10% of 4,050 = 405; total 4,905.
      expect(find.text(r'$4,905.00'), findsNWidgets(2)); // the option tile and the receipt
      await _shot(t, 'line_items_estimate');

      await http.runWithClient(() async {
        await t.tap(find.text('Edit Estimate'));
        await t.pumpAndSettle();
        expect(find.text('Editing preview only'), findsOneWidget);
        expect(find.textContaining('The original estimate stays exactly as it is.'), findsOneWidget);
        await _shot(t, 'line_items_estimate_editing');

        // Opener $650 -> $500: items 4,350; tax 10% of 3,900 = 390; total 4,740. Its tab follows the draft (round 4: it
        // used to keep the saved total beside the changed one); the saved option itself is unchanged (Exit preview below).
        await _type(t, 1, 'LiftMaster 8500W wall mount opener', 'rate', '500');
        expect(find.text(r'$4,740.00'), findsNWidgets(2), reason: 'the receipt and the option\'s tab');
        expect(find.text(r'$390.00'), findsNWidgets(2), reason: 'the tax line in the table, and Taxes, fees & discounts');
        expect(find.text(r'$4,905.00'), findsNothing);
        await t.testTextInput.receiveAction(TextInputAction.done); // Enter keeps; Esc cancels since decision A1 (2026-11-23)
        await _shot(t, 'line_items_estimate_edited');

        // The other option can be looked at while editing, and the draft is still there on the way back.
        await t.tap(find.text('Standard').first);
        await t.pumpAndSettle();
        expect(find.text('Gallery Steel | 16x7 | Insulated'), findsOneWidget);
        await t.tap(find.text('Premium').first);
        await t.pumpAndSettle();
        expect(find.text(r'$4,740.00'), findsNWidgets(2), reason: 'the draft is still there: the receipt and the tab');

        expect(find.text('Save'), findsNothing);
        await t.tap(find.text('LiftMaster 8500W wall mount opener'));
        await t.pumpAndSettle();
        await _ctrlS(t);
        expect(find.textContaining('Not saved: saving isn\'t available yet'), findsOneWidget);

        await t.tap(find.text('Exit preview'));
        await t.pumpAndSettle();
        expect(find.text('Edit Estimate'), findsOneWidget);
        expect(find.byType(TextField), findsNothing);
        expect(find.text(r'$4,740.00'), findsNothing);
        expect(find.text(r'$4,905.00'), findsNWidgets(2));
        expect(find.text(r'$650.00'), findsNWidgets(2));
      }, () => client);
      expect(_writes, isEmpty, reason: 'only GETs: $_requests');
    });

    testWidgets('no options yet: Service Fusion\'s items, previewed the same way', (t) async {
      final client = _server(_record(items: _threeItems(), estimate: true, total: '1565.00', charges: _tax), _options());
      await _open(t, client);
      expect(find.text('Edit Estimate'), findsOneWidget);
      expect(find.text('Read-only copy'), findsNothing);
      expect(find.text('Copy into Option 1'), findsNothing);
      expect(find.text('New option'), findsOneWidget);
      await _shot(t, 'line_items_estimate_sf');
      await http.runWithClient(() async {
        await t.tap(find.text('Edit Estimate'));
        await t.pumpAndSettle();
        // Its only tab ("Estimate Option", round 4) follows the draft, as its totals do (a tab used to keep the saved
        // total beside a changed one).
        final tab = find.byKey(const ValueKey('option-tab-sf'));
        expect(find.descendant(of: tab, matching: find.text(r'$1,565.00')), findsOneWidget);
        await _type(t, 1, 'Weather Seal | Stop Mold | 7\' White', 'qty', '5');
        expect(_inTable(r'$1,977.50'), findsOneWidget);
        expect(find.descendant(of: tab, matching: find.text(r'$1,977.50')), findsOneWidget, reason: 'the tab follows the draft');
        await t.tap(find.text('Exit preview'));
        await t.pumpAndSettle();
        expect(_inTable(r'$1,565.00'), findsOneWidget);
        expect(find.descendant(of: tab, matching: find.text(r'$1,565.00')), findsOneWidget, reason: 'and goes back with it');
      }, () => client);
      expect(_writes, isEmpty);
    });
  });
}
