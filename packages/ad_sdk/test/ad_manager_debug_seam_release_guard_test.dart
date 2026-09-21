// Round-68 audit fix (MAJOR, claude external) — `debugSetAdapter`,
// `debugVipManager`, `debugConsentManager` and `debugConfig` were only
// `@visibleForTesting` (an analyzer lint, not a runtime guard). Any code
// running in the same isolate as a shipped release app — including a
// compromised transitive dependency — could call them to silently swap out
// the real adapter/VIP/consent state, zeroing ad revenue or faking
// VIP/consent-active state with no crash and no signal.
//
// Round-69 audit fix (MAJOR, 3 internal forks) — round 68's guard covered
// only those 5 seams; ~28 other `@visibleForTesting` setters/methods on
// `AdManager` shared the exact same gap (no runtime check, just the lint).
// Misuse in a shipped release app could forge consent
// (`debugApplyUmpConsentResult`), reopen a footgun the SDK just closed
// (`debugFootgunBlocked`, `debugTestIdFootgunBlocked`), wipe every guard at
// once (`debugResetGuardState`), or reset the invalid-traffic cooldowns the
// ad-request throttling exists to enforce. All 33 now share the same guard;
// this file adds representative coverage across categories rather than one
// test per seam — the pattern is what needs proving, not each application
// of it.
//
// These tests simulate a release build via
// `AdManager.debugSimulateReleaseModeForTestSeams` (kReleaseMode itself is
// always false under `flutter test`) and assert each seam is a no-op while
// "released".
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _config = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
      bannerId: 'b', interstitialId: 'i', appOpenId: 'ao', rewardedId: 'r'),
);

class _StubAdapter implements AdProviderAdapter {
  @override
  void applyConsent(AdConsent consent) {}

  @override
  Future<bool> initialize(
    AdConfig config, {
    String deviceGaid = '',
    bool isAgeRestrictedUser = false,
    AdConsent? consent,
  }) async =>
      true;

  @override
  String get tag => 'stub';

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
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    AdManager.debugSimulateReleaseModeForTestSeams = false;
    await AdManager().destroy();
    ConsentManager.resetForTest();
    AdPreferences.resetForTest();
  });

  test('debugSetAdapter is ignored while release mode is simulated',
      () async {
    await AdManager().destroy();
    expect(AdManager().adapter, isNull);

    AdManager.debugSimulateReleaseModeForTestSeams = true;
    AdManager().debugSetAdapter(_StubAdapter());

    expect(AdManager().adapter, isNull,
        reason:
            'debugSetAdapter must not apply in a (simulated) release build');
  });

  test('debugSetAdapter still applies once release mode simulation is off',
      () async {
    await AdManager().destroy();
    final stub = _StubAdapter();
    AdManager().debugSetAdapter(stub);
    expect(AdManager().adapter, same(stub));
  });

  test('debugConfig is ignored while release mode is simulated', () async {
    await AdManager().destroy();
    expect(AdManager().config, isNull);

    AdManager.debugSimulateReleaseModeForTestSeams = true;
    AdManager().debugConfig = _config;

    expect(AdManager().config, isNull,
        reason: 'debugConfig must not apply in a (simulated) release build');
  });

  test('debugConfig still applies once release mode simulation is off',
      () async {
    await AdManager().destroy();
    AdManager().debugConfig = _config;
    expect(AdManager().config, same(_config));
  });

  test('debugVipManager is ignored while release mode is simulated',
      () async {
    await AdManager().destroy();
    final before = AdManager().vip;
    final prefs = await AdPreferences.getInstance();

    AdManager.debugSimulateReleaseModeForTestSeams = true;
    AdManager().debugVipManager = VipManager(prefs);

    expect(AdManager().vip, same(before),
        reason:
            'debugVipManager must not apply in a (simulated) release build');
  });

  test('debugConsentManager is ignored while release mode is simulated',
      () async {
    await AdManager().destroy();
    final before = AdManager().consentManager;
    final prefs = await AdPreferences.getInstance();
    final mgr = await ConsentManager.bootstrap(prefs: prefs);

    AdManager.debugSimulateReleaseModeForTestSeams = true;
    AdManager().debugConsentManager = mgr;

    expect(AdManager().consentManager, same(before),
        reason: 'debugConsentManager must not apply in a (simulated) '
            'release build');
  });

  // Round-69: representative coverage for the 33 seams that round 68 did
  // not cover — one per category (ads-gate, footgun, consent-state,
  // bulk-reset), not one per seam.

  test('debugCanRequestAds is ignored while release mode is simulated',
      () async {
    await AdManager().destroy();
    final before = AdManager().canRequestAdsListenable.value;

    AdManager.debugSimulateReleaseModeForTestSeams = true;
    AdManager().debugCanRequestAds = !before;

    expect(AdManager().canRequestAdsListenable.value, before,
        reason:
            'debugCanRequestAds must not apply in a (simulated) release build');
  });

  test('debugFootgunBlocked is ignored while release mode is simulated',
      () async {
    await AdManager().destroy();
    expect(AdManager().debugFootgunBlocked, isFalse);

    AdManager.debugSimulateReleaseModeForTestSeams = true;
    AdManager().debugFootgunBlocked = true;

    expect(AdManager().debugFootgunBlocked, isFalse,
        reason: 'debugFootgunBlocked must not apply in a (simulated) '
            'release build — a real app could otherwise reopen an ads '
            'footgun the SDK just closed');
  });

  test('debugConsentExplicitlySet is ignored while release mode is simulated',
      () async {
    await AdManager().destroy();
    expect(AdManager().debugConsentExplicitlySet, isFalse);

    AdManager.debugSimulateReleaseModeForTestSeams = true;
    AdManager().debugConsentExplicitlySet = true;

    expect(AdManager().debugConsentExplicitlySet, isFalse,
        reason: 'debugConsentExplicitlySet must not apply in a (simulated) '
            'release build');
  });

  test('debugResetGuardState is ignored while release mode is simulated',
      () async {
    await AdManager().destroy();
    AdManager().debugFootgunBlocked = true; // not released yet — applies
    expect(AdManager().debugFootgunBlocked, isTrue);

    AdManager.debugSimulateReleaseModeForTestSeams = true;
    AdManager().debugResetGuardState();

    expect(AdManager().debugFootgunBlocked, isTrue,
        reason: 'debugResetGuardState must not wipe every footgun guard at '
            'once in a (simulated) release build');
  });
}
