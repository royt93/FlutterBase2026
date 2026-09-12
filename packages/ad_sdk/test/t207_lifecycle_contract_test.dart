import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final manager = AdManager();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AdPreferences.resetForTest();
    await manager.destroy();
    final prefs = await AdPreferences.getInstance();
    await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
    manager.debugConfig = null;
    manager.debugSetAdapter(FakeAdProviderAdapter());
    manager.debugConfig = const AdConfig(
      provider: AdProvider.admob,
      admob: AdMobConfig(
        bannerId: 'test',
        interstitialId: 'test',
        rewardedId: 'test',
        appOpenId: 'test',
      ),
      safety: AdSafetyParams(dryRun: true, minSessionDurationBeforeAd: 0),
    );
  });

  tearDown(() async {
    await manager.destroy();
    manager.debugConfig = null;
    manager.debugSetAdapter(null);
  });

  test('load/show lifecycle returns to idle and remains reusable', () async {
    await manager.loadInterstitial();
    expect(manager.adapter!.interstitialSlot.isReady, isTrue);
    var shown = false;
    await manager.showInterstitial(onDoneFlow: (value) => shown = value);
    expect(shown, isTrue);
    expect(manager.adapter!.interstitialSlot.isShowing, isFalse);
    expect(manager.adapter!.interstitialSlot.isLoading, isFalse);
    await manager.loadInterstitial();
    expect(manager.adapter!.interstitialSlot.isReady, isTrue);
  });

  test('destroy is idempotent and clears adapter/session state', () async {
    await manager.loadRewardedAd();
    final first = manager.destroy();
    final second = manager.destroy();
    await Future.wait([first, second]);
    expect(manager.isInitialised, isFalse);
    expect(manager.adapter, isNull);
    await manager.destroy();
  });

  test('destroy during an in-flight show leaves no fullscreen busy state',
      () async {
    manager.adapter!.interstitialSlot.beginLoad();
    manager.adapter!.interstitialSlot.markReady();
    manager.adapter!.interstitialSlot.beginShow();
    expect(manager.fullscreenBusy.value, isTrue);
    await manager.destroy();
    expect(manager.fullscreenBusy.value, isFalse);
    expect(manager.adapter, isNull);
  });

  test('a fresh adapter can be installed after destroy without stale state',
      () async {
    await manager.destroy();
    final replacement = FakeAdProviderAdapter();
    manager.debugSetAdapter(replacement);
    manager.debugConfig = const AdConfig(
      provider: AdProvider.admob,
      admob: AdMobConfig(
        bannerId: 'test',
        interstitialId: 'test',
        rewardedId: 'test',
        appOpenId: 'test',
      ),
      safety: AdSafetyParams(dryRun: true, minSessionDurationBeforeAd: 0),
    );
    await manager.loadInterstitial();
    expect(replacement.interstitialSlot.isReady, isTrue);
    expect(manager.adapter, same(replacement));
  });
}
