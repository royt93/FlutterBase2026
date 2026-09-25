// T144 on-device integration test — AdManager().exportDisputeKit() bundles
// all 3 already-existing signed exports through a real AdManager() session
// and real Ed25519 signing (package:cryptography, no mocked plugin), on a
// real device.
//
// Run with:
//   flutter test integration_test/t144_dispute_kit_test.dart -d <device-or-sim-id>

import 'dart:convert';

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
    );

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    await AdManager().destroy();
  });

  testWidgets(
      'exportDisputeKit() bundles all 3 real signed exports, each '
      'independently verifiable, on a real device', (tester) async {
    await AdManager().initialize(config: _config(), onComplete: (_, _) {});
    await tester.pump(const Duration(milliseconds: 300));
    expect(AdManager().isInitialised, isTrue);

    AdManager().bypassAuditTrail.record(
          kind: 'bypassSafety',
          callSiteTag: 'splash_app_open',
          type: AdSlotType.appOpen,
        );
    AdManager().incidentRecorder.record(
          'adapterInitialized',
          const AdSdkStateSnapshot(
            isInitialised: true,
            canRequestAds: true,
            isOffline: false,
            isVipActive: false,
            fullscreenBusy: false,
          ),
        );

    final kit = await AdManager().exportDisputeKit();

    expect(
      await verifySignedComplianceReportJson(jsonEncode(kit.compliance.toJson())),
      isTrue,
      reason: 'the compliance part must verify against the real, '
          'on-device-minted Ed25519 signing key',
    );
    expect(
      await verifySignedJsonPayload(jsonEncode(kit.bypassAuditTrail.toJson())),
      isTrue,
    );
    expect(
      await verifySignedJsonPayload(jsonEncode(kit.incidentBundle.toJson())),
      isTrue,
    );

    final decoded = jsonDecode(kit.toJsonString()) as Map<String, dynamic>;
    expect(decoded.keys,
        containsAll(['compliance', 'bypassAuditTrail', 'incidentBundle']));
  });
}
