// T121 regression: AdConfig.safetyRampSchedule lets a host ramp
// AdSafetyParams by device age (D0/D3/D7/D30...) fully locally, no
// remote-config/network needed. initialize() picks the schedule entry
// whose key is the largest Duration still <= elapsed-since-first-install,
// applied BEFORE any remoteSafetyProvider override so remote always wins on
// a field both touch.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Same mock as ad_manager_core_test.dart's setUpAll — MobileAds._instance
// fires an un-awaited channel.invokeMethod('_init') the first time anything
// touches MobileAds.instance; without a handler that's an uncaught async
// MissingPluginException.
const _gmaChannel = MethodChannel('plugins.flutter.io/google_mobile_ads');
const _appLovinMaxChannel =
    MethodChannel('com.applovin.applovin_max/applovin_max');

const _kFirstInstallKey = 'ad_sdk_first_install_at_ms';

AdConfig _config({Map<Duration, AdSafetyParams>? ramp}) => AdConfig(
      provider: AdProvider.admob,
      admob: const AdMobConfig(
        bannerId: 'ca-app-pub-3940256099942544/6300978111',
        interstitialId: 'ca-app-pub-3940256099942544/1033173712',
        appOpenId: 'ca-app-pub-3940256099942544/9257395921',
        rewardedId: 'ca-app-pub-3940256099942544/5224354917',
      ),
      safety: const AdSafetyParams(dryRun: true, maxFullscreenAdsPerDay: 5),
      autoRequestUmpConsent: false,
      safetyRampSchedule: ramp,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_gmaChannel, (call) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_appLovinMaxChannel, (call) async => null);
  });
  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_gmaChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_appLovinMaxChannel, null);
  });

  tearDown(() async {
    await AdManager().destroy();
  });

  test('no schedule set — behaviour unchanged (uses config.safety as-is)',
      () async {
    AdPreferences.resetForTest();
    SharedPreferences.setMockInitialValues({});
    await AdManager()
        .initialize(config: _config(), onComplete: (_, _) {});
    AdSafetyConfig.recordFullscreenAdShown();
    // config.safety's maxFullscreenAdsPerDay is 5 — 1 show must not cap.
    expect(AdSafetyConfig.dailyCapReached(), isFalse);
  });

  test('device age past the D3 stage picks the D3 params, not D0',
      () async {
    final threeDaysAgo = DateTime.now()
        .subtract(const Duration(days: 4))
        .millisecondsSinceEpoch;
    AdPreferences.resetForTest();
    SharedPreferences.setMockInitialValues({_kFirstInstallKey: threeDaysAgo});

    await AdManager().initialize(
      config: _config(ramp: {
        Duration.zero: const AdSafetyParams(maxFullscreenAdsPerDay: 1),
        const Duration(days: 3): const AdSafetyParams(maxFullscreenAdsPerDay: 999),
      }),
      onComplete: (_, _) {},
    );

    // _config()'s own base `safety` already allows 5/day — show 6 to exceed
    // THAT, so this only reads isFalse if the ramp's 999/day stage was
    // actually picked. (Showing just 1 wouldn't distinguish "ramp applied"
    // from "ramp silently ignored, base config.safety's 5/day still open".)
    for (var i = 0; i < 6; i++) {
      AdSafetyConfig.recordFullscreenAdShown();
    }
    expect(AdSafetyConfig.dailyCapReached(), isFalse,
        reason: 'device is 4 days old (past the 3-day stage) — the 999/day '
            'D3 params must be picked, not the 1/day D0 params or the base '
            'config.safety (5/day, already exceeded by the 6 shows above)');
  });

  test('a brand-new device (no persisted first-install stamp) gets the D0 '
      'stage', () async {
    AdPreferences.resetForTest();
    SharedPreferences.setMockInitialValues({}); // no first-install key yet

    await AdManager().initialize(
      config: _config(ramp: {
        Duration.zero: const AdSafetyParams(maxFullscreenAdsPerDay: 1),
        const Duration(days: 3): const AdSafetyParams(maxFullscreenAdsPerDay: 999),
      }),
      onComplete: (_, _) {},
    );

    AdSafetyConfig.recordFullscreenAdShown();
    expect(AdSafetyConfig.dailyCapReached(), isTrue,
        reason: 'no persisted stamp means elapsed=0 (this IS the first '
            'launch) — the D0 (1/day) stage must be picked');
  });
}
