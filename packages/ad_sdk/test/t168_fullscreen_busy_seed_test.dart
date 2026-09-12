// codex review (T168, round 1) — `markCustomOverlayOnScreen` is a plain
// top-level function, so a host can call it before ever touching `AdManager`
// (e.g. its very first frame shows a splash-time overlay before the app
// calls `AdManager().initialize()`). The AdManager constructor only WIRES
// listeners for the busy inputs it tracks; it must also SEED
// `fullscreenBusy` from whatever their current values already are, or the
// public mirror stays stuck at its `false` default until some other busy
// input changes.
//
// This has to live in its own file: `flutter test` gives each test file its
// own isolate, so this is the only place `markCustomOverlayOnScreen(true)`
// can run strictly before `AdManager`'s singleton is first constructed in
// this process — a shared file (like ad_manager_core_test.dart) already has
// dozens of other groups that touch `AdManager()` first.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'a custom overlay marked on screen before AdManager is ever '
      'constructed is already reflected in fullscreenBusy on first access',
      () {
    markCustomOverlayOnScreen(true);

    expect(AdManager().fullscreenBusy.value, isTrue,
        reason: 'T168 — the constructor must seed fullscreenBusy from the '
            'current value of every busy input it wires a listener for, not '
            'just react to future changes');
    expect(AdManager().debugFullscreenBusyReason,
        'a custom host overlay is on screen');

    markCustomOverlayOnScreen(false);
    expect(AdManager().fullscreenBusy.value, isFalse);
  });
}
