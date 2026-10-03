import 'dart:convert';
import 'dart:io';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String validBundleJson;
  final toolScript = '${Directory.current.path}/tool/verify_adproof.dart';

  Future<ProcessResult> runTool(List<String> args) {
    return Process.run(
      'dart',
      ['run', toolScript, ...args],
      workingDirectory: Directory.current.path,
    );
  }

  String cleanOutput(String stdout) {
    final cleaned = stdout.replaceAll('Running build hooks...', '').trim();
    if (cleaned.endsWith('INVALID')) return 'INVALID';
    if (cleaned.endsWith('VALID')) return 'VALID';
    return cleaned;
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('t238_adproof_test_');

    final recorder = AdFlightRecorder();
    await recorder.record(
      label: 'bannerVisible',
      slotType: 'banner',
      placement: 'home',
      providerTag: '[AdMob]',
      viewabilityFraction: 1.0,
      widthPx: 320,
      heightPx: 50,
    );
    await recorder.record(
      label: 'clicked',
      slotType: 'banner',
      placement: 'home',
      providerTag: '[AdMob]',
      touchActive: true,
    );
    await recorder.record(
      label: 'bannerHidden',
      slotType: 'banner',
      placement: 'home',
      providerTag: '[AdMob]',
    );

    final bundle = FlightRecorderBundle(
      entries: recorder.entries,
      generatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    final signed = await signFlightRecorderBundle(bundle);
    validBundleJson = signed.toJsonString();
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('T238 — verify_adproof CLI', () {
    test('missing arguments prints usage and exits 2', () async {
      final res = await runTool([]);
      expect(res.exitCode, 2);
      expect(res.stderr.toString(), contains('usage: dart run tool/verify_adproof.dart <path>'));
      expect(cleanOutput(res.stdout.toString()), isEmpty);
    });

    test('missing or unreadable file prints error and exits 2', () async {
      final missingPath = '${tempDir.path}/nonexistent.adproof';
      final res = await runTool([missingPath]);
      expect(res.exitCode, 2);
      expect(res.stderr.toString(), contains('could not read'));
      expect(cleanOutput(res.stdout.toString()), isEmpty);
    });

    test('valid .adproof outputs VALID and exits 0', () async {
      final file = File('${tempDir.path}/valid.adproof');
      await file.writeAsString(validBundleJson);

      final res = await runTool([file.path]);
      expect(res.exitCode, 0);
      expect(cleanOutput(res.stdout.toString()), 'VALID');
      expect(res.stderr.toString().trim(), isEmpty);
    });

    test('tampered payload content invalidates signature -> INVALID and exit 1', () async {
      final decoded = jsonDecode(validBundleJson) as Map<String, dynamic>;
      final payload = jsonDecode(decoded['payloadJson'] as String) as Map<String, dynamic>;
      final entries = (payload['entries'] as List).cast<Map<String, dynamic>>();

      // Mutate a field
      entries[0]['widthPx'] = 400.0;
      decoded['payloadJson'] = jsonEncode(payload);

      final file = File('${tempDir.path}/tampered_field.adproof');
      await file.writeAsString(jsonEncode(decoded));

      final res = await runTool([file.path]);
      expect(res.exitCode, 1);
      expect(cleanOutput(res.stdout.toString()), 'INVALID');
    });

    test('re-signed payload with broken hash chain -> INVALID and exit 1', () async {
      final decoded = jsonDecode(validBundleJson) as Map<String, dynamic>;
      final payload = jsonDecode(decoded['payloadJson'] as String) as Map<String, dynamic>;
      final entries = (payload['entries'] as List).cast<Map<String, dynamic>>();

      // Reorder entries: swap entry 0 and 1
      final temp = entries[0];
      entries[0] = entries[1];
      entries[1] = temp;

      // Re-sign to make signature pass, proving chain check catches it
      final reorderedBundle = FlightRecorderBundle.fromJsonString(jsonEncode(payload));
      final reSigned = await signFlightRecorderBundle(reorderedBundle);

      final file = File('${tempDir.path}/reordered.adproof');
      await file.writeAsString(reSigned.toJsonString());

      final res = await runTool([file.path]);
      expect(res.exitCode, 1);
      expect(cleanOutput(res.stdout.toString()), 'INVALID');
    });

    test('re-signed payload with deleted middle entry -> INVALID and exit 1', () async {
      final decoded = jsonDecode(validBundleJson) as Map<String, dynamic>;
      final payload = jsonDecode(decoded['payloadJson'] as String) as Map<String, dynamic>;
      final entries = (payload['entries'] as List).cast<Map<String, dynamic>>();

      // Delete middle entry (index 1)
      entries.removeAt(1);

      final deletedBundle = FlightRecorderBundle.fromJsonString(jsonEncode(payload));
      final reSigned = await signFlightRecorderBundle(deletedBundle);

      final file = File('${tempDir.path}/deleted_middle.adproof');
      await file.writeAsString(reSigned.toJsonString());

      final res = await runTool([file.path]);
      expect(res.exitCode, 1);
      expect(cleanOutput(res.stdout.toString()), 'INVALID');
    });

    test('re-signed payload with forged appended entry -> INVALID and exit 1', () async {
      final decoded = jsonDecode(validBundleJson) as Map<String, dynamic>;
      final payload = jsonDecode(decoded['payloadJson'] as String) as Map<String, dynamic>;
      final entries = (payload['entries'] as List).cast<Map<String, dynamic>>();

      // Append forged entry with bogus previousHash
      final forgedEntry = Map<String, dynamic>.from(entries.last);
      forgedEntry['previousHash'] = 'deadbeef';
      entries.add(forgedEntry);

      final forgedBundle = FlightRecorderBundle.fromJsonString(jsonEncode(payload));
      final reSigned = await signFlightRecorderBundle(forgedBundle);

      final file = File('${tempDir.path}/appended_forged.adproof');
      await file.writeAsString(reSigned.toJsonString());

      final res = await runTool([file.path]);
      expect(res.exitCode, 1);
      expect(cleanOutput(res.stdout.toString()), 'INVALID');
    });

    test('re-signed payload with tampered previousHash -> INVALID and exit 1',
        () async {
      final decoded = jsonDecode(validBundleJson) as Map<String, dynamic>;
      final payload =
          jsonDecode(decoded['payloadJson'] as String) as Map<String, dynamic>;
      final entries =
          (payload['entries'] as List).cast<Map<String, dynamic>>();

      entries[1]['previousHash'] = 'deadbeef';

      final tamperedBundle =
          FlightRecorderBundle.fromJsonString(jsonEncode(payload));
      final reSigned = await signFlightRecorderBundle(tamperedBundle);
      final file = File('${tempDir.path}/tampered_previous_hash.adproof');
      await file.writeAsString(reSigned.toJsonString());

      final res = await runTool([file.path]);
      expect(res.exitCode, 1);
      expect(cleanOutput(res.stdout.toString()), 'INVALID');
    });

    test('tampered signature -> INVALID and exit 1', () async {
      final decoded = jsonDecode(validBundleJson) as Map<String, dynamic>;
      final sig = decoded['signatureBase64'] as String;
      // Mutate last character
      final flip = sig.endsWith('A') ? 'B' : 'A';
      final corruptedSig = '${sig.substring(0, sig.length - 2)}$flip=';
      decoded['signatureBase64'] = corruptedSig;

      final file = File('${tempDir.path}/corrupt_sig.adproof');
      await file.writeAsString(jsonEncode(decoded));

      final res = await runTool([file.path]);
      expect(res.exitCode, 1);
      expect(cleanOutput(res.stdout.toString()), 'INVALID');
    });

    test('tampered public key -> INVALID and exit 1', () async {
      final decoded = jsonDecode(validBundleJson) as Map<String, dynamic>;
      final pub = decoded['publicKeyBase64'] as String;
      final flip = pub.endsWith('A') ? 'B' : 'A';
      final corruptedPub = '${pub.substring(0, pub.length - 2)}$flip=';
      decoded['publicKeyBase64'] = corruptedPub;

      final file = File('${tempDir.path}/corrupt_pub.adproof');
      await file.writeAsString(jsonEncode(decoded));

      final res = await runTool([file.path]);
      expect(res.exitCode, 1);
      expect(cleanOutput(res.stdout.toString()), 'INVALID');
    });

    test('malformed JSON content -> INVALID and exit 1', () async {
      final file = File('${tempDir.path}/malformed.adproof');
      await file.writeAsString('not a valid json {]');

      final res = await runTool([file.path]);
      expect(res.exitCode, 1);
      expect(cleanOutput(res.stdout.toString()), 'INVALID');
    });
  });
}
