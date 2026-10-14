// Renders the Calendar screen with fake events at several window sizes. Run:
//   flutter test test/calendar_render_test.dart --update-goldens
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iohd_desktop/calendar_screen.dart';

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer)));
  }
  await loader.load();
}

const _cust = ['Schuber Mitchell Homes', 'Quality Building Systems Inc.', 'Lennar', 'Moser Construction LLC', 'Trinitas', 'OZ Homes, LLC', 'Heather & Tom Whitfield'];
const _st = ['Scheduled - Full Day', 'Need To Schedule', 'Complete', 'Partially Complete', 'Estimate Provided', 'Need Deposit'];
const _tech = ['Brett Hall', 'Marcus Lee', 'Dan Ruiz', ''];

http.Client _mock() => MockClient((req) async {
      final now = DateTime.now();
      final events = <Map<String, dynamic>>[];
      for (var d = 1; d <= 28; d++) {
        final n = (d * 7) % 6; // 0..5 events per day
        for (var i = 0; i < n; i++) {
          final k = d + i;
          events.add({
            'event_date': '${now.year}-${now.month.toString().padLeft(2, '0')}-${d.toString().padLeft(2, '0')}',
            'job_number': '${1099000000 + k}',
            'customer_name': _cust[k % _cust.length],
            'status': _st[k % _st.length],
            'techs': k % 3 == 0 ? 'Brett Hall, Marcus Lee' : _tech[k % _tech.length],
            'is_estimate': k % 4 == 0,
          });
        }
      }
      return http.Response(jsonEncode({'events': events}), 200);
    });

void main() {
  setUpAll(() async {
    await _loadFont('Segoe UI', ['C:/Windows/Fonts/segoeui.ttf', 'C:/Windows/Fonts/segoeuib.ttf']);
  });

  for (final s in const [(1920.0, 1080.0), (1280.0, 720.0), (800.0, 700.0), (420.0, 800.0)]) {
    testWidgets('calendar month ${s.$1.toInt()}', (t) async {
      t.view.physicalSize = Size(s.$1, s.$2);
      t.view.devicePixelRatio = 1;
      await http.runWithClient(() async {
        await t.pumpWidget(RepaintBoundary(
          key: const ValueKey('shot'),
          child: MaterialApp(theme: ThemeData(useMaterial3: true, fontFamily: 'Segoe UI'), home: const CalendarScreen()),
        ));
        await t.pumpAndSettle();
      }, _mock);
      expect(t.takeException(), isNull);
      await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('shots/calendar_month_${s.$1.toInt()}.png'));
    });
  }
}
