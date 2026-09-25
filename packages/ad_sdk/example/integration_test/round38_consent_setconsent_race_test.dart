// On-device integration test for round-38 audit MAJOR-2 — three rounds
// deep, this one caught by running on real Samsung hardware:
//
// 1. claude CLI found `setConsent()`'s own tail write had no epoch guard.
// 2. codex (re-audit) caught that fix guarded the wrong call — the real
//    write is `applyConsentToProviders()`, reached via a direct call inside
//    `AdManager.setConsent()`.
// 3. Running the fix's own integration test on a REAL Samsung device (not
//    just mocked-channel unit tests) immediately failed the test's own
//    sanity check — the "older" call's write fired essentially instantly,
//    before the newer call was even involved. Root cause: `AdManager
//    .setConsent()` calls `_consentManager!.set(...)` FIRST, and THAT
//    (`ConsentManager._setInternal`) does its own persist-then-apply cycle
//    with its own real async gap and NO ordering protection at all — the
//    actual path every `setConsent()`/`showDialog()`/`reset()` call goes
//    through in real use. AdManager's own direct call (guarded in rounds 1-2)
//    turned out to be a redundant SECOND apply of the same value.
//
// Root-cause fix: `ConsentManager` now has its own self-contained epoch,
// checked around every entry point that reaches `_applyToProviders`.
//
// Why the method channel is mocked even though this is an on-device test:
// `applyConsentToProviders()` calls the real `AppLovinMAX` plugin class
// directly, not through the injectable `AdProviderAdapter` interface, so
// `AdManager.debugAdapterFactory` cannot intercept it. Mocking
// `MethodChannel('applovin_max')` at the Flutter-engine boundary (supported
// by `IntegrationTestWidgetsFlutterBinding` the same way `flutter_test`'s
// binding supports it) is the only way to observe the actual call order
// without a real AppLovin SDK key (never committed to this repo) or a way to
// read back "what's currently applied" from the native side, which neither
// ad SDK exposes anyway.
//
// `ConsentManager.debugApplyBarrier` (added alongside the root-cause fix) is
// a pure Dart-side delay inserted right before the guarded write, at the
// actual point that matters — it makes the race's timing window
// controllable instead of relying on real platform-channel scheduling to
// happen to reorder two calls.
//
// Unit-level coverage of the same fix (same mocking technique, plain
// `flutter test`, no device): test/consent_setconsent_race_test.dart.
//
// Run with:
//   flutter test integration_test/round38_consent_setconsent_race_test.dart -d <device>

import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _admobConfig = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'ca-app-pub-3940256099942544/6300978111',
    interstitialId: 'ca-app-pub-3940256099942544/1033173712',
    appOpenId: 'ca-app-pub-3940256099942544/9257395921',
    rewardedId: 'ca-app-pub-3940256099942544/5224354917',
  ),
  safety: AdSafetyParams(dryRun: true),
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const alChannel = MethodChannel('applovin_max');

  final appLovinConsentCalls = <bool>[];

  setUp(() {
    appLovinConsentCalls.clear();
    messenger.setMockMethodCallHandler(alChannel, (call) async {
      if (call.method == 'setHasUserConsent') {
        appLovinConsentCalls.add((call.arguments as Map)['value'] as bool);
      }
      return null;
    });
  });

  tearDown(() async {
    ConsentManager.debugApplyBarrier = null;
    await AdManager().destroy();
    messenger.setMockMethodCallHandler(alChannel, null);
  });

  testWidgets(
      'an older setConsent() call whose real provider-apply (inside '
      'ConsentManager) is delayed must never land after a newer overlapping '
      'call has already applied its own value (round-38 MAJOR-2)',
      (tester) async {
    await AdManager()
        .initialize(config: _admobConfig, onComplete: (_, _) {});
    await AdManager().setConsent(const AdConsent(hasUserConsent: true));
    appLovinConsentCalls.clear();

    // Older call: a tightening decision (user declines). Its real apply
    // (inside ConsentManager) parks right before it would fire.
    final olderGate = Completer<void>();
    ConsentManager.debugApplyBarrier = olderGate.future;
    final older =
        AdManager().setConsent(const AdConsent(hasUserConsent: false));
    await tester.pump(const Duration(milliseconds: 100));
    expect(appLovinConsentCalls, isEmpty,
        reason: 'sanity: the older call must not have written anything yet '
            '— it is parked at the barrier');

    // Newer call fired right behind it — user immediately changes their
    // mind. No barrier of its own, so it completes its entire real apply
    // first.
    ConsentManager.debugApplyBarrier = null;
    final newer =
        AdManager().setConsent(const AdConsent(hasUserConsent: true));
    await newer;
    expect(appLovinConsentCalls, isNotEmpty);
    expect(appLovinConsentCalls.every((v) => v == true), isTrue);

    // The older, now-superseded call is released. Pre-fix, this fired
    // AppLovinMAX.setHasUserConsent(false) — chronologically AFTER the
    // newer call's (true) — silently re-enforcing the stale decision.
    olderGate.complete();
    await older;

    expect(appLovinConsentCalls.every((v) => v == true), isTrue,
        reason: 'the older call\'s real provider write must never fire at '
            'all once superseded — no `false` may ever appear here');
    expect(AdManager().consent.hasUserConsent, isTrue,
        reason: 'reported state must agree with what was actually applied '
            '— no divergence');
    expect(tester.takeException(), isNull);
  });
}
