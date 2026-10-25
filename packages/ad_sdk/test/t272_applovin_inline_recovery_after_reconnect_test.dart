import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/adapters/applovin_adapter.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_max/applovin_max.dart' show AdFormat, AdViewId;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'applovin_adapter_test.dart' show FakeAppLovinBridge;

class _CountingAppLovinBridge extends FakeAppLovinBridge {
  int preloadCalls = 0;
  final List<String> preloadIds = [];

  @override
  Future<AdViewId?> preloadWidgetAdView(String id, AdFormat f) async {
    preloadCalls++;
    preloadIds.add(id);
    return preloadCalls;
  }
}

const _config = AdConfig(
  provider: AdProvider.appLovin,
  appLovin: AppLovinConfig(
    sdkKey: 'fake-sdk-key',
    bannerId: 'applovin_banner_1',
    mrecId: 'applovin_mrec_1',
    interstitialId: 'applovin_inter_1',
    appOpenId: 'applovin_app_open_1',
    rewardedId: 'applovin_rewarded_1',
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _CountingAppLovinBridge bridge;
  late AppLovinAdapter adapter;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AdPreferences.resetForTest();
    final prefs = await AdPreferences.getInstance();
    await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
    AdSafetyConfig.resetForReinit();

    bridge = _CountingAppLovinBridge();
    adapter = AppLovinAdapter(bridge: bridge);
    expect(await adapter.initialize(_config), isTrue);
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _config;
    AdManager().debugVipManager = null;
    AdManager().debugReconnectDebounce = const Duration(milliseconds: 10);
  });

  tearDown(() async {
    AdManager().debugSetAdapter(null);
    AdManager().debugConfig = null;
    await adapter.dispose();
  });

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 50));

  group('AppLovinAdapter.recoverInlineAdsAfterReconnect (T272)', () {
    test('a banner that had error while offline is reloaded on reconnect',
        () async {
      await adapter.preloadBanner('banner_k');
      expect(bridge.preloadCalls, 1);

      // Simulate load failure while offline (sets error and marks slot failed)
      adapter.banner('banner_k').markError();
      adapter.bannerSlot('banner_k').markFailed();
      expect(adapter.banner('banner_k').needsRecovery, isTrue);

      final callsBefore = bridge.preloadCalls;
      adapter.recoverInlineAdsAfterReconnect();
      await settle();

      expect(bridge.preloadCalls, callsBefore + 1,
          reason: 'banner in error must be re-preloaded on reconnect');
      expect(adapter.banner('banner_k').hasError.value, isFalse);
    });

    test('a banner that already has an ad is left alone', () async {
      await adapter.preloadBanner('banner_ok');
      expect(bridge.preloadCalls, 1);
      adapter.banner('banner_ok').clearError();
      expect(adapter.banner('banner_ok').needsRecovery, isFalse);

      final callsBefore = bridge.preloadCalls;
      adapter.recoverInlineAdsAfterReconnect();
      await settle();

      expect(bridge.preloadCalls, callsBefore,
          reason: 'successful banner must not reload on reconnect');
    });

    test('an MREC that had error while offline is reloaded on reconnect',
        () async {
      await adapter.preloadMrec('mrec_k');
      expect(bridge.preloadCalls, 1);

      adapter.mrec('mrec_k').markError();
      adapter.mrecSlot('mrec_k').markFailed();
      expect(adapter.mrec('mrec_k').needsRecovery, isTrue);

      final callsBefore = bridge.preloadCalls;
      adapter.recoverInlineAdsAfterReconnect();
      await settle();

      expect(bridge.preloadCalls, callsBefore + 1,
          reason: 'MREC in error must be re-preloaded on reconnect');
      expect(adapter.mrec('mrec_k').hasError.value, isFalse);
    });

    test('multiple failed keys are all recovered', () async {
      for (final k in ['b1', 'b2', 'b3']) {
        await adapter.preloadBanner(k);
        adapter.banner(k).markError();
        adapter.bannerSlot(k).markFailed();
      }

      final callsBefore = bridge.preloadCalls;
      adapter.recoverInlineAdsAfterReconnect();
      await settle();

      expect(bridge.preloadCalls, callsBefore + 3,
          reason: 'all 3 failed banners must be recovered');
    });
  });

  group('AdManager reconnect wiring for AppLovin (T272)', () {
    test('offline→online connectivity change recovers AppLovin inline ads',
        () async {
      AdManager().debugConnectivityChanged(true);
      await adapter.preloadBanner('reconnect_key');
      adapter.banner('reconnect_key').markError();
      adapter.bannerSlot('reconnect_key').markFailed();
      expect(adapter.banner('reconnect_key').needsRecovery, isTrue);

      final callsBefore = bridge.preloadCalls;
      AdManager().debugConnectivityChanged(false);
      AdManager().debugConnectivityChanged(true);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(bridge.preloadCalls, greaterThan(callsBefore),
          reason: 'AdManager reconnect must reach AppLovin inline ads');
    });
  });
}
