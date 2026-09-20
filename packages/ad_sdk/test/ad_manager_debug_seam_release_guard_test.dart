// Round-68 audit fix (MAJOR, claude external) — `debugSetAdapter`,
// `debugVipManager`, `debugConsentManager` and `debugConfig` were only
// `@visibleForTesting` (an analyzer lint, not a runtime guard). Any code
// running in the same isolate as a shipped release app — including a
// compromised transitive dependency — could call them to silently swap out
// the real adapter/VIP/consent state, zeroing ad revenue or faking
// VIP/consent-active state with no crash and no signal.
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
}
