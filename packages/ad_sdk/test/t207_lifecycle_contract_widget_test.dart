// Audit fix (post-T207) — the old test pumped an unrelated `Text` widget
// around a destroy() call; it never mounted anything AdManager-integrated at
// all, so it couldn't have caught a real widget-lifecycle regression. This
// mounts a real BannerAdWidget (the one host widget every consuming app
// actually uses) and drives the exact contract this task cares about:
// destroy() while a live, ad-bearing widget is mounted, then unmount.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _config = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'test',
    interstitialId: 'test',
    rewardedId: 'test',
    appOpenId: 'test',
  ),
  safety: AdSafetyParams(dryRun: true, minSessionDurationBeforeAd: 0),
);

void main() {
  testWidgets(
      'a real BannerAdWidget survives AdManager.destroy() while mounted, '
      'and unmounts cleanly afterward', (tester) async {
    final adapter = FakeAdProviderAdapter();
    final manager = AdManager();
    manager.debugResetGuardState();
    manager.debugSetAdapter(adapter);
    manager.debugConfig = _config;
    manager.debugCanRequestAds = true;

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: BannerAdWidget()),
    ));
    await tester.pumpAndSettle();
    expect(adapter.bannerSlots.length, 1,
        reason: 'sanity: the banner actually mounted a real slot');

    // The contract this task exists to prove: a live, ad-bearing widget must
    // not throw when the SDK it depends on is torn down underneath it —
    // the "destroy while a widget is up" case the app-lifecycle background/
    // process-death path can genuinely hit.
    await manager.destroy();
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull,
        reason: 'unmounting after the manager it depended on was torn down '
            'must not throw either (dispose() must not assume a live SDK)');

    manager.debugSetAdapter(null);
    manager.debugResetGuardState();
  });
}
