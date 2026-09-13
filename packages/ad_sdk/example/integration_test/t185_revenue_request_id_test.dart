// T185 on-device integration test — a real showInterstitial() call, on a
// real device with a real AdMob interstitial actually loaded and shown,
// proves the requestId stamped on the slot at load time reaches the real
// AdRevenueEvent from AdMob's real native onPaidEvent callback (AdMob's
// test ad units fire this for real on display, same as production) — end
// to end through real initialize(), not just the debugConfig-seeded unit
// tests in test/admob_behavioral_test.dart and
// test/t185_revenue_request_id_test.dart.
//
// Deliberately does NOT dismiss the ad (AdShowEvent only fires on
// dismiss, which needs a real tap through the native ad UI this harness
// doesn't drive) — the paid-event callback fires on DISPLAY, before
// dismiss, so `interstitialSlot.requestId` read right after `show()`
// still reflects the exact id the SAME load stamped (no reload can have
// happened yet — the slot refuses a new load while showing).
//
// Run with:
//   flutter test integration_test/t185_revenue_request_id_test.dart -d <device-or-sim-id>

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

AdConfig _config() => const AdConfig(
      provider: AdProvider.admob,
      admob: AdMobConfig(
        bannerId: 'ca-app-pub-3940256099942544/6300978111',
        interstitialId: 'ca-app-pub-3940256099942544/1033173712',
        appOpenId: 'ca-app-pub-3940256099942544/9257395921',
        rewardedId: 'ca-app-pub-3940256099942544/5224354917',
      ),
      safety: AdSafetyParams(dryRun: true),
      firstInstallVipGrace: FirstInstallVipGrace.disabled,
    );

Future<void> _waitForInterstitialReady(WidgetTester tester) async {
  for (var i = 0; i < 60; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (AdManager().adapter?.interstitialSlot.isReady ?? false) return;
  }
  fail('interstitial never became ready on this real device');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    await AdManager().destroy();
  });

  testWidgets(
      'a real interstitial\'s AdRevenueEvent carries the SAME requestId '
      'that was stamped on the slot at load time, on a real device with '
      'a real loaded+shown AdMob test ad', (tester) async {
    await AdManager().initialize(config: _config(), onComplete: (_, __) {});
    await _waitForInterstitialReady(tester);
    expect(AdManager().isInitialised, isTrue);

    final loadedRequestId = AdManager().adapter!.interstitialSlot.requestId;
    expect(loadedRequestId, isNotNull,
        reason: 'a real load on a real device must stamp a requestId');

    final events = <AdEvent>[];
    final sub = AdManager().events.listen(events.add);
    addTearDown(sub.cancel);

    await AdManager().showInterstitial(onDoneFlow: (_) {});
    // A real AdMob test ad fires onPaidEvent on display — give the native
    // side a real window to report it before asserting. Not dismissed —
    // see the file-level comment for why that's unnecessary here.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (events.whereType<AdRevenueEvent>().isNotEmpty) break;
    }

    final revenue = events.whereType<AdRevenueEvent>().single;
    expect(revenue.requestId, loadedRequestId,
        reason: 'the real AdMob paid-event callback must carry the SAME '
            'id this load stamped — this is the whole point of T185');
  });
}
