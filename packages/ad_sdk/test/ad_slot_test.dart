import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
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
