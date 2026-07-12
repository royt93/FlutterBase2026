// Tests for the opt-in global crash guard (ad_crash_guard.dart):
//   1. An exception whose stack trace is genuinely SDK-attributed (obtained
//      by calling a REAL SDK function — verifySignedVipKey — with malformed
//      input, so the throw site is actually inside
//      package:applovin_admob_sdk/... — not a fabricated StackTrace) is
//      caught, logged, and recovers the affected AdSlot to `cooldown`
//      instead of leaving it stuck `showing`.
//   2. A control exception whose stack trace has NO SDK frame is NOT
//      swallowed — it is forwarded to whatever handler was previously
//      installed (proven by asserting the chained handler ran).

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/core/ad_crash_guard.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Minimal fake adapter exposing real [AdSlot]s — mirrors the pattern used in
/// ad_manager_core_test.dart's `_FakeAdapter`. Everything not needed here is
/// routed through noSuchMethod.
class _FakeAdapter implements AdProviderAdapter {
  @override
  final AdSlot appOpenSlot = AdSlot(type: AdSlotType.appOpen);
  @override
  final AdSlot interstitialSlot = AdSlot(type: AdSlotType.interstitial);
  @override
  final AdSlot rewardedSlot = AdSlot(type: AdSlotType.rewarded);
  @override
  final AdSlot bannerSlot = AdSlot(type: AdSlotType.banner);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Drives a real SDK code path (`verifySignedVipKey`) into failure so the
/// resulting [StackTrace] genuinely contains a
/// `package:applovin_admob_sdk/...` frame — no fabricated stack trace.
Future<({Object error, StackTrace stack})> _genuineSdkError() async {
  try {
    await verifySignedVipKey('not-a-real-key', publicKeyBase64: 'AA==');
    throw StateError('expected verifySignedVipKey to throw');
  } catch (e, st) {
    return (error: e, stack: st);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('genuine SDK-attributed stack trace actually contains the package',
      () async {
    final result = await _genuineSdkError();
    expect(result.error, isA<VipKeyException>());
    expect(isSdkAttributable(result.stack), isTrue);
  });

  test('non-SDK stack trace is not attributed to the SDK', () {
    try {
      throw StateError('host app bug, nothing to do with the SDK');
    } catch (e, st) {
      expect(isSdkAttributable(st), isFalse);
    }
  });

  group('installAdCrashGuard', () {
    late _FakeAdapter adapter;

    setUp(() {
      adapter = _FakeAdapter();
      AdManager().debugSetAdapter(adapter);
    });

    tearDown(() {
      AdManager().debugSetAdapter(null);
      FlutterError.onError = FlutterError.presentError;
      PlatformDispatcher.instance.onError = null;
    });

    test('recovers a showing slot to cooldown on an SDK-attributed error',
        () async {
      adapter.interstitialSlot.beginLoad();
      adapter.interstitialSlot.markReady();
      adapter.interstitialSlot.beginShow();
      expect(adapter.interstitialSlot.isShowing, isTrue);

      installAdCrashGuard();
      final err = await _genuineSdkError();
      FlutterError.onError!(FlutterErrorDetails(
        exception: err.error,
        stack: err.stack,
      ));

      expect(adapter.interstitialSlot.isCooldown, isTrue);
    });

    test(
        'recovers a loading slot to cooldown on an SDK-attributed platform error',
        () async {
      adapter.bannerSlot.beginLoad();
      expect(adapter.bannerSlot.isLoading, isTrue);

      installAdCrashGuard();
      final err = await _genuineSdkError();
      final handled =
          PlatformDispatcher.instance.onError!(err.error, err.stack);

      expect(handled, isTrue);
      expect(adapter.bannerSlot.isCooldown, isTrue);
    });

    test('non-SDK FlutterError is NOT swallowed — chains to previous handler',
        () {
      FlutterErrorDetails? seenByPrevious;
      FlutterError.onError = (details) => seenByPrevious = details;

      adapter.rewardedSlot.beginLoad();
      adapter.rewardedSlot.markReady();
      adapter.rewardedSlot.beginShow();

      installAdCrashGuard();
      final details = FlutterErrorDetails(
        exception: StateError('host bug'),
        stack: StackTrace.current,
      );
      FlutterError.onError!(details);

      // Forwarded to the previously-installed handler...
      expect(seenByPrevious, same(details));
      // ...and the SDK made no attempt to touch slot state for a
      // non-attributable error.
      expect(adapter.rewardedSlot.isShowing, isTrue);
    });

    test('non-SDK platform error is NOT swallowed — chains to previous handler',
        () {
      Object? seenByPrevious;
      PlatformDispatcher.instance.onError = (error, stack) {
        seenByPrevious = error;
        return true;
      };

      installAdCrashGuard();
      final error = StateError('host bug');
      final handled =
          PlatformDispatcher.instance.onError!(error, StackTrace.current);

      expect(handled, isTrue);
      expect(seenByPrevious, same(error));
    });
  });
}
