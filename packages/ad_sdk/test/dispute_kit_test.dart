// T144 — combined dispute kit export: bundles the 3 already-existing signed
// exports (compliance report, bypass audit trail, incident bundle) into one
// artifact a host can hand a partner/reviewer in one shot during an appeal,
// instead of calling 3 separate methods and gluing the JSON together itself.
import 'dart:convert';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AdManager().incidentRecorder.clear();
    AdManager().bypassAuditTrail.clear();
  });

  tearDown(() {
    AdManager().debugConfig = null;
  });

  group('AdManager().exportSignedIncidentBundle()', () {
    test('signs the current incidentRecorder buffer, verifiable', () async {
      AdManager().incidentRecorder.record(
            'consentChanged',
            const AdSdkStateSnapshot(
              isInitialised: true,
              canRequestAds: true,
              isOffline: false,
              isVipActive: false,
              fullscreenBusy: false,
            ),
          );

      final signed = await AdManager().exportSignedIncidentBundle();
      final json = signed.toJsonString();

      expect(await verifySignedJsonPayload(json), isTrue);
      final replayed = replayIncidentBundleJson(signed.payloadJson);
      expect(replayed, hasLength(1));
      expect(replayed.single.label, 'consentChanged');
    });

    test('safe to call before initialize() — empty config fingerprint, '
        'still signs and verifies', () async {
      AdManager().debugConfig = null;

      final signed = await AdManager().exportSignedIncidentBundle();

      expect(await verifySignedJsonPayload(signed.toJsonString()), isTrue);
    });
  });

  group('AdManager().exportDisputeKit()', () {
    test('bundles all 3 signed exports, each independently verifiable',
        () async {
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
        await verifySignedComplianceReportJson(
            jsonEncode(kit.compliance.toJson())),
        isTrue,
      );
      expect(
        await verifySignedJsonPayload(
            jsonEncode(kit.bypassAuditTrail.toJson())),
        isTrue,
      );
      expect(
        await verifySignedJsonPayload(
            jsonEncode(kit.incidentBundle.toJson())),
        isTrue,
      );
    });

    test('toJsonString() round-trips through toJson() with all 3 keys '
        'present', () async {
      final kit = await AdManager().exportDisputeKit();
      final decoded =
          jsonDecode(kit.toJsonString()) as Map<String, dynamic>;

      expect(decoded.keys,
          containsAll(['compliance', 'bypassAuditTrail', 'incidentBundle']));
    });

    test('from/to is forwarded to the underlying compliance report',
        () async {
      final from = DateTime(2026, 1, 1);
      final to = DateTime(2026, 1, 2);

      final kit = await AdManager().exportDisputeKit(from: from, to: to);
      final report = jsonDecode(kit.compliance.reportJson) as Map<String, dynamic>;

      expect(report['rangeFrom'], from.toIso8601String());
      expect(report['rangeTo'], to.toIso8601String());
    });
  });
}
