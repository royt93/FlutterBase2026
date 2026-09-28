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
}
