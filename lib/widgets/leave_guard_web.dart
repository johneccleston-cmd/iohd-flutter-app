import 'dart:js_interop';
import 'dart:js_interop_unsafe';

bool Function()? _holdsWork;
bool _installed = false;

/// The browser's own "Leave site? Changes you made may not be saved." when the tab is closed or reloaded while
/// [holdsWork] says there is something to lose. Browsers show their own wording; a page can only ask for the prompt.
void watchUnload(bool Function()? holdsWork) {
  _holdsWork = holdsWork;
  if (_installed) return;
  _installed = true;
  globalContext.callMethod(
    'addEventListener'.toJS,
    'beforeunload'.toJS,
    ((JSObject event) {
      final check = _holdsWork;
      if (check == null || !check()) return;
      event.callMethod('preventDefault'.toJS);
      event['returnValue'] = ''.toJS; // older Chrome and Edge need this as well
    }).toJS,
  );
}
