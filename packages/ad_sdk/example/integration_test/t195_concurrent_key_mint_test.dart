// T195 on-device integration test — two concurrent signComplianceReport()
// calls against the REAL flutter_secure_storage platform channel (iOS
// Keychain / Android Keystore) on first use must converge on the SAME
// Ed25519 public key, not two different ones. The pure-Dart unit tests in
// test/compliance_signing_test.dart use a fake, near-instant in-memory
// storage — this proves the fix also holds against the real platform
// channel's actual timing.
//
// Run with:
//   flutter test integration_test/t195_concurrent_key_mint_test.dart -d <device-or-sim-id>

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _snapshot = AdSafetySnapshot(
  fullscreenAdsShownInSession: 0,
  maxFullscreenAdsPerSession: 6,
  hourlyAdCount: 0,
  maxFullscreenAdsPerHour: 3,
  dailyAdCount: 0,
  maxFullscreenAdsPerDay: 5,
  clickThroughRate: 0,
  fullscreenClickThroughRate: 0,
  suspiciousCtrThreshold: 0.3,
  clicksLastMinute: 0,
  suspiciousViolationCount: 0,
  isSuspended: false,
  dryRun: false,
);

ComplianceReport _report({int eventCount = 1}) => ComplianceReport.generate(
      events: List.generate(
          eventCount, (i) => {'kind': 'ad_event', 'timestampMs': i}),
      safety: _snapshot,
      consent: ConsentSettings.accepted,
      vipActive: false,
    );

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const storage = FlutterSecureStorage();

  setUp(() async {
    // Real device keychain/keystore — start each run from a genuinely
    // empty slot so this always exercises the first-use mint race, not
    // a key left over from a previous run.
    await storage.delete(key: 'ad_sdk_compliance_signing_key_v1');
  });

  testWidgets(
      'two concurrent signComplianceReport calls against the real secure '
      'storage converge on the same public key', (tester) async {
    final results = await Future.wait([
      signComplianceReport(_report(), secureStorage: storage),
      signComplianceReport(_report(eventCount: 2), secureStorage: storage),
    ]);

    expect(results[1].publicKeyBase64, results[0].publicKeyBase64,
        reason: 'a real-device race on first use must not mint two '
            'different keys against the real platform secure storage');
    expect(await verifySignedComplianceReportJson(results[0].toJsonString()),
        isTrue);
    expect(await verifySignedComplianceReportJson(results[1].toJsonString()),
        isTrue);

    // A later, non-concurrent call must reuse the SAME persisted key too.
    final later = await signComplianceReport(_report(), secureStorage: storage);
    expect(later.publicKeyBase64, results[0].publicKeyBase64);
  });
}
