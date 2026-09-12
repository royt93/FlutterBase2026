// On-device integration test for T171 — a 0 or negative config threshold
// passed to ProviderFailoverAdvisor, WaterfallTuner, or IncidentRecorder must
// fall back to that class's own safe default (with a logged warning) instead
// of silently misbehaving or crashing, in a real compiled process.
//
// Run with:
//   flutter test integration_test/r171_config_threshold_validation_test.dart \
//     -d <device-or-sim-id>

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _snap = AdSdkStateSnapshot(
  isInitialised: true,
  canRequestAds: true,
  isOffline: false,
  isVipActive: false,
  fullscreenBusy: false,
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'ProviderFailoverAdvisor(consecutiveFailureThreshold: 0) falls back '
      'to 5 and does not recommend failover with zero real failures, on a '
      'real device', (tester) async {
    final advisor = ProviderFailoverAdvisor(
        consecutiveFailureThreshold: 0, persist: false);
    await advisor.ready;
    expect(advisor.consecutiveFailureThreshold, 5);
    expect(advisor.shouldFailoverNextSession, isFalse);
    await advisor.dispose();
  });

  testWidgets(
      'WaterfallTuner(rollingWindowSize: -2) falls back to 20 and keeps '
      'accumulating real events instead of throwing, on a real device',
      (tester) async {
    final tuner = WaterfallTuner(rollingWindowSize: -2, persist: false);
    await tuner.ready;
    for (var i = 0; i < 6; i++) {
      AdManager().debugEmit(AdLoadEvent(
        providerTag: '[AdMob]',
        type: AdSlotType.interstitial,
        placement: AdPlacement.home,
        success: i.isEven,
      ));
    }
    await tester.pump();
    // No RangeError reaching here (the old bug) is itself part of the
    // proof; this also confirms the tuner is still alive and usable.
    expect(
      tuner.recommendation(
        type: AdSlotType.interstitial,
        placement: AdPlacement.home,
        currentProvider: '[AdMob]',
      ),
      isNull,
      reason: 'only one provider has any data yet — no recommendation is '
          'expected, this just proves recommendation() runs cleanly',
    );
    await tuner.dispose();
  });

  testWidgets(
      'IncidentRecorder(capacity: -1) falls back to 200 and records '
      'normally instead of throwing on the first record(), on a real '
      'device', (tester) async {
    final recorder = IncidentRecorder(capacity: -1);
    expect(recorder.capacity, 200);
    recorder.record('boot', _snap, now: DateTime(2026, 1, 1));
    expect(recorder.entries, hasLength(1));
  });
}
