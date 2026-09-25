// Round-38 audit regression — three rounds deep:
//
// 1. claude CLI (independent review) found `setConsent()`'s own tail write
//    (`_adapter?.applyConsent`) had no epoch guard.
// 2. codex (re-audit) caught that fix guarded the wrong call — the REAL
//    write is `applyConsentToProviders()`, reached via
//    `AdManager.setConsent()`'s own direct call, which got guarded properly
//    next.
// 3. An on-device integration test run (real Samsung hardware) caught that
//    BOTH of those guarded calls are actually a REDUNDANT SECOND apply:
//    `AdManager.setConsent()` calls `_consentManager!.set(...)` FIRST, which
//    internally (`ConsentManager._setInternal`) does its OWN persist-then-
//    apply cycle with its OWN real async gap and NO ordering protection at
//    all — the actual, real-world path every `setConsent()`/`showDialog()`/
//    `reset()` call goes through. No unit test had ever caught this because
//    they all bypass `ConsentManager` entirely via `AdManager.debugSetAdapter`
//    /`debugConfig` — the SDK never actually gets far enough to reach
//    `ConsentManager.set()`.
//
// Root-cause fix: `ConsentManager` now has its own self-contained epoch
// (`_applyEpoch`), bumped and checked around EVERY entry point that calls
// `_applyToProviders` (`set`/`_setInternal`, `reset`, `applyToProviders`) —
// protects every caller uniformly, not just `AdManager.setConsent()`.
//
// This test targets that root-cause fix directly, using
// `ConsentManager.debugApplyBarrier` (added alongside it) to reproduce the
// real race deterministically.

import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MinimalAdapter implements AdProviderAdapter {
  @override
  final AdSlot appOpenSlot = AdSlot(type: AdSlotType.appOpen);
  @override
  final AdSlot interstitialSlot = AdSlot(type: AdSlotType.interstitial);
  @override
  final AdSlot rewardedSlot = AdSlot(type: AdSlotType.rewarded);
  @override
  final AdSlot rewardedInterstitialSlot =
      AdSlot(type: AdSlotType.rewardedInterstitial);

  @override
  void applyConsent(AdConsent consent) {}

  void Function(AdEvent)? _eventSink;
  @override
  void Function(AdEvent)? get eventSink => _eventSink;
  @override
  set eventSink(void Function(AdEvent)? sink) => _eventSink = sink;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

const _admobConfig = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'ca-app-pub-3940256099942544/6300978111',
    interstitialId: 'ca-app-pub-3940256099942544/1033173712',
    appOpenId: 'ca-app-pub-3940256099942544/9257395921',
    rewardedId: 'ca-app-pub-3940256099942544/5224354917',
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const alChannel = MethodChannel('applovin_max');
  const gmaChannel = MethodChannel('plugins.flutter.io/google_mobile_ads');

  final appLovinConsentCalls = <bool>[];

  setUp(() {
    appLovinConsentCalls.clear();
    messenger.setMockMethodCallHandler(alChannel, (call) async {
      if (call.method == 'setHasUserConsent') {
        appLovinConsentCalls.add((call.arguments as Map)['value'] as bool);
      }
      return null;
    });
    messenger.setMockMethodCallHandler(gmaChannel, (call) async => null);
    SharedPreferences.setMockInitialValues({});
    AdManager.debugAdapterFactory = (_) => _MinimalAdapter();
  });

  tearDown(() async {
    ConsentManager.debugApplyBarrier = null;
    AdManager.debugAdapterFactory = null;
    await AdManager().destroy();
    messenger.setMockMethodCallHandler(alChannel, null);
    messenger.setMockMethodCallHandler(gmaChannel, null);
  });

  test(
      'an older setConsent() call whose real provider-apply (inside '
      'ConsentManager) is delayed must never land after a newer overlapping '
      'call has already applied its own value — no stale write, ever',
      () async {
    // Bootstraps `_consentManager` for real — without this, `setConsent()`
    // only buffers and never reaches `ConsentManager.set()` at all, which is
    // exactly the blind spot every prior unit test for this bug had.
    await AdManager()
        .initialize(config: _admobConfig, onComplete: (_, _) {});
    await AdManager().setConsent(const AdConsent(hasUserConsent: true));
    appLovinConsentCalls.clear();

    // Older call: a tightening decision (user declines). Its real apply
    // (inside ConsentManager) parks right before it would fire — simulating
    // a real-world delay at `_persist()`'s real async gap.
    final olderGate = Completer<void>();
    ConsentManager.debugApplyBarrier = olderGate.future;
    final older =
        AdManager().setConsent(const AdConsent(hasUserConsent: false));
    await Future<void>.delayed(Duration.zero);
    expect(appLovinConsentCalls, isEmpty,
        reason: 'sanity: the older call must not have written anything yet '
            '— it is parked at the barrier');

    // Newer call fired right behind it, with no barrier of its own — it
    // races ahead and completes its entire real apply first.
    ConsentManager.debugApplyBarrier = null;
    final newer =
        AdManager().setConsent(const AdConsent(hasUserConsent: true));
    await newer;
    expect(appLovinConsentCalls, isNotEmpty);
    expect(appLovinConsentCalls.every((v) => v == true), isTrue,
        reason: 'the newer call must have written its own (correct) value '
            'for real');

    // The older, now-superseded call is released. Pre-fix, this would fire
    // AppLovinMAX.setHasUserConsent(false) — chronologically AFTER the
    // newer call's (true), silently re-enforcing the stale decision on the
    // real native SDK. `AdManager.setConsent()` calls `applyConsentToProviders`
    // TWICE per invocation (once via `ConsentManager.set()`, once directly)
    // — this asserts NEITHER of the older call's two attempts ever lands.
    olderGate.complete();
    await older;

    expect(appLovinConsentCalls.every((v) => v == true), isTrue,
        reason: 'the older call\'s real provider write must never fire at '
            'all once superseded — no `false` may ever appear here, from '
            'either of setConsent()\'s two write paths');
    expect(AdManager().consent.hasUserConsent, isTrue,
        reason: 'reported state must agree with what was actually applied '
            '— no divergence');
  });
}
