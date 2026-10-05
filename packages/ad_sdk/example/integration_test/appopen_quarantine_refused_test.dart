// Audit round 74 — on-device check of the AppLovin App Open quarantine as the
// HOST sees it, through the real AdManager on a real device.
//
// A lost native `onAdHidden` cannot be reproduced with a real MAX ad, so this
// drives the real `AppLovinAdapter` with a recording bridge (no SDK key, no
// network ad) and real wall-clock time: the watchdog abandons a show after its
// ~10s foreground grace, which arms the 35s quarantine; the next
// `showAppOpenAd` must resolve `false`, never reach the native bridge, and
// charge no impression. It proves the refused path on-device, NOT AppLovin's
// real late-callback timing.
//
// Run with:
//   flutter test integration_test/appopen_quarantine_refused_test.dart -d <id>

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/adapters/applovin_adapter.dart';
import 'package:applovin_admob_sdk/src/adapters/applovin_bridge.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

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

const _config = AdConfig(
  provider: AdProvider.appLovin,
  appLovin: AppLovinConfig(
    sdkKey: 'sdk',
    bannerId: 'banner-id',
    interstitialId: 'inter-id',
    appOpenId: 'appopen-id',
    rewardedId: 'rewarded-id',
  ),
  safety: AdSafetyParams(dryRun: true),
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'quarantined App Open resolves false, skips native, charges nothing',
      (tester) async {
    // Real platform on purpose: Android's watchdog abandons after ~10s of
    // foreground, iOS only at the ~90s hard cap. Wait for the actual resolve.
    try {
      final bridge = _RecordingBridge();
      final adapter = AppLovinAdapter(
        bridge: bridge,
        lifecycleStateResolver: () => AppLifecycleState.resumed,
      );
      await adapter.initialize(_config);

      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _config;
      AdManager().debugCanRequestAds = true;
      AdManager().markSplashInactive();

      // Real watchdog: foreground + no hidden callback => abandoned after two
      // 5s ticks, which arms the quarantine.
      var abandoned = false;
      adapter.debugStartAppOpenWatchdog((_) => abandoned = true);
      final wait = Stopwatch()..start();
      while (!abandoned && wait.elapsed < const Duration(seconds: 120)) {
        await tester.pump(const Duration(seconds: 1));
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      expect(abandoned, isTrue,
          reason: 'the real watchdog must resolve the lost callback');
      adapter.appOpenSlot.markReady();

      final sessionBefore = AdSafetyConfig.getSessionAdCount();
      final events = <AdEvent>[];
      final sub = AdManager().events.listen(events.add);

      bool? dismissed;
      await AdManager().showAppOpenAd(
        bypassSafety: true,
        onAdDismiss: (d) => dismissed = d,
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(dismissed, isFalse, reason: 'the splash caller must not hang');
      expect(bridge.shows, isEmpty,
          reason: 'a quarantined show never reaches the native SDK');
      expect(AdSafetyConfig.getSessionAdCount(), sessionBefore,
          reason: 'a refused show is not an impression');
      expect(events.whereType<AdShowEvent>().where((e) => e.success), isEmpty);
      await sub.cancel();
    } finally {
      AdManager().debugSetAdapter(null);
      AdManager().markSplashActive();
    }
  });
}
