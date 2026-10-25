// On-device regression test for the 3.6.1 fix: a resume that lands while a
// Privacy Options consent write is still in flight must not leave the banner
// gate shut after the grant lands.
//
// Closing the UMP privacy form resumes the app. In 3.6.0 that resume was
// skipped because the consent write was still running, and it left
// `_resumeConsentBlocked` set, so a banner held while consent was declined
// stayed missing until the NEXT background/foreground. 3.6.1 replays the one
// skipped resume when the apply drain ends.
//
// KNOWN LIMITATION: the UMP form is a native dialog that WidgetTester cannot
// tap (see ump_eea_consent_test.dart). So this test does not drive the form.
// It reproduces the two things the form does to the SDK instead:
//   1. a Privacy Options apply that is parked at its consent write
//      (`AdManager.debugConsentWriteBarrier`, same seam as
//      consent_gate_recovery_test.dart), and
//   2. exactly ONE `resumed` lifecycle event while that apply is parked — the
//      resume the closing form produces. No paused/resumed cycle follows.
// The platform half (a real EEA form closing) was measured by hand on a
// Pixel 7 Pro: 3.6.0 loaded the banner 0 of 5 times, 3.6.1 5 of 5.
//
// Unit coverage of the same contract:
//   test/consent_gate_banner_widget_test.dart
//
// Run with:
//   flutter test integration_test/consent_resume_mid_apply_banner_test.dart -d <device-id>

import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

AdConfig _admobConfig() => const AdConfig(
      provider: AdProvider.admob,
      admob: AdMobConfig(
        bannerId: 'ca-app-pub-3940256099942544/6300978111',
        interstitialId: 'ca-app-pub-3940256099942544/1033173712',
        appOpenId: 'ca-app-pub-3940256099942544/9257395921',
        rewardedId: 'ca-app-pub-3940256099942544/5224354917',
      ),
      safety: AdSafetyParams(dryRun: true),
    );

int _readyBanners(WidgetTester tester) {
  final adapter = AdManager().adapter;
  if (adapter == null) return 0;
  return tester
      .stateList(find.byType(BannerAdWidget))
      .where((k) => adapter.bannerSlot(k).isReady)
      .length;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    AdManager.debugConsentWriteBarrier = null;
    AdManager().debugCanRequestAds = true;
    await AdManager().destroy();
  });

  testWidgets(
      'a resume that lands mid-apply does not keep the banner gate shut after '
      'the grant lands', (tester) async {
    await AdManager().initialize(config: _admobConfig(), onComplete: (_, _) {});
    await AdManager().requestUmpConsent();
    // A VIP loads no ads at all — by design — and this fleet's devices carry
    // VIP entries from the other suites.
    await AdManager().vip!.revokeAll();
    await tester.pump(const Duration(milliseconds: 500));

    // Consent is declined: the gate is shut and the banner is held.
    AdManager().debugCanRequestAds = false;
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [adRouteObserver],
        home: const Scaffold(body: Center(child: BannerAdWidget())),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(AdManager().canRequestAds, isFalse, reason: 'sanity: gate shut');
    expect(_readyBanners(tester), 0,
        reason: 'sanity: a shut gate means no banner is loaded');

    // The user grants: the apply parks just before its consent write.
    final stuckWrite = Completer<void>();
    AdManager.debugConsentWriteBarrier = stuckWrite.future;
    final grant = AdManager().showPrivacyOptions();
    await tester.pump(const Duration(milliseconds: 200));

    // Closing the form resumes the app while the write is still parked. Give
    // the resume's own consent re-check time to settle before the write lands,
    // so it reaches the in-flight early return.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }

    stuckWrite.complete();
    await grant;

    // No paused/resumed cycle from here on: the SDK must recover on its own.
    var loaded = false;
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (_readyBanners(tester) > 0) {
        loaded = true;
        break;
      }
    }

    expect(AdManager().canRequestAds, isTrue,
        reason: 'the grant landed; the skipped resume must not keep the gate '
            'shut until some later resume');
    expect(loaded, isTrue,
        reason: 'a consenting user must get the banner without a second '
            'background/foreground cycle');
    expect(tester.takeException(), isNull);
  });
}
