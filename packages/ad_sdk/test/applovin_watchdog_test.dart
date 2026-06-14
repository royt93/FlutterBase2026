// FakeAsync tests for the AppLovin App Open show watchdog — the
// platform-divergent timing logic in
// `AppLovinAdapter._scheduleAppOpenTimeoutCheck`.
//
// The watchdog reads the platform (`defaultTargetPlatform`) and the live app
// lifecycle state. Both are made deterministic here:
//   • platform via `debugDefaultTargetPlatformOverride`,
//   • lifecycle via the adapter's injected `lifecycleStateResolver`,
//   • time via `fakeAsync` so the recursive 5s timers advance instantly.
//
// The contract being locked down:
//   • iOS: the ad shows while the app stays `resumed`, so foreground is NOT
//     treated as hung — it re-arms until the 90s hard cap (this is the bug fix).
//   • Android: app foreground without a hidden callback IS a hung overlay —
//     force-dismiss after a 1-tick grace (~10s).
//   • Backgrounded (paused): ad is on screen → wait for the native callback
//     until the 90s hard cap on both platforms.
//   • A native dismiss (slot leaves `showing`) makes the watcher exit quietly.

import 'package:applovin_admob_sdk/src/adapters/applovin_adapter.dart';
import 'package:applovin_admob_sdk/src/state/ad_slot.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  AppLovinAdapter build(AppLifecycleState? Function() lifecycle) =>
      AppLovinAdapter(lifecycleStateResolver: lifecycle);

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('iOS: foreground re-arms past the 10s Android cutoff; hard cap at ~90s',
      () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    fakeAsync((async) {
      final adapter = build(() => AppLifecycleState.resumed);
      bool? dismissed;
      adapter.debugStartAppOpenWatchdog((d) => dismissed = d);

      async.elapse(const Duration(seconds: 30)); // well past 10s
      expect(dismissed, isNull,
          reason: 'iOS must keep re-arming, never force-dismiss on foreground');
      expect(adapter.appOpenSlot.isShowing, isTrue);

      async.elapse(const Duration(seconds: 70)); // total 100s > 90s cap
      expect(dismissed, isFalse, reason: 'only the 90s hard cap dismisses on iOS');
      expect(adapter.appOpenSlot.value, AdSlotState.cooldown);
    });
  });

  test('Android: force-dismisses on the 2nd foreground tick (~10s)', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    fakeAsync((async) {
      final adapter = build(() => AppLifecycleState.resumed);
      bool? dismissed;
      adapter.debugStartAppOpenWatchdog((d) => dismissed = d);

      async.elapse(const Duration(seconds: 5)); // tick #1 → grace, re-arm
      expect(dismissed, isNull, reason: 'first foreground tick is a grace period');

      async.elapse(const Duration(seconds: 5)); // tick #2 (10s) → force-dismiss
      expect(dismissed, isFalse,
          reason: 'Android force-dismisses a hung foreground ad at ~10s');
      expect(adapter.appOpenSlot.value, AdSlotState.cooldown);
    });
  });

  test('backgrounded (paused) waits for the native callback until the 90s cap',
      () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    fakeAsync((async) {
      final adapter = build(() => AppLifecycleState.paused); // ad on screen
      bool? dismissed;
      adapter.debugStartAppOpenWatchdog((d) => dismissed = d);

      async.elapse(const Duration(seconds: 30));
      expect(dismissed, isNull,
          reason: 'paused = ad still showing → keep waiting, do not cut it');

      async.elapse(const Duration(seconds: 70)); // > 90s
      expect(dismissed, isFalse, reason: 'hard cap eventually fires');
    });
  });

  test('native dismiss (slot leaves showing) exits the watcher quietly', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    fakeAsync((async) {
      final adapter = build(() => AppLifecycleState.resumed);
      bool? dismissed;
      adapter.debugStartAppOpenWatchdog((d) => dismissed = d);

      // Simulate AppLovin's onAdHidden resolving the show before the cap.
      adapter.appOpenSlot.markDismissed();

      async.elapse(const Duration(seconds: 30));
      expect(dismissed, isNull,
          reason: 'watcher must defer to the native dismiss, not force a result');
    });
  });
}
