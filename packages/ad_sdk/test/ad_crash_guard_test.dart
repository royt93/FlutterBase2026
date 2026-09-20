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
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// A widget whose `build()` calls into a real SDK function
/// (`MonetizationArbitrator.decide`) with a host-supplied callback that
/// throws — for the widget-test below, proving the crash-guard fix holds
/// under Flutter's OWN exception-during-build handling, not just a plain
/// unit-test `try`/`catch`.
class _ThrowingDuringBuildWidget extends StatelessWidget {
  const _ThrowingDuringBuildWidget();

  @override
  Widget build(BuildContext context) {
    final arbitrator = MonetizationArbitrator();
    arbitrator.registerVipLikelihoodEstimator(
        () => throw StateError('host bug thrown during widget build'));
    arbitrator.decide(AdSlotType.interstitial);
    return const SizedBox.shrink();
  }
}

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

  test(
      'REAL (not fabricated) stack trace from a host callback thrown out of '
      'an actual SDK call also does not attribute to the SDK', () {
    // MonetizationArbitrator.decide() calls a host-supplied estimator
    // synchronously and unguarded (lib/src/monetization/
    // monetization_arbitrator.dart:263) — a real, structurally identical
    // stand-in for onReward/onAdDismiss for the purpose of proving the
    // FIRST-FRAME assumption holds against genuine Dart runtime stack
    // trace formatting, not just a hand-written fake string.
    final arbitrator = MonetizationArbitrator();
    arbitrator.registerVipLikelihoodEstimator(() {
      throw StateError('host bug inside the likelihood estimator');
    });

    try {
      arbitrator.decide(AdSlotType.interstitial);
      fail('expected decide() to propagate the estimator\'s exception');
    } catch (e, st) {
      expect(e, isA<StateError>());
      // Empirical proof this SDK's package genuinely appears somewhere in
      // this REAL stack trace beneath the actual throw site — exactly why
      // the old whole-trace `contains` check misattributed this kind of
      // host bug to the SDK.
      expect(st.toString(), contains('package:applovin_admob_sdk/'),
          reason: 'sanity — if this fails, the test stopped proving what '
              'it claims to prove');
      expect(isSdkAttributable(st), isFalse,
          reason: 'the throw site (frame #0) is the host\'s own callback, '
              'even though the SDK genuinely appears deeper in this real '
              'stack trace');
    }
  });

  test('empty stack trace is not attributed to the SDK (no crash)', () {
    expect(isSdkAttributable(StackTrace.fromString('')), isFalse);
  });

  test('stack trace with only blank lines before nothing real is not '
      'attributed to the SDK (no crash)', () {
    expect(isSdkAttributable(StackTrace.fromString('\n\n   \n')), isFalse);
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

    test(
        'a host bug thrown from inside a real SDK call (SDK genuinely on '
        'the stack, just not at the throw site) still reaches the '
        'previous handler through the FULL installAdCrashGuard() pipeline',
        () {
      // Regression test for the exact bug this round fixed: this is not
      // just isSdkAttributable() in isolation, but the real
      // FlutterError.onError wiring installAdCrashGuard() sets up, fed a
      // REAL stack trace where the SDK genuinely appears (proving the old
      // whole-trace `contains` check really would have swallowed this).
      FlutterErrorDetails? seenByPrevious;
      FlutterError.onError = (details) => seenByPrevious = details;

      adapter.rewardedSlot.beginLoad();
      adapter.rewardedSlot.markReady();
      adapter.rewardedSlot.beginShow();

      installAdCrashGuard();

      final arbitrator = MonetizationArbitrator();
      arbitrator.registerVipLikelihoodEstimator(() {
        throw StateError('host bug inside the likelihood estimator');
      });
      late StackTrace realStack;
      try {
        arbitrator.decide(AdSlotType.interstitial);
        fail('expected decide() to propagate');
      } catch (_, st) {
        realStack = st;
      }
      expect(realStack.toString(), contains('package:applovin_admob_sdk/'),
          reason: 'sanity — this must be a real stack where the SDK '
              'genuinely appears, not a trivial host-only trace');

      final details = FlutterErrorDetails(
        exception: StateError('host bug inside the likelihood estimator'),
        stack: realStack,
      );
      FlutterError.onError!(details);

      expect(seenByPrevious, same(details),
          reason: 'must reach the host\'s own crash handler, not be '
              'swallowed as if it were an SDK bug');
      expect(adapter.rewardedSlot.isShowing, isTrue,
          reason: 'a non-attributable error must not trigger slot recovery '
              'either — that machinery is only for the SDK\'s own bugs');
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

    test(
        'round 52 audit fix (MAJOR): a host replacing ONLY FlutterError.'
        'onError does not corrupt PlatformDispatcher.onError\'s saved '
        'previous handler', () {
      var hostPlatformCalls = 0;
      bool hostPlatformHandler(Object error, StackTrace stack) {
        hostPlatformCalls++;
        return false;
      }

      PlatformDispatcher.instance.onError = hostPlatformHandler;
      installAdCrashGuard();
      final platformWrapperAfterFirst = PlatformDispatcher.instance.onError;

      // Host replaces ONLY FlutterError.onError since the last install —
      // PlatformDispatcher.onError is untouched, still this guard's own
      // wrapper from the call above.
      FlutterError.onError = FlutterError.presentError;
      installAdCrashGuard();

      expect(identical(PlatformDispatcher.instance.onError, platformWrapperAfterFirst),
          isTrue,
          reason: 'PlatformDispatcher.onError was never replaced by anyone '
              'else, so re-wrapping it here would bury the real host '
              'handler under a second layer of this guard');

      uninstallAdCrashGuard();
      // A non-SDK platform error must reach the ORIGINAL host handler, not
      // a stale copy of this guard's own first-install wrapper.
      PlatformDispatcher.instance.onError!(StateError('host bug'), StackTrace.empty);
      expect(hostPlatformCalls, 1,
          reason: 'uninstall must restore the true original host handler, '
              'not this guard\'s own previous wrapper — otherwise an '
              'SDK-attributed error keeps being intercepted forever after '
              'destroy()');
    });
  });

  testWidgets(
      'WIDGET TEST — a host bug thrown during a real widget build (SDK '
      'genuinely on the stack) surfaces via tester.takeException(), not '
      'swallowed as an SDK bug', (tester) async {
    installAdCrashGuard();
    addTearDown(() {
      FlutterError.onError = FlutterError.presentError;
      PlatformDispatcher.instance.onError = null;
    });

    await tester.pumpWidget(const _ThrowingDuringBuildWidget());

    final caught = tester.takeException();
    expect(caught, isA<StateError>(),
        reason: 'flutter_test\'s own error capture (chained to by '
            'installAdCrashGuard()) must still see this host bug — proof '
            'the fix holds under Flutter\'s real exception-during-build '
            'handling, not just a plain try/catch');
  });
}
