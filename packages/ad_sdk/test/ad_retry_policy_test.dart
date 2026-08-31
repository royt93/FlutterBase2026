// T108 — per-slot retry policy: no-fill/network/invalid-request/timeout
// mean different things, so a slot can opt into a policy that treats them
// differently. A slot with no policy set (the default) must behave
// identically to plain Backoff — that's the non-breaking guarantee the
// ticket requires, and is asserted here directly.
import 'dart:math';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('default (no retryPolicy) behaves exactly like plain Backoff', () {
    test('a fresh cooldown blocks beginLoad, matching Backoff.isInCooldown',
        () {
      final slot = AdSlot(type: AdSlotType.interstitial);
      slot.beginLoad();
      slot.markFailed(errorCode: 3); // no-fill, say
      expect(slot.retryPolicy, isNull);
      expect(slot.beginLoad(), isFalse,
          reason: 'still inside the default 15s base window');
    });

    test('clearCooldownOnReconnect is a no-op with no policy', () {
      final slot = AdSlot(type: AdSlotType.interstitial);
      slot.beginLoad();
      slot.markFailed();
      final before = slot.lastErrorAt;
      slot.clearCooldownOnReconnect();
      expect(slot.lastErrorAt, same(before));
      expect(slot.beginLoad(), isFalse);
    });
  });

  group('isRetryable classifier', () {
    test('a non-retryable error code blocks beginLoad even after the '
        'backoff window would otherwise have elapsed', () {
      final slot = AdSlot(type: AdSlotType.interstitial)
        ..retryPolicy = const AdRetryPolicy(
          backoff: Backoff(baseMs: 1, maxMs: 1), // elapses almost instantly
          isRetryable: _notInvalidRequest,
        );
      slot.beginLoad();
      slot.markFailed(errorCode: _invalidRequestCode);

      expect(slot.beginLoad(), isFalse,
          reason: 'invalid-request never self-resolves by retrying');
    });

    test('a retryable error code is unblocked once the backoff window '
        'elapses', () async {
      final slot = AdSlot(type: AdSlotType.interstitial)
        ..retryPolicy = const AdRetryPolicy(
          backoff: Backoff(baseMs: 1, maxMs: 1),
          isRetryable: _notInvalidRequest,
        );
      slot.beginLoad();
      slot.markFailed(errorCode: _noFillCode);

      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(slot.beginLoad(), isTrue,
          reason: 'a no-fill is transient — must retry once the window has '
              'elapsed');
    });

    test('a null errorCode (caught-exception path) is retryable by '
        'default even under a classifier', () async {
      final slot = AdSlot(type: AdSlotType.interstitial)
        ..retryPolicy = const AdRetryPolicy(
          backoff: Backoff(baseMs: 1, maxMs: 1),
          isRetryable: _notInvalidRequest,
        );
      slot.beginLoad();
      slot.markFailed(); // no errorCode — matches an unclassified THREW path

      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(slot.beginLoad(), isTrue);
    });
  });

  group('jitter', () {
    test('jitterFraction=0 is identical to plain Backoff (deterministic)',
        () {
      final policy = const AdRetryPolicy(
          backoff: Backoff(baseMs: 10000, maxMs: 60000));
      final now = DateTime.now();
      final withoutJitter = const Backoff(baseMs: 10000, maxMs: 60000)
          .isInCooldown(lastErrorAt: now, consecutiveFailures: 1);
      final viaPolicy = !policy.canRetryNow(
        lastErrorAt: now,
        consecutiveFailures: 1,
        lastErrorCode: null,
      );
      expect(viaPolicy, withoutJitter);
    });

    test('a stable jitter draw agrees with itself across repeated checks '
        '(no flip-flopping)', () {
      final errorAt = DateTime.now();
      final policy = const AdRetryPolicy(
        backoff: Backoff(baseMs: 10000, maxMs: 60000),
        jitterFraction: 0.5,
      );
      final first = policy.canRetryNow(
          lastErrorAt: errorAt, consecutiveFailures: 3, lastErrorCode: null);
      final second = policy.canRetryNow(
          lastErrorAt: errorAt, consecutiveFailures: 3, lastErrorCode: null);
      final third = policy.canRetryNow(
          lastErrorAt: errorAt, consecutiveFailures: 3, lastErrorCode: null);
      expect([first, second, third], everyElement(equals(first)),
          reason: 'the same failure must always draw the same jitter, or a '
              'slot could pass then fail then pass beginLoad from one tick '
              'to the next with no state change in between');
    });

    test('an explicit random makes the jitter direction assertable', () {
      final policy = const AdRetryPolicy(
        backoff: Backoff(baseMs: 10000, maxMs: 60000),
        jitterFraction: 0.5,
      );
      final errorAt = DateTime.now().subtract(const Duration(seconds: 8));
      // nextDouble() == 0 → jitter term is fully negative → shortens the
      // delay below the un-jittered 10s, so 8s elapsed should already clear
      // a base-10s window shrunk by up to 50%.
      final canRetry = policy.canRetryNow(
        lastErrorAt: errorAt,
        consecutiveFailures: 1,
        lastErrorCode: null,
        random: _FixedRandom(0),
      );
      expect(canRetry, isTrue);
    });
  });

  group('resetOnConnectivityRestored', () {
    test('opted-in policy clears the cooldown early', () {
      final slot = AdSlot(type: AdSlotType.interstitial)
        ..retryPolicy = const AdRetryPolicy(
          backoff: Backoff(baseMs: 60000, maxMs: 60000),
          resetOnConnectivityRestored: true,
        );
      slot.beginLoad();
      slot.markFailed();
      expect(slot.beginLoad(), isFalse, reason: 'well inside the 60s window');

      slot.clearCooldownOnReconnect();

      expect(slot.beginLoad(), isTrue,
          reason: 'reconnect must not make a network-outage failure wait '
              'out a backoff computed while offline');
    });

    test('a policy that did not opt in still waits out the window', () {
      final slot = AdSlot(type: AdSlotType.interstitial)
        ..retryPolicy = const AdRetryPolicy(
          backoff: Backoff(baseMs: 60000, maxMs: 60000),
        );
      slot.beginLoad();
      slot.markFailed();

      slot.clearCooldownOnReconnect();

      expect(slot.beginLoad(), isFalse,
          reason: 'a no-fill/invalid-request is not a connectivity problem '
              '— opting out must mean opting out');
    });
  });

  group('reset() clears the policy-tracked error code', () {
    test('lastErrorCode is cleared alongside lastErrorAt', () {
      final slot = AdSlot(type: AdSlotType.interstitial);
      slot.beginLoad();
      slot.markFailed(errorCode: 7);
      expect(slot.lastErrorCode, 7);

      slot.reset();

      expect(slot.lastErrorCode, isNull);
    });
  });
}

const _invalidRequestCode = 2;
const _noFillCode = 3;

bool _notInvalidRequest(int? code) => code != _invalidRequestCode;

class _FixedRandom implements Random {
  _FixedRandom(this._value);
  final double _value;

  @override
  double nextDouble() => _value;

  @override
  int nextInt(int max) => 0;

  @override
  bool nextBool() => false;
}
