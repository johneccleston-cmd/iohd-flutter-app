import 'package:flutter/widgets.dart';

import 'leave_guard_stub.dart' if (dart.library.js_interop) 'leave_guard_web.dart' as browser;

/// Stops the app leaving a page that has work on it which would be lost (the job and estimate page's Edit Job /
/// Edit Estimate preview with changes in it).
///
/// A page [register]s a check while it is open. Everything that moves to another page asks [confirm] first: the top
/// bar (tabs, menus, the drawer, search, My Profile), Jarvis's record links, the page's own links, and the route's
/// `onExit` (Back, and a `go` to another record in the same section). Each check may ask the person, and returns
/// false to stay. In the browser, closing or reloading the tab also asks while any page [holdsWork].
class LeaveGuard {
  LeaveGuard._();

  static final List<_Entry> _entries = [];
  static Future<bool>? _asking;

  /// Adds [canLeave]; [holdsWork] says whether there is anything to lose right now (for the browser's own
  /// "Leave site?" prompt, which can't wait for an answer). Returns the function that removes it.
  static VoidCallback register({required Future<bool> Function() canLeave, required bool Function() holdsWork}) {
    final entry = _Entry(canLeave, holdsWork);
    _entries.add(entry);
    browser.watchUnload(() => _entries.any((e) => e.holdsWork()));
    return () {
      _entries.remove(entry);
      if (_entries.isEmpty) browser.watchUnload(null);
    };
  }

  /// True when every page agrees to be left. While one question is on screen a second request waits for the same
  /// answer, so a double click can't stack two dialogs.
  static Future<bool> confirm() {
    final pending = _asking;
    if (pending != null) return pending;
    final future = _run();
    _asking = future;
    return future.whenComplete(() => _asking = null);
  }

  static Future<bool> _run() async {
    for (final e in List.of(_entries)) {
      if (!await e.canLeave()) return false;
    }
    return true;
  }

  /// Runs [go] once the pages agree.
  static Future<void> leave(VoidCallback go) async {
    if (await confirm()) go();
  }

  /// For tests.
  @visibleForTesting
  static int get count => _entries.length;
}

class _Entry {
  final Future<bool> Function() canLeave;
  final bool Function() holdsWork;
  _Entry(this.canLeave, this.holdsWork);
}
