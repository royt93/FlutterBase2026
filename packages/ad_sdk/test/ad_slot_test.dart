import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
// T78 — Backoff is no longer part of the public barrel (internal detail of
// AdSlot.beginLoad()'s default parameter); this package's own tests may
// still reach into src/ directly.
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AdSlot transitions', () {
    test('starts idle', () {
      final s = AdSlot(type: AdSlotType.interstitial);
      expect(s.value, AdSlotState.idle);
      expect(s.isIdle, isTrue);
    });

    test('beginLoad idle → loading', () {
      final s = AdSlot(type: AdSlotType.interstitial);
      expect(s.beginLoad(), isTrue);
      expect(s.value, AdSlotState.loading);
    });

    test('beginLoad rejects when already loading', () {
      final s = AdSlot(type: AdSlotType.interstitial)..beginLoad();
      expect(s.beginLoad(), isFalse);
    });

    test('markReady transitions loading → ready and clears failures', () {
      final s = AdSlot(type: AdSlotType.interstitial)
        ..beginLoad()
        ..markFailed()
        ..beginLoad();
      expect(s.consecutiveFailures, 1);
      s.markReady();
      expect(s.value, AdSlotState.ready);
      expect(s.consecutiveFailures, 0);
    });

    test('beginShow only valid from ready', () {
      final s = AdSlot(type: AdSlotType.interstitial);
      expect(s.beginShow(), isFalse);
      s.beginLoad();
      expect(s.beginShow(), isFalse);
      s.markReady();
      expect(s.beginShow(), isTrue);
      expect(s.value, AdSlotState.showing);
    });

    test('markDismissed showing → idle', () {
      final s = AdSlot(type: AdSlotType.interstitial)
        ..beginLoad()
        ..markReady()
        ..beginShow()
        ..markDismissed();
      expect(s.value, AdSlotState.idle);
    });

    test('reset fires pending callback with false', () {
      final s = AdSlot(type: AdSlotType.interstitial)..beginLoad();
      bool? received;
      s.pendingCallback = (ok) => received = ok;
      s.reset();
      expect(received, isFalse);
      expect(s.value, AdSlotState.idle);
      expect(s.pendingCallback, isNull);
    });

    test(
        'beginLoad respects backoff after fail (regression guard for fixed-cooldown)',
        () {
      final s = AdSlot(type: AdSlotType.interstitial)
        ..beginLoad()
        ..markFailed();
      expect(s.value, AdSlotState.cooldown);
      // Default backoff baseMs = 15 000 ms — too soon to retry.
      expect(s.beginLoad(), isFalse);
      // Custom tiny backoff allows immediate retry.
      expect(s.beginLoad(backoff: const Backoff(baseMs: 0, maxMs: 0)), isTrue);
    });
  });

  // Regression for the "slot dies after a show failure" bug: a plain
  // beginLoad() right after markShowFailed() is blocked by the just-armed
  // backoff window, but beginReload() must refill immediately.
  group('AdSlot beginReload (refill after show failure)', () {
    test('beginLoad is blocked in cooldown, beginReload bypasses it', () {
      final s = AdSlot(type: AdSlotType.appOpen);
      expect(s.beginLoad(), isTrue);
      s.markReady();
      expect(s.beginShow(), isTrue);
      s.markShowFailed(); // → cooldown, lastErrorAt = now
      expect(s.isCooldown, isTrue);

      // A real backoff window blocks the normal load path.
      expect(
        s.beginLoad(backoff: const Backoff(baseMs: 60000, maxMs: 600000)),
        isFalse,
        reason: 'backoff must throttle the genuine load-retry path',
      );
      expect(s.isCooldown, isTrue);

      // The refill path bypasses the cooldown window.
      expect(s.beginReload(), isTrue);
      expect(s.value, AdSlotState.loading);
    });

    test('beginReload refuses while loading or showing', () {
      final s = AdSlot(type: AdSlotType.interstitial);
      expect(s.beginReload(), isTrue); // idle → loading
      expect(s.beginReload(), isFalse, reason: 'already loading');
      s.markReady();
      expect(s.beginShow(), isTrue); // → showing
      expect(s.beginReload(), isFalse, reason: 'already showing');
    });

    test('dispose() disposes the underlying notifier', () {
      final s = AdSlot(type: AdSlotType.interstitial);
      s.dispose();
      expect(
        () => s.state.addListener(() {}),
        throwsFlutterError,
      );
    });
  });

  // 2026-08-17 fork-review audit: armLoadWatchdog() kept no handle on the
  // Timer it created, so re-arming (adapter's internal reload path arms a
  // fresh watchdog while an earlier one is still pending) left the stale
  // timer alive to fire markFailed() on the NEW loading window early.
  group('armLoadWatchdog (2026-08-17 fork-review audit)', () {
    test(
        're-arming cancels the previous watchdog — a stale timer must not '
        'fail a fresh reload window early', () {
      fakeAsync((async) {
        final s = AdSlot(type: AdSlotType.interstitial)..beginLoad();
        s.armLoadWatchdog('first', const Duration(seconds: 30));

        async.elapse(const Duration(seconds: 20));
        // reload starts before the first watchdog's 30s deadline elapses
        s.markShowFailed();
        s.beginReload();
        s.armLoadWatchdog('second', const Duration(seconds: 30));

        // total 31s since start = past the FIRST watchdog's original 30s
        // deadline, but only 11s into the second one's own 30s window.
        async.elapse(const Duration(seconds: 11));
        expect(s.isLoading, isTrue,
            reason: 'the stale first watchdog must not have fired '
                'markFailed() early');

        // now past the second watchdog's real deadline too.
        async.elapse(const Duration(seconds: 20));
        expect(s.isCooldown, isTrue);
      });
    });

    test('dispose() cancels a pending watchdog so it never fires on a '
        'disposed notifier', () {
      fakeAsync((async) {
        final s = AdSlot(type: AdSlotType.interstitial)..beginLoad();
        s.armLoadWatchdog('x', const Duration(seconds: 30));
        s.dispose();
        expect(() => async.elapse(const Duration(seconds: 31)),
            returnsNormally);
      });
    });
  });

  group('Backoff', () {
    test('zero failures = zero wait', () {
      const b = Backoff();
      expect(b.compute(0), 0);
    });

    test('grows exponentially', () {
      const b = Backoff(baseMs: 1000, maxMs: 999999);
      expect(b.compute(1), 1000);
      expect(b.compute(2), 2000);
      expect(b.compute(3), 4000);
      expect(b.compute(4), 8000);
    });

    test('caps at maxMs', () {
      const b = Backoff(baseMs: 1000, maxMs: 5000);
      expect(b.compute(10), 5000);
    });
  });
}
