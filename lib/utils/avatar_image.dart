import 'dart:typed_data';
import 'dart:ui' as ui;

/// Crops a picture to a centred square and scales it down to at most [size] pixels, returning PNG bytes.
///
/// Photos straight from a phone are several MB and rarely square. Profile pictures are shown in small circles, so
/// this keeps the upload to a few hundred KB and the circle filled. Re-encoding also drops the camera's metadata
/// (location, device). Throws a [FormatException] when the bytes are not a picture it can read.
Future<Uint8List> squareAvatarPng(Uint8List bytes, {int size = 320}) async {
  final ui.Codec codec;
  final ui.FrameInfo frame;
  try {
    codec = await ui.instantiateImageCodec(bytes);
    frame = await codec.getNextFrame();
  } catch (_) {
    throw const FormatException('Not a readable picture.');
  }
  final source = frame.image;
  try {
    final side = source.width < source.height ? source.width : source.height;
    final out = side < size ? side : size; // never blow a small picture up
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImageRect(
      source,
      ui.Rect.fromLTWH((source.width - side) / 2, (source.height - side) / 2, side.toDouble(), side.toDouble()),
      ui.Rect.fromLTWH(0, 0, out.toDouble(), out.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.high,
    );
    final image = await recorder.endRecording().toImage(out, out);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw const FormatException('Could not encode the picture.');
      return data.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  } finally {
    source.dispose();
    codec.dispose();
  }
}
