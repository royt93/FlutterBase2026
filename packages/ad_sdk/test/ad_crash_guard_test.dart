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
  final AdSlot rewardedInterstitialSlot =
      AdSlot(type: AdSlotType.rewardedInterstitial);
  final AdSlot _bannerSlot = AdSlot(type: AdSlotType.banner);
  @override
  AdSlot bannerSlot(Object key) => _bannerSlot;
  @override
  Iterable<AdSlot> get bannerSlots => [_bannerSlot];

  // MJ23 — the recovery pass now covers mrec and native too, which is the
  // whole point of that fix: those slots have no show-watchdog, so a crash in
  // the callback that would have advanced them used to strand them `showing`
  // for the rest of the process.
  final AdSlot _mrecSlot = AdSlot(type: AdSlotType.mrec);
  @override
  Iterable<AdSlot> get mrecSlots => [_mrecSlot];

  final AdSlot _nativeSlot = AdSlot(type: AdSlotType.native);
  @override
  Iterable<AdSlot> get nativeSlots => [_nativeSlot];

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

  test(
      'a host callback (onReward/onAdDismiss) exception is NOT attributed to '
      'the SDK just because the SDK invoked it and appears deeper in the '
      'stack', () {
    // The SDK is always on the stack beneath a host ad-callback throw — it's
    // what called the callback. Only the frame where the exception actually
    // originated (frame #0) should decide attribution; a substring search
    // over the whole trace would misattribute every host-callback bug to
    // this SDK, silently swallowing it instead of reporting it to the
    // host's own crash tool.
    final stack = StackTrace.fromString(
        '#0      MyHostWidget._onReward (package:my_app/home.dart:42:5)\n'
        '#1      AdManager._deliverReward (package:applovin_admob_sdk/src/core/ad_manager.dart:1000:5)\n'
        '#2      AdManager.showRewardedAd (package:applovin_admob_sdk/src/core/ad_manager.dart:990:5)\n');
    expect(isSdkAttributable(stack), isFalse,
        reason: 'the throw site is host code; the SDK merely appears '
            'further down the call chain because it invoked the callback');
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

    // MJ23 + B1 (second independent review). The fake's `mrecSlots` /
    // `nativeSlots` getters were added because the interface required them to
    // compile, and nothing asserted them — so deleting the three slot families
    // from `_recoverSlots` left the whole suite green. That is verbatim the
    // "fake captured data and nobody asserted it" mistake the commit adding
    // them claimed to have learned from. This is the assert.
    test('MJ23: recovers rewardedInterstitial, MREC and native slots too',
        () async {
      for (final slot in [
        adapter.rewardedInterstitialSlot,
        adapter.mrecSlots.first,
        adapter.nativeSlots.first,
      ]) {
        slot.beginLoad();
        slot.markReady();
        slot.beginShow();
        expect(slot.isShowing, isTrue);
      }

      installAdCrashGuard();
      final err = await _genuineSdkError();
      FlutterError.onError!(FlutterErrorDetails(
        exception: err.error,
        stack: err.stack,
      ));

      expect(adapter.rewardedInterstitialSlot.isCooldown, isTrue,
          reason: 'these three formats have no show-watchdog by design, so '
              'this pass is their ONLY way out of a stuck `showing`');
      expect(adapter.mrecSlots.first.isCooldown, isTrue);
      expect(adapter.nativeSlots.first.isCooldown, isTrue);
    });

    test(
        'recovers a loading slot to cooldown on an SDK-attributed platform error',
        () async {
      adapter.bannerSlot('k').beginLoad();
      expect(adapter.bannerSlot('k').isLoading, isTrue);

      installAdCrashGuard();
      final err = await _genuineSdkError();
      final handled =
          PlatformDispatcher.instance.onError!(err.error, err.stack);

      expect(handled, isTrue);
      expect(adapter.bannerSlot('k').isCooldown, isTrue);
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

    // Round-27 backlog B6 — a host that provider-switches or logs out/in
    // within one process calls initialize() (and therefore this) repeatedly.
    test(
        'round-27 B6: a second call does not stack another wrapper layer '
        'around the still-installed handler', () async {
      installAdCrashGuard();
      final afterFirst = FlutterError.onError;
      installAdCrashGuard();
      final afterSecond = FlutterError.onError;

      expect(identical(afterFirst, afterSecond), isTrue,
          reason: 'a repeat call with nothing having replaced the handler '
              'since must be a no-op, not wrap yet another layer around it');

      // The single installed layer must still work correctly afterwards.
      adapter.interstitialSlot.beginLoad();
      adapter.interstitialSlot.markReady();
      adapter.interstitialSlot.beginShow();
      final err = await _genuineSdkError();
      FlutterError.onError!(FlutterErrorDetails(
        exception: err.error,
        stack: err.stack,
      ));
      expect(adapter.interstitialSlot.isCooldown, isTrue);
    });

    test(
        'round-27 B6: DOES reinstall if something else replaced the handler '
        'since the last call (e.g. destroy() cycle, or another test)', () {
      installAdCrashGuard();
      // Something else takes ownership of the slot in between — a fresh
      // destroy()+initialize() cycle in the host, or plain test isolation.
      FlutterError.onError = FlutterError.presentError;

      installAdCrashGuard();
      expect(identical(FlutterError.onError, FlutterError.presentError), isFalse,
          reason: 'must actually (re)install — the previous guard layer is '
              'gone, so silently no-op-ing here would leave no guard at all');
    });
  });
}
