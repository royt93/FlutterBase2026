// Adapter-level tests for AdMobAdapter — the layer that previously had no
// tests and where the recent fixes live. We can't drive the real GMA native
// classes (AppOpenAd.load / ad.show), but the two riskiest fixes expose
// testable seams:
//   • `isAdFresh` — the interstitial/rewarded/app-open expiry decision.
//   • App Open show watchdog — a real Timer whose hard cap is overridable via
//     `debugSimulateAppOpenShowAndArmWatchdog`, so the "no dismiss callback →
//     force dismiss(false)" path can be exercised end-to-end without GMA.

import 'package:applovin_admob_sdk/src/adapters/admob_adapter.dart';
import 'package:applovin_admob_sdk/src/state/ad_slot.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AdMobAdapter.isAdFresh (expiry decision)', () {
    final base = DateTime(2026, 6, 14, 12, 0, 0);

    test('never-loaded (null) is not fresh', () {
      expect(AdMobAdapter.isAdFresh(null, 1, now: base), isFalse);
    });

    test('loaded within the window is fresh', () {
      final loadedAt = base.subtract(const Duration(minutes: 30));
      expect(AdMobAdapter.isAdFresh(loadedAt, 1, now: base), isTrue);
    });

    test('loaded beyond the window is stale', () {
      final loadedAt = base.subtract(const Duration(hours: 1, minutes: 1));
      expect(AdMobAdapter.isAdFresh(loadedAt, 1, now: base), isFalse);
    });

    test('4h app-open window respected', () {
      expect(
        AdMobAdapter.isAdFresh(base.subtract(const Duration(hours: 3)), 4,
            now: base),
        isTrue,
      );
      expect(
        AdMobAdapter.isAdFresh(base.subtract(const Duration(hours: 5)), 4,
            now: base),
        isFalse,
      );
    });
  });

  group('AdMobAdapter App Open watchdog', () {
    test('force-dismisses with false after the hard cap when no callback fires',
        () async {
      final adapter = AdMobAdapter();
      bool? dismissed;
      adapter.debugSimulateAppOpenShowAndArmWatchdog(
        (d) => dismissed = d,
        const Duration(milliseconds: 40),
      );
      expect(adapter.debugWatchdogArmed, isTrue);
      expect(adapter.appOpenSlot.isShowing, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(dismissed, isFalse, reason: 'caller must be force-dismissed');
      expect(adapter.appOpenSlot.value, AdSlotState.cooldown,
          reason: 'markShowFailed → cooldown');
      expect(adapter.debugWatchdogArmed, isFalse, reason: 'timer self-cleared');
    });

    test('dispose cancels the watchdog — it never fires twice', () async {
      final adapter = AdMobAdapter();
      var calls = 0;
      adapter.debugSimulateAppOpenShowAndArmWatchdog(
        (_) => calls++,
        const Duration(milliseconds: 40),
      );

      // dispose flushes the pending dismiss callback once and cancels the timer.
      await adapter.dispose();
      expect(calls, 1,
          reason: 'dispose flushes the pending callback exactly once');
      expect(adapter.debugWatchdogArmed, isFalse);

      // Past the original cap — the cancelled timer must NOT fire again.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(calls, 1, reason: 'cancelled watchdog must not double-fire');
    });
  });

  group('AdMobAdapter.dispose() releases ValueNotifiers', () {
    test('slot and banner notifiers are disposed, not just reset', () async {
      final adapter = AdMobAdapter();
      await adapter.dispose();

      expect(() => adapter.appOpenSlot.state.addListener(() {}),
          throwsFlutterError);
      expect(() => adapter.interstitialSlot.state.addListener(() {}),
          throwsFlutterError);
      expect(() => adapter.rewardedSlot.state.addListener(() {}),
          throwsFlutterError);
      expect(() => adapter.bannerSlot.state.addListener(() {}),
          throwsFlutterError);
      expect(
          () => adapter.banner.isLoaded.addListener(() {}), throwsFlutterError);
      expect(
          () => adapter.mrecSlot.state.addListener(() {}), throwsFlutterError);
      expect(
          () => adapter.mrec.isLoaded.addListener(() {}), throwsFlutterError);
      expect(() => adapter.nativeSlot.state.addListener(() {}),
          throwsFlutterError);
      expect(
          () => adapter.native.isLoaded.addListener(() {}), throwsFlutterError);
    });
  });

  group('AdMobAdapter native slot', () {
    test('beginLoad/markReady/markFailed drive nativeSlot state', () {
      final adapter = AdMobAdapter();
      expect(adapter.nativeSlot.beginLoad(), isTrue);
      expect(adapter.nativeSlot.isLoading, isTrue);

      adapter.nativeSlot.markReady();
      expect(adapter.nativeSlot.value, AdSlotState.ready);

      adapter.nativeSlot.reset();
      expect(adapter.nativeSlot.beginLoad(), isTrue);
      adapter.nativeSlot.markFailed();
      expect(adapter.nativeSlot.value, AdSlotState.cooldown);
    });
  });
}
