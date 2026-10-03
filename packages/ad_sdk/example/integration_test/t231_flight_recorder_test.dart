// T231 on-device integration test — Flight Recorder end-to-end through a
// REAL AdManager() session, a REAL mounted BannerAdWidget (real
// RenderBox.localToGlobal pixel coordinates from actual on-device layout,
// real VisibilityDetector callback timing), and real Ed25519 signing
// (package:cryptography, no mocked plugin).
//
// Proves what a unit/widget test cannot: that the pixel-position capture
// works against the device's real render tree/pixel density, and that a
// real VisibilityDetector visibility transition actually fires the
// recorder on-device (not just via a synthetic VisibilityInfo in a widget
// test's fake clock).
//
// Run with:
//   flutter test integration_test/t231_flight_recorder_test.dart -d <device-or-sim-id>

import 'dart:convert';
import 'dart:io';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

AdConfig _config() => const AdConfig(
      provider: AdProvider.admob,
      admob: AdMobConfig(
        bannerId: 'ca-app-pub-3940256099942544/6300978111',
        interstitialId: 'ca-app-pub-3940256099942544/1033173712',
        appOpenId: 'ca-app-pub-3940256099942544/9257395921',
        rewardedId: 'ca-app-pub-3940256099942544/5224354917',
        nativeId: 'ca-app-pub-3940256099942544/2247696110',
      ),
      safety: AdSafetyParams(dryRun: true),
    );

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    AdManager().disableFlightRecorder();
    await AdManager().destroy();
  });

  testWidgets(
      'enabling the recorder + mounting a real banner records a real '
      'pixel-bound entry, and the signed export verifies on-device',
      (tester) async {
    AdManager().enableFlightRecorder(AdFlightRecorder());
    await AdManager().initialize(config: _config(), onComplete: (_, _) {});
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 300));
      if (AdManager().isInitialised) break;
    }
    expect(AdManager().isInitialised, isTrue);

    await tester.pumpWidget(const MaterialApp(
      navigatorObservers: [],
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: BannerAdWidget(collapseAnimationDuration: Duration.zero),
        ),
      ),
    ));
    // Real VisibilityDetector fires on its own composition schedule — give
    // it a bounded number of real frames rather than pumpAndSettle (a
    // banner's auto-refresh timer would hang that).
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    final recorder = AdManager().flightRecorder!;
    expect(recorder.entries, isNotEmpty,
        reason: 'a real on-device VisibilityDetector callback must have '
            'fired at least the initial "became visible" transition');
    final visible =
        recorder.entries.firstWhere((e) => e.label == 'bannerVisible');
    expect(visible.viewabilityFraction, greaterThan(0));
    // Real device layout — these are actual global pixel coordinates from
    // RenderBox.localToGlobal, not synthetic test values.
    expect(visible.widthPx, greaterThan(0));
    expect(await verifyFlightRecorderChain(recorder.entries), isTrue);

    // Unmount → drives a real dispose path; must not crash and must not
    // write a late entry.
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);

    final signed = await AdManager().exportSignedFlightRecorderBundle();
    expect(signed, isNotNull);
    expect(await verifySignedFlightRecorderBundle(signed!.toJsonString()),
        isTrue,
        reason: 'real on-device Ed25519 signing key must produce a '
            'signature that verifies, and the recorded chain must be intact');

    final kit = await AdManager().exportDisputeKit();
    expect(kit.flightRecorderBundle, isNotNull);
    final decoded = jsonDecode(kit.toJsonString()) as Map<String, dynamic>;
    expect(decoded.containsKey('flightRecorderBundle'), isTrue);
  });

  testWidgets(
      'T236: App Open records one valid fullscreen show/dismiss pair',
      (tester) async {
    final adapter = FakeAdProviderAdapter();
    AdManager().debugSetAdapter(adapter);
    AdManager().debugCanRequestAds = true;
    AdManager().enableFlightRecorder(AdFlightRecorder());
    await adapter.loadAppOpen();

    bool? dismissed;
    await AdManager().showAppOpenAd(
      bypassSafety: true,
      onAdDismiss: (value) => dismissed = value,
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(dismissed, isTrue);
    final entries = AdManager().flightRecorder!.entries;
    expect(entries.where((e) => e.label == 'fullscreenVisible'), hasLength(1));
    expect(entries.where((e) => e.label == 'fullscreenDismissed'), hasLength(1));
    expect(await verifyFlightRecorderChain(entries), isTrue);
  });

  testWidgets('T236: mounted NativeAdWidget records real device pixel bounds',
      (tester) async {
    final adapter = FakeAdProviderAdapter();
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _config();
    AdManager().debugCanRequestAds = true;
    AdManager().enableFlightRecorder(AdFlightRecorder());
    expect(AdManager().isInitialised, isTrue);

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: NativeAdWidget(placement: AdPlacement.home)),
    ));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final entries = AdManager().flightRecorder!.entries;
    final visible = entries.singleWhere(
      (e) => e.label == 'nativeVisible' && e.placement == 'home',
      orElse: () => throw StateError(
          'no nativeVisible entry; recorded labels: '
          '${entries.map((e) => e.label).toList()}'),
    );
    expect(visible.widthPx, greaterThan(0));
    expect(visible.heightPx, greaterThan(0));
    expect(await verifyFlightRecorderChain(entries), isTrue);
  });

  testWidgets('T238: export a real on-device .adproof for standalone CLI',
      (tester) async {
    final adapter = FakeAdProviderAdapter();
    AdManager().debugSetAdapter(adapter);
    AdManager().debugCanRequestAds = true;
    AdManager().enableFlightRecorder(AdFlightRecorder());
    await adapter.loadAppOpen();

    await AdManager().showAppOpenAd(
      bypassSafety: true,
      onAdDismiss: (_) {},
    );
    final signed = await AdManager().exportSignedFlightRecorderBundle();
    expect(signed, isNotNull);
    expect(await verifySignedFlightRecorderBundle(signed!.toJsonString()),
        isTrue);

    final output = File('${Directory.systemTemp.path}/t238_device.adproof');
    await output.writeAsString(signed.toJsonString());
    expect(await output.exists(), isTrue);
    // ignore: avoid_print
    print('T238_ADPROOF_PATH=${output.path}');
    // Test runner uninstalls the base APK immediately after completion, which
    // removes its private cache before a host-side `adb run-as ... cat` can
    // pull this artifact. Opt-in hold exists only for the manual T238 CLI
    // verification workflow; normal CI/device runs pay no delay.
    if (const bool.fromEnvironment('T238_HOLD_EXPORT')) {
      await Future<void>.delayed(const Duration(seconds: 30));
    }
  });
}
