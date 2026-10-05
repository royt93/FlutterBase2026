// Audit round 74 — host-visible behaviour when AppLovinAdapter refuses an
// App Open because a prior cycle's show was never confirmed (35s quarantine).
//
// Adapter-level coverage lives in applovin_adapter_test.dart; this file covers
// the host contract: callback resolves false, no impression is charged,
// and nothing hangs. Window expiry is covered at adapter level (the 34s/35s
// boundary test); the manager path awaits a connectivity read that FakeAsync
// cannot drive, so it is not repeated here.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/adapters/applovin_adapter.dart';
import 'package:applovin_admob_sdk/src/adapters/applovin_bridge.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RecordingBridge implements AppLovinBridge {
  final shows = <String>[];

  @override
  Future<void> initialize(String sdkKey) async {}
  @override
  void showAppOpenAd(String adUnitId) => shows.add(adUnitId);
  @override
  void loadAppOpenAd(String adUnitId) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeVip implements VipManager {
  @override
  bool get isActive => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _config = AdConfig(
  provider: AdProvider.appLovin,
  appLovin: AppLovinConfig(
    sdkKey: 'sdk',
    bannerId: 'banner-id',
    interstitialId: 'inter-id',
    appOpenId: 'appopen-id',
    rewardedId: 'rewarded-id',
  ),
);

/// Real adapter, quarantined through the real watchdog path: a show whose
/// native `onAdHidden` never arrives, resolved by the Android grace tick.
AppLovinAdapter _quarantined(_RecordingBridge bridge, FakeAsync async) {
  final a = AppLovinAdapter(
    bridge: bridge,
    lifecycleStateResolver: () => AppLifecycleState.resumed,
  );
  a.initialize(_config);
  async.flushMicrotasks();
  a.debugStartAppOpenWatchdog((_) {});
  async.elapse(const Duration(seconds: 10));
  a.appOpenSlot.markReady(); // slot looks reusable; only quarantine refuses
  return a;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await AdManager().destroy();
    SharedPreferences.setMockInitialValues({});
    final prefs = await AdPreferences.getInstance();
    await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
    AdSafetyConfig.resetForReinit();
    AdManager().debugVipManager = _FakeVip();
    AdManager().debugCanRequestAds = true;
    AdManager().markSplashInactive();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    AdManager().debugSetAdapter(null);
    AdManager().debugVipManager = null;
    AdManager().markSplashActive();
    await AdManager().destroy();
  });

  test('quarantine refusal reaches the host as false with no impression', () {
    fakeAsync((async) {
      final bridge = _RecordingBridge();
      final adapter = _quarantined(bridge, async);
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _config;
      final sessionBefore = AdSafetyConfig.getSessionAdCount();
      final events = <AdEvent>[];
      final sub = AdManager().events.listen(events.add);

      bool? dismissed;
      var completed = false;
      AdManager()
          .showAppOpenAd(
              bypassSafety: true, onAdDismiss: (d) => dismissed = d)
          .then((_) => completed = true);
      async.flushMicrotasks();

      expect(completed, isTrue, reason: 'the splash caller must not hang');
      expect(dismissed, isFalse);
      expect(bridge.shows, isEmpty,
          reason: 'a quarantined show never reaches the native SDK');
      expect(AdSafetyConfig.getSessionAdCount(), sessionBefore,
          reason: 'a refused show is not an impression');
      final showEvents = events.whereType<AdShowEvent>().toList();
      expect(showEvents, hasLength(1),
          reason: 'the refusal must still be observable telemetry');
      expect(showEvents.single.success, isFalse);
      sub.cancel();
    });
  });
}
