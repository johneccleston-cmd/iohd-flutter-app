// lib/widgets/smooth_wheel_scroll.dart
//
// Makes every mouse-wheel notch glide instead of jump, for every scrollable in the app,
// with no changes to individual screens.
//
// Flutter desktop applies each wheel notch as one instant jump. This sits in front of the
// engine's pointer stream, holds wheel deltas back, and releases them a little each frame
// with exponential easing. Spinning the wheel keeps adding to the glide without restarting
// it, and reversing direction cancels the old glide so it never fights you.
// Trackpads send pan/zoom gestures, not wheel events, so they keep their native feel.
//
// Install once in main():
//   WidgetsFlutterBinding.ensureInitialized();
//   SmoothWheelScroll.install();
//   runApp(...);

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';

class SmoothWheelScroll {
  SmoothWheelScroll._();

  /// Roughly how long a single notch takes to finish gliding. Raise it for a floatier feel.
  static Duration settle = const Duration(milliseconds: 280);

  static bool _installed = false;
  static ui.PointerDataPacketCallback? _forward;

  // The latest wheel event: where the pointer is, which device, which window.
  static ui.PointerData? _template;
  static final Stopwatch _sinceTemplate = Stopwatch();

  // Wheel distance not yet delivered, in physical pixels.
  static double _pendingX = 0;
  static double _pendingY = 0;

  static Duration? _lastFrame;
  static bool _ticking = false;

  static void install() {
    if (_installed) return;
    final dispatcher = ui.PlatformDispatcher.instance;
    final original = dispatcher.onPointerDataPacket;
    if (original == null) return; // call after WidgetsFlutterBinding.ensureInitialized()
    _forward = original;
    dispatcher.onPointerDataPacket = _onPacket;
    _installed = true;
  }

  static bool _isWheel(ui.PointerData d) =>
      d.signalKind == ui.PointerSignalKind.scroll && d.kind == ui.PointerDeviceKind.mouse;

  static void _onPacket(ui.PointerDataPacket packet) {
    var wheel = 0;
    for (final d in packet.data) {
      if (_isWheel(d)) wheel++;
    }
    if (wheel == 0) {
      _forward!(packet);
      return;
    }

    final rest = <ui.PointerData>[];
    for (final d in packet.data) {
      if (_isWheel(d)) {
        _queue(d);
      } else {
        rest.add(d);
      }
    }
    if (rest.isNotEmpty) _forward!(ui.PointerDataPacket(data: rest));
  }

  static void _queue(ui.PointerData d) {
    // Changing direction drops the old glide so the page turns around immediately.
    if (_pendingY != 0 && d.scrollDeltaY != 0 && _pendingY.sign != d.scrollDeltaY.sign) _pendingY = 0;
    if (_pendingX != 0 && d.scrollDeltaX != 0 && _pendingX.sign != d.scrollDeltaX.sign) _pendingX = 0;

    _pendingX += d.scrollDeltaX;
    _pendingY += d.scrollDeltaY;
    _template = d;
    _sinceTemplate
      ..reset()
      ..start();

    if (!_ticking) {
      _ticking = true;
      _lastFrame = null;
      SchedulerBinding.instance.scheduleFrameCallback(_tick);
    }
  }

  static void _tick(Duration now) {
    final last = _lastFrame;
    _lastFrame = now;

    // Frame gap in ms; the first frame of a glide assumes one 60 Hz frame.
    final dt = last == null ? 16.0 : ((now - last).inMicroseconds / 1000.0).clamp(1.0, 50.0);
    final tau = math.max(1.0, settle.inMicroseconds / 1000.0 / 3.0); // ~95% delivered by `settle`
    final k = 1 - math.exp(-dt / tau);

    var dx = _pendingX * k;
    var dy = _pendingY * k;
    if ((_pendingX - dx).abs() < 0.5) dx = _pendingX;
    if ((_pendingY - dy).abs() < 0.5) dy = _pendingY;
    _pendingX -= dx;
    _pendingY -= dy;

    _emit(dx, dy);

    if (_pendingX == 0 && _pendingY == 0) {
      _ticking = false;
      return;
    }
    SchedulerBinding.instance.scheduleFrameCallback(_tick);
  }

  static void _emit(double dx, double dy) {
    final t = _template;
    if (t == null || (dx == 0 && dy == 0)) return;
    _forward!(ui.PointerDataPacket(data: [
      ui.PointerData(
        viewId: t.viewId,
        embedderId: t.embedderId,
        timeStamp: t.timeStamp + _sinceTemplate.elapsed,
        change: t.change,
        kind: t.kind,
        signalKind: ui.PointerSignalKind.scroll,
        device: t.device,
        pointerIdentifier: t.pointerIdentifier,
        physicalX: t.physicalX,
        physicalY: t.physicalY,
        buttons: t.buttons,
        scrollDeltaX: dx,
        scrollDeltaY: dy,
      ),
    ]));
  }
}
