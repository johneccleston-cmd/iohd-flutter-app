// squareAvatarPng crops a picture to a centred square and scales it down before it is uploaded as a profile photo.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:iohd_desktop/utils/avatar_image.dart';

Future<Uint8List> _picture(int w, int h) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), ui.Paint()..color = const ui.Color(0xFF336699));
  // A red block in the middle, so a crop that lost the centre would show.
  canvas.drawRect(ui.Rect.fromLTWH(w / 2 - 10, h / 2 - 10, 20, 20), ui.Paint()..color = const ui.Color(0xFFFF0000));
  final image = await recorder.endRecording().toImage(w, h);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

Future<ui.Image> _decode(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  return (await codec.getNextFrame()).image;
}

void main() {
  testWidgets('a large landscape picture becomes a 320 px square', (t) async {
    await t.runAsync(() async {
      final out = await _decode(await squareAvatarPng(await _picture(1000, 500)));
      expect(out.width, 320);
      expect(out.height, 320);
    });
  });

  testWidgets('a tall picture is cropped to a square too', (t) async {
    await t.runAsync(() async {
      final out = await _decode(await squareAvatarPng(await _picture(400, 900)));
      expect(out.width, out.height);
      expect(out.width, 320);
    });
  });

  testWidgets('a small picture is cropped but never enlarged', (t) async {
    await t.runAsync(() async {
      final out = await _decode(await squareAvatarPng(await _picture(200, 150)));
      expect(out.width, 150);
      expect(out.height, 150);
    });
  });

  testWidgets('the middle of the picture survives the crop', (t) async {
    await t.runAsync(() async {
      final out = await _decode(await squareAvatarPng(await _picture(800, 400)));
      final data = (await out.toByteData())!; // RGBA
      final i = ((out.height ~/ 2) * out.width + out.width ~/ 2) * 4;
      expect([data.getUint8(i), data.getUint8(i + 1), data.getUint8(i + 2)], [255, 0, 0]);
    });
  });

  testWidgets('bytes that are not a picture are refused', (t) async {
    await t.runAsync(() async {
      await expectLater(squareAvatarPng(Uint8List.fromList([1, 2, 3, 4])), throwsFormatException);
    });
  });

  testWidgets('the upload stays well under the 1 MB the server allows', (t) async {
    await t.runAsync(() async {
      final bytes = await squareAvatarPng(await _picture(4000, 3000));
      expect(bytes.length, lessThan(1024 * 1024));
    });
  });
}
