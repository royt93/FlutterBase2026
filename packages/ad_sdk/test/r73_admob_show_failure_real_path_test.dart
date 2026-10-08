// Round-73 audit — the REAL show-failure path (a platform show() that throws,
// the same fake the MJ25 tests use), for all four fullscreen formats, and
// through AdManager.showInterstitial for the refill it issues. The slot used to
// stay empty until the 5-minute retry timer; the refill must start immediately.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/adapters/admob_adapter.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'admob_behavioral_test.dart' show FakeGmaBridge;

const _config = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'b',
    interstitialId: 'i',
    appOpenId: 'ao',
    rewardedId: 'r',
    rewardedInterstitialId: 'ri',
  ),
  safety: AdSafetyParams(dryRun: true),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeGmaBridge bridge;
  late AdMobAdapter adapter;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AdPreferences.resetForTest();
    final prefs = await AdPreferences.getInstance();
    await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
    AdSafetyConfig.resetForReinit();
    bridge = FakeGmaBridge();
    adapter = AdMobAdapter(bridge: bridge);
    expect(await adapter.initialize(_config), isTrue);
  });

  tearDown(() => adapter.dispose());

  int loads(String k) => bridge.loads[k]!.length;

  group('adapter: a show() that throws leaves the slot immediately reloadable',
      () {
    test('interstitial', () async {
      await adapter.loadInterstitial();
      bridge.lastInter!.throwOnShow = true;
      await adapter.showInterstitial(onDone: (_) {});
      final before = loads('interstitial');

      await adapter.loadInterstitial();

      expect(loads('interstitial'), before + 1);
    });

    test('rewarded', () async {
      await adapter.loadRewarded();
      bridge.lastRewarded!.throwOnShow = true;
      await adapter.showRewarded(onDone: (_) {});
      final before = loads('rewarded');

      await adapter.loadRewarded();

      expect(loads('rewarded'), before + 1);
    });

    test('rewarded interstitial', () async {
      await adapter.loadRewardedInterstitial();
      bridge.lastRewardedInterstitial!.throwOnShow = true;
      await adapter.showRewardedInterstitial(onDone: (_) {});
      final before = loads('rewardedInterstitial');

      await adapter.loadRewardedInterstitial();

      expect(loads('rewardedInterstitial'), before + 1);
    });

    test('app open', () async {
      await adapter.loadAppOpen();
      bridge.lastAppOpen!.throwOnShow = true;
      await adapter.showAppOpen(onDismiss: (_) {});
      final before = loads('appOpen');

      await adapter.loadAppOpen();

      expect(loads('appOpen'), before + 1);
    });
  });

  group('a genuine LOAD failure is still throttled', () {
    test('interstitial: load fails -> immediate retry is refused', () async {
      bridge.failNextLoad = true;
      await adapter.loadInterstitial();
      final before = loads('interstitial');

      await adapter.loadInterstitial();

      expect(loads('interstitial'), before,
          reason: 'backoff must still protect against a flapping load');
    });
  });

  group('through AdManager.showInterstitial', () {
    setUp(() {
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _config;
      AdManager().debugVipManager = null;
      AdManager().debugCanRequestAds = true;
      AdManager().debugConnectivityReady = false;
      AdManager().debugConnectivityChanged(true);
    });
    tearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
    });

    test('a failed show starts a refill request right away', () async {
      await adapter.loadInterstitial();
      bridge.lastInter!.throwOnShow = true;
      final before = loads('interstitial');
      bool? shown;

      await AdManager().showInterstitial(onDoneFlow: (s) => shown = s);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(shown, isFalse);
      expect(loads('interstitial'), greaterThan(before),
          reason: 'the post-show refill must not be refused by the backoff');
    });
  });
}
