import 'dart:convert';
import 'dart:io';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemorySecureStorage extends FlutterSecureStorage {
  final Map<String, String> values = {};

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => values[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  final root = Directory.current.path;
  late String complianceJson;
  late String incidentJson;
  late String bypassJson;

  Future<ProcessResult> runTool(String script, List<String> args) =>
      Process.run('dart', [
        'run',
        '$root/tool/$script',
        ...args,
      ], workingDirectory: root);

  Future<String> writeFixture(String name, String body) async {
    final file = File('${tempDir.path}/$name');
    await file.writeAsString(body);
    return file.path;
  }

  Future<String> signedPayloadEnvelope(String payload) async =>
      (await signJsonPayload(
        payload,
        secureStorage: _MemorySecureStorage(),
      )).toJsonString();

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('signed_export_cli_');
  });

  setUpAll(() async {
    final storage = _MemorySecureStorage();
    const safety = AdSafetySnapshot(
      fullscreenAdsShownInSession: 1,
      maxFullscreenAdsPerSession: 6,
      hourlyAdCount: 1,
      maxFullscreenAdsPerHour: 3,
      dailyAdCount: 1,
      maxFullscreenAdsPerDay: 10,
      clickThroughRate: 0,
      fullscreenClickThroughRate: 0,
      suspiciousCtrThreshold: 0.3,
      clicksLastMinute: 0,
      suspiciousViolationCount: 0,
      isSuspended: false,
      dryRun: false,
    );
    final report = ComplianceReport.generate(
      events: const [
        {'kind': 'ad_event', 'timestampMs': 1},
      ],
      safety: safety,
      consent: ConsentSettings.accepted,
      vipActive: false,
      now: DateTime.utc(2026, 1, 1),
    );
    complianceJson = (await signComplianceReport(
      report,
      secureStorage: storage,
    )).toJsonString();

    const config = AdConfig(
      provider: AdProvider.admob,
      admob: AdMobConfig(
        bannerId: 'banner',
        interstitialId: 'interstitial',
        appOpenId: 'app-open',
        rewardedId: 'rewarded',
      ),
    );
    final recorder = IncidentRecorder();
    recorder.record(
      'boot',
      const AdSdkStateSnapshot(
        isInitialised: false,
        canRequestAds: false,
        isOffline: false,
        isVipActive: false,
        fullscreenBusy: false,
      ),
      now: DateTime.utc(2026, 1, 1),
    );
    incidentJson = (await signJsonPayload(
      IncidentBundle.capture(
        recorder,
        config,
        now: DateTime.utc(2026, 1, 1),
      ).toJsonString(),
      secureStorage: storage,
    )).toJsonString();

    final trail = BypassAuditTrail();
    trail.record(
      kind: 'bypassSafety',
      callSiteTag: 'test_splash',
      type: AdSlotType.appOpen,
    );
    bypassJson = (await signJsonPayload(
      trail.toPayloadJson(),
      secureStorage: storage,
    )).toJsonString();
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  group('verify_compliance_report CLI', () {
    const script = 'verify_compliance_report.dart';

    test('valid signed report prints VALID and exits 0', () async {
      final path = await writeFixture('report.json', complianceJson);
      final result = await runTool(script, [path]);
      expect(result.exitCode, 0);
      expect(result.stdout.toString().trim(), 'VALID');
      expect(result.stderr.toString(), isEmpty);
    });

    test(
      'tampered signature and malformed JSON print INVALID and exit 1',
      () async {
        final decoded = jsonDecode(complianceJson) as Map<String, dynamic>;
        final signature = base64Url.decode(
          base64Url.normalize(decoded['signatureBase64'] as String),
        );
        signature[0] ^= 1;
        decoded['signatureBase64'] = base64Url.encode(signature);
        final tamperedPath = await writeFixture(
          'tampered-signature.json',
          jsonEncode(decoded),
        );
        final tampered = await runTool(script, [tamperedPath]);
        expect(tampered.exitCode, 1);
        expect(tampered.stdout.toString().trim(), 'INVALID');

        final payloadTampered =
            jsonDecode(complianceJson) as Map<String, dynamic>;
        payloadTampered['reportJson'] =
            (payloadTampered['reportJson'] as String).replaceFirst(
              'ad_event',
              'x',
            );
        final payloadPath = await writeFixture(
          'tampered-report.json',
          jsonEncode(payloadTampered),
        );
        final payloadResult = await runTool(script, [payloadPath]);
        expect(payloadResult.exitCode, 1);
        expect(payloadResult.stdout.toString().trim(), 'INVALID');

        final malformedPath = await writeFixture('malformed.json', '{bad');
        final malformed = await runTool(script, [malformedPath]);
        expect(malformed.exitCode, 1);
        expect(malformed.stdout.toString().trim(), endsWith('INVALID'));
      },
    );

    test('well-formed wrong public key and JSON root print INVALID', () async {
      final wrongKey = jsonDecode(complianceJson) as Map<String, dynamic>;
      wrongKey['publicKeyBase64'] = base64Url.encode(List<int>.filled(31, 0));
      final wrongKeyPath = await writeFixture(
        'wrong-public-key.json',
        jsonEncode(wrongKey),
      );
      final wrongKeyResult = await runTool(script, [wrongKeyPath]);
      expect(wrongKeyResult.exitCode, 1);
      expect(wrongKeyResult.stdout.toString().trim(), 'INVALID');

      final rootPath = await writeFixture('array-root.json', '[]');
      final rootResult = await runTool(script, [rootPath]);
      expect(rootResult.exitCode, 1);
      expect(rootResult.stdout.toString().trim(), 'INVALID');
    });

    test('usage, missing and unreadable path use exit 2', () async {
      final usage = await runTool(script, []);
      expect(usage.exitCode, 2);
      expect(usage.stderr.toString(), contains('usage:'));
      expect(usage.stdout.toString(), isEmpty);

      final missing = await runTool(script, ['${tempDir.path}/missing.json']);
      expect(missing.exitCode, 2);
      expect(missing.stderr.toString(), contains('could not read'));
      expect(missing.stdout.toString(), isEmpty);

      final unreadable = await runTool(script, [tempDir.path]);
      expect(unreadable.exitCode, 2);
      expect(unreadable.stderr.toString(), contains('could not read'));
    });
  });

  group('incident_replay CLI', () {
    const script = 'incident_replay.dart';

    test('valid signed incident prints timeline and exits 0', () async {
      final path = await writeFixture('incident.json', incidentJson);
      final result = await runTool(script, [path]);
      expect(result.exitCode, 0);
      expect(result.stdout.toString(), contains('signature: VALID'));
      expect(result.stdout.toString(), contains('boot'));
      expect(result.stderr.toString(), isEmpty);
    });

    test(
      'invalid signature still prints parsed timeline and exits 1',
      () async {
        final decoded = jsonDecode(incidentJson) as Map<String, dynamic>;
        final signature = base64Url.decode(
          base64Url.normalize(decoded['signatureBase64'] as String),
        );
        signature[0] ^= 1;
        decoded['signatureBase64'] = base64Url.encode(signature);
        final path = await writeFixture(
          'incident-invalid.json',
          jsonEncode(decoded),
        );
        final result = await runTool(script, [path]);
        expect(result.exitCode, 1);
        expect(result.stdout.toString(), contains('signature: INVALID'));
        expect(result.stdout.toString(), contains('boot'));

        final payloadTampered =
            jsonDecode(incidentJson) as Map<String, dynamic>;
        final payload =
            jsonDecode(payloadTampered['payloadJson'] as String)
                as Map<String, dynamic>;
        payload['entries'] = <dynamic>[];
        payloadTampered['payloadJson'] = jsonEncode(payload);
        final payloadPath = await writeFixture(
          'incident-payload-tampered.json',
          jsonEncode(payloadTampered),
        );
        final payloadResult = await runTool(script, [payloadPath]);
        expect(payloadResult.exitCode, 1);
        expect(payloadResult.stdout.toString(), contains('signature: INVALID'));
        expect(payloadResult.stdout.toString(), contains('0 entries:'));
      },
    );

    test(
      'malformed envelope, usage and missing file use documented exits',
      () async {
        final malformedPath = await writeFixture(
          'incident-malformed.json',
          '{bad',
        );
        final malformed = await runTool(script, [malformedPath]);
        expect(malformed.exitCode, 2);
        expect(
          malformed.stderr.toString(),
          contains('not a valid signed bundle'),
        );
        expect(malformed.stdout.toString(), isEmpty);

        final invalidPayloadEnvelope = await signedPayloadEnvelope('{bad');
        final invalidPayloadPath = await writeFixture(
          'incident-invalid-payload.json',
          invalidPayloadEnvelope,
        );
        final invalidPayload = await runTool(script, [invalidPayloadPath]);
        expect(invalidPayload.exitCode, 2);
        expect(invalidPayload.stdout.toString(), contains('signature: VALID'));
        expect(
          invalidPayload.stderr.toString(),
          contains('payloadJson is not a valid incident bundle'),
        );

        final usage = await runTool(script, []);
        expect(usage.exitCode, 2);
        expect(usage.stderr.toString(), contains('usage:'));

        final missing = await runTool(script, ['${tempDir.path}/missing.json']);
        expect(missing.exitCode, 2);
        expect(missing.stderr.toString(), contains('could not read'));
        expect(missing.stdout.toString(), isEmpty);

        final unreadable = await runTool(script, [tempDir.path]);
        expect(unreadable.exitCode, 2);
        expect(unreadable.stderr.toString(), contains('could not read'));
        expect(unreadable.stdout.toString(), isEmpty);
      },
    );
  });

  group('bypass_audit_replay CLI', () {
    const script = 'bypass_audit_replay.dart';

    test('valid signed trail prints entries and exits 0', () async {
      final path = await writeFixture('bypass.json', bypassJson);
      final result = await runTool(script, [path]);
      expect(result.exitCode, 0);
      expect(result.stdout.toString(), contains('signature: VALID'));
      expect(result.stdout.toString(), contains('test_splash'));
      expect(result.stderr.toString(), isEmpty);
    });

    test('invalid signature still prints parsed entries and exits 1', () async {
      final decoded = jsonDecode(bypassJson) as Map<String, dynamic>;
      final signature = base64Url.decode(
        base64Url.normalize(decoded['signatureBase64'] as String),
      );
      signature[0] ^= 1;
      decoded['signatureBase64'] = base64Url.encode(signature);
      final path = await writeFixture(
        'bypass-invalid.json',
        jsonEncode(decoded),
      );
      final result = await runTool(script, [path]);
      expect(result.exitCode, 1);
      expect(result.stdout.toString(), contains('signature: INVALID'));
      expect(result.stdout.toString(), contains('test_splash'));

      final payloadTampered = jsonDecode(bypassJson) as Map<String, dynamic>;
      final payload =
          jsonDecode(payloadTampered['payloadJson'] as String)
              as Map<String, dynamic>;
      payload['entries'] = <dynamic>[];
      payloadTampered['payloadJson'] = jsonEncode(payload);
      final payloadPath = await writeFixture(
        'bypass-payload-tampered.json',
        jsonEncode(payloadTampered),
      );
      final payloadResult = await runTool(script, [payloadPath]);
      expect(payloadResult.exitCode, 1);
      expect(payloadResult.stdout.toString(), contains('signature: INVALID'));
      expect(payloadResult.stdout.toString(), contains('0 entries:'));
    });

    test(
      'malformed envelope, usage and missing file use documented exits',
      () async {
        final malformedPath = await writeFixture(
          'bypass-malformed.json',
          '{bad',
        );
        final malformed = await runTool(script, [malformedPath]);
        expect(malformed.exitCode, 2);
        expect(
          malformed.stderr.toString(),
          contains('not a valid signed bundle'),
        );
        expect(malformed.stdout.toString(), isEmpty);

        final invalidPayloadEnvelope = await signedPayloadEnvelope('{bad');
        final invalidPayloadPath = await writeFixture(
          'bypass-invalid-payload.json',
          invalidPayloadEnvelope,
        );
        final invalidPayload = await runTool(script, [invalidPayloadPath]);
        expect(invalidPayload.exitCode, 2);
        expect(invalidPayload.stdout.toString(), contains('signature: VALID'));
        expect(
          invalidPayload.stderr.toString(),
          contains('payloadJson is not a valid bypass audit trail'),
        );

        final usage = await runTool(script, []);
        expect(usage.exitCode, 2);
        expect(usage.stderr.toString(), contains('usage:'));

        final missing = await runTool(script, ['${tempDir.path}/missing.json']);
        expect(missing.exitCode, 2);
        expect(missing.stderr.toString(), contains('could not read'));
        expect(missing.stdout.toString(), isEmpty);

        final unreadable = await runTool(script, [tempDir.path]);
        expect(unreadable.exitCode, 2);
        expect(unreadable.stderr.toString(), contains('could not read'));
        expect(unreadable.stdout.toString(), isEmpty);
      },
    );
  });
}
