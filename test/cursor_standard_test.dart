// The app's cursor standard (user, 2026-11-23): anything clickable shows the pointer, even over its own label, and an
// input box shows the I-beam. The app-wide selection used to give every Text an I-beam of its own, which covered the
// pointer over the words in a button.
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/main.dart' show officeTheme;
import 'package:iohd_desktop/widgets/page_selection.dart';

void main() {
  testWidgets('buttons show the pointer over their labels, input boxes the I-beam', (t) async {
    final controller = TextEditingController(text: 'typed words');
    await t.pumpWidget(
      MaterialApp(
        theme: officeTheme(),
        builder: appSelectionBuilder,
        home: Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(onPressed: () {}, child: const Text('Text button label')),
                FilledButton(onPressed: () {}, child: const Text('Filled button label')),
                OutlinedButton(onPressed: () {}, child: const Text('Outlined button label')),
                PopupMenuButton<int>(
                  itemBuilder: (_) => const [PopupMenuItem(value: 1, child: Text('Menu row'))],
                  // Flutter's own popup button only shows the pointer on the web, so the app wraps the face in ClickCursor.
                  child: const ClickCursor(
                    child: Padding(padding: EdgeInsets.all(8), child: Text('Menu button label')),
                  ),
                ),
                SizedBox(width: 240, child: TextField(controller: controller, decoration: const InputDecoration(hintText: 'Hint'))),
                SizedBox(width: 240, child: TextField(decoration: const InputDecoration(hintText: 'Empty box hint'))),
              ],
            ),
          ),
        ),
      ),
    );

    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    Future<MouseCursor?> over(Finder f) async {
      await mouse.moveTo(t.getCenter(f));
      await t.pump();
      return RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1);
    }

    expect(await over(find.text('Text button label')), SystemMouseCursors.click);
    expect(await over(find.text('Filled button label')), SystemMouseCursors.click);
    expect(await over(find.text('Outlined button label')), SystemMouseCursors.click);
    expect(await over(find.text('Menu button label')), SystemMouseCursors.click);
    expect(await over(find.byType(TextField).first), SystemMouseCursors.text, reason: 'a box with words in it');
    expect(await over(find.text('Empty box hint')), SystemMouseCursors.text, reason: 'the hint inside an empty box');

    // The words inside an open menu are clickable too.
    await t.tap(find.text('Menu button label'));
    await t.pumpAndSettle();
    expect(await over(find.text('Menu row')), SystemMouseCursors.click);
  });

  // Flutter's InkWell shows the pointer on the web only; on Windows and macOS it is the arrow unless it names a cursor.
  // `WidgetStateMouseCursor.clickable` is the pointer when the InkWell can be tapped and the arrow when it cannot.
  test('every InkWell in lib/ names its cursor', () {
    final missing = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final src = f.readAsStringSync();
      for (final m in RegExp(r'(?<![A-Za-z_])InkWell\(').allMatches(src)) {
        var depth = 1, i = m.end;
        while (i < src.length && depth > 0) {
          final c = src[i++];
          if (c == '(') depth++;
          if (c == ')') depth--;
        }
        if (!src.substring(m.end, i).contains('mouseCursor:')) {
          missing.add('${f.path}:${'\n'.allMatches(src.substring(0, m.start)).length + 1}');
        }
      }
    }
    expect(missing, isEmpty, reason: 'add mouseCursor: WidgetStateMouseCursor.clickable to these InkWells');
  });
}
