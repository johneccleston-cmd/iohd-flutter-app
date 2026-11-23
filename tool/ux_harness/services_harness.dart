// Real-browser harness for the Services Catalog UX audit: the app (services_harness_app.dart) plus finders a
// DevTools-protocol driver calls. LOCAL ONLY: never shipped.
//
//   flutter build web --profile -t tool/ux_harness/services_harness.dart --output build/<new folder>
//   (profile, not release: release minifies the widget names the finders match; a new folder each time: rebuilding
//   into the same one kept the old main.dart.js)
//
// The Windows desktop run is services_harness_desktop.dart (no browser finders there).

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/material.dart';

import 'services_harness_app.dart';

Future<void> main() => runServicesHarness(beforeRun: _exposeFinders);

// ---- finders for the browser driver ---------------------------------------------------------------------------------

List<double>? _rectOf(Element e) {
  final r = e.renderObject;
  if (r is! RenderBox || !r.attached || !r.hasSize) return null;
  final o = r.localToGlobal(Offset.zero);
  if (r.size.isEmpty) return null;
  return [o.dx, o.dy, r.size.width, r.size.height];
}

JSArray<JSNumber>? _find(bool Function(Element) test, int index) {
  final hits = <List<double>>[];
  void visit(Element e) {
    if (test(e)) {
      final r = _rectOf(e);
      if (r != null) hits.add(r);
    }
    e.visitChildren(visit);
  }

  final root = WidgetsBinding.instance.rootElement;
  if (root == null) return null;
  visit(root);
  if (hits.isEmpty) return null;
  final i = index < 0 ? hits.length + index : index;
  if (i < 0 || i >= hits.length) return null;
  return [for (final v in hits[i]) v.toJS].toJS;
}

void _exposeFinders() {
  globalContext.setProperty(
    'uxRect'.toJS,
    ((JSString key, JSNumber? index) => _find((e) => e.widget.key == ValueKey<String>(key.toDart), index?.toDartInt ?? 0)).toJS,
  );
  globalContext.setProperty(
    'uxText'.toJS,
    ((JSString text, JSNumber? index) => _find((e) {
      final w = e.widget;
      return w is RichText && w.text.toPlainText() == text.toDart;
    }, index?.toDartInt ?? 0)).toJS,
  );
  globalContext.setProperty(
    'uxFocus'.toJS,
    (() {
      final f = FocusManager.instance.primaryFocus;
      final ctx = f?.context;
      // The nearest keyed widget above the focus, and the first few widget types, so the driver can say what it is.
      String? keyed;
      final types = <String>[];
      ctx?.visitAncestorElements((a) {
        if (types.length < 4) types.add(a.widget.runtimeType.toString().split('<').first);
        final k = a.widget.key;
        if (k is ValueKey<String>) {
          keyed = k.value;
          return false;
        }
        return true;
      });
      final ro = ctx?.findRenderObject();
      final rect = ro is RenderBox && ro.hasSize ? () {
        final o = ro.localToGlobal(Offset.zero);
        return '@${o.dx.round()},${o.dy.round()},${ro.size.width.round()},${ro.size.height.round()}';
      }() : '';
      return '${f?.debugLabel ?? ctx?.widget.runtimeType ?? 'none'} | key=${keyed ?? '-'} | ${types.join('<')} $rect'.toJS;
    }).toJS,
  );
  // Every widget of a type, as [x, y, w, h] each (e.g. 'InputDecorator' to measure every drawn box on screen).
  globalContext.setProperty(
    'uxAll'.toJS,
    ((JSString type) {
      final out = <JSArray<JSNumber>>[];
      void visit(Element e) {
        if (e.widget.runtimeType.toString().split('<').first == type.toDart) {
          try {
            final r = _rectOf(e);
            if (r != null) out.add([for (final v in r) v.toJS].toJS);
          } catch (_) {}
        }
        e.visitChildren(visit);
      }

      final root = WidgetsBinding.instance.rootElement;
      if (root != null) visit(root);
      return out.toJS;
    }).toJS,
  );
  globalContext.setProperty('uxLocation'.toJS, (() => harnessRouter.routerDelegate.currentConfiguration.uri.toString().toJS).toJS);
}
