import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

Directory _findPackageRoot({Directory? from}) {
  var directory = from ?? Directory.current;
  while (true) {
    final candidates = [
      directory,
      Directory('${directory.path}/packages/ad_sdk'),
    ];
    for (final candidate in candidates) {
      final pubspec = File('${candidate.path}/pubspec.yaml');
      if (pubspec.existsSync()) {
        final name = RegExp(
          r'^name:\s*applovin_admob_sdk\s*$',
          multiLine: true,
        );
        if (name.hasMatch(pubspec.readAsStringSync())) return candidate;
      }
    }
    final parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError('could not find applovin_admob_sdk package root');
    }
    directory = parent;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('package root is found from a monorepo root working directory', () {
    final package = _findPackageRoot(from: Directory.current.parent.parent);
    expect(package.path, endsWith('/packages/ad_sdk'));
  });

  late Directory tempDir;
  late SimpleKeyPair keyPair;
  late String publicKeyBase64;
  late String signatureBase64;

  final ed25519 = Ed25519();
  final packageRoot = _findPackageRoot();

  Future<ProcessResult> runTool(String tool, List<String> args) => Process.run(
    'dart',
    ['run', '${packageRoot.path}/tool/$tool', ...args],
    workingDirectory: packageRoot.path,
  );

  Future<String> signedEnvelope(String payloadJson) async {
    final signature = await ed25519.sign(
      utf8.encode(payloadJson),
      keyPair: keyPair,
    );
    return jsonEncode({
      'payloadJson': payloadJson,
      'publicKeyBase64': publicKeyBase64,
      'signatureBase64': base64Url.encode(signature.bytes),
    });
  }

  Future<String> complianceEnvelope(String reportJson) async {
    final signature = await ed25519.sign(
      utf8.encode(reportJson),
      keyPair: keyPair,
    );
    return jsonEncode({
      'reportJson': reportJson,
      'publicKeyBase64': publicKeyBase64,
      'signatureBase64': base64Url.encode(signature.bytes),
    });
  }

  Future<File> writeFixture(String name, String contents) async {
    final file = File('${tempDir.path}/$name.json');
    await file.writeAsString(contents);
    return file;
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('signed_export_cli_');
    keyPair = await ed25519.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    publicKeyBase64 = base64Url.encode(publicKey.bytes);
    signatureBase64 = base64Url.encode(
      (await ed25519.sign(utf8.encode('{}'), keyPair: keyPair)).bytes,
    );
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  group('verify_compliance_report CLI', () {
    const tool = 'verify_compliance_report.dart';

    test('valid report prints VALID and exits zero', () async {
      final file = await writeFixture(
        'valid_compliance',
        await complianceEnvelope('{"schemaVersion":1}'),
      );
      final result = await runTool(tool, [file.path]);
      expect(result.exitCode, 0);
      expect(result.stdout, contains('VALID'));
      expect(result.stderr, isEmpty);
    });

    test('tampered signature prints INVALID and exits one', () async {
      final envelope =
          jsonDecode(await complianceEnvelope('{"schemaVersion":1}'))
              as Map<String, dynamic>;
      envelope['signatureBase64'] = signatureBase64;
      final file = await writeFixture('bad_compliance', jsonEncode(envelope));
      final result = await runTool(tool, [file.path]);
      expect(result.exitCode, 1);
      expect(result.stdout, contains('INVALID'));
    });

    test('missing path and malformed JSON use error exit codes', () async {
      final missing = await runTool(tool, ['${tempDir.path}/missing.json']);
      expect(missing.exitCode, 2);
      expect(missing.stderr, contains('could not read'));

      final malformed = await writeFixture('malformed_compliance', '{');
      final invalid = await runTool(tool, [malformed.path]);
      expect(invalid.exitCode, 1);
      expect(invalid.stdout, contains('INVALID'));
    });

    test('missing arguments prints usage and exits two', () async {
      final result = await runTool(tool, []);
      expect(result.exitCode, 2);
      expect(result.stderr, contains('usage:'));
    });
  });

  group('incident_replay CLI', () {
    const tool = 'incident_replay.dart';
    const payload = '{"generatedAtMs":1,"configFingerprint":{},"entries":[]}';

    test('valid signed bundle prints timeline and exits zero', () async {
      final file = await writeFixture(
        'valid_incident',
        await signedEnvelope(payload),
      );
      final result = await runTool(tool, [file.path]);
      expect(result.exitCode, 0);
      expect(result.stdout, contains('signature: VALID'));
      expect(result.stdout, contains('0 entries'));
      expect(result.stderr, isEmpty);
    });

    test('tampered signature still prints replay but exits one', () async {
      final envelope =
          jsonDecode(await signedEnvelope(payload)) as Map<String, dynamic>;
      envelope['signatureBase64'] = signatureBase64;
      final file = await writeFixture('bad_incident', jsonEncode(envelope));
      final result = await runTool(tool, [file.path]);
      expect(result.exitCode, 1);
      expect(result.stdout, contains('signature: INVALID'));
    });

    test('missing path and malformed envelope exit two', () async {
      final missing = await runTool(tool, ['${tempDir.path}/missing.json']);
      expect(missing.exitCode, 2);
      expect(missing.stderr, contains('could not read'));

      final malformed = await writeFixture('malformed_incident', '{');
      final result = await runTool(tool, [malformed.path]);
      expect(result.exitCode, 2);
      expect(result.stderr, contains('not a valid signed bundle'));
    });

    test('missing arguments prints usage and exits two', () async {
      final result = await runTool(tool, []);
      expect(result.exitCode, 2);
      expect(result.stderr, contains('usage:'));
    });
  });

  group('bypass_audit_replay CLI', () {
    const tool = 'bypass_audit_replay.dart';
    const payload = '{"generatedAtMs":1,"entries":[]}';

    test('valid signed bundle prints entries and exits zero', () async {
      final file = await writeFixture(
        'valid_bypass',
        await signedEnvelope(payload),
      );
      final result = await runTool(tool, [file.path]);
      expect(result.exitCode, 0);
      expect(result.stdout, contains('signature: VALID'));
      expect(result.stdout, contains('0 entries'));
      expect(result.stderr, isEmpty);
    });

    test('tampered signature still prints replay but exits one', () async {
      final envelope =
          jsonDecode(await signedEnvelope(payload)) as Map<String, dynamic>;
      envelope['signatureBase64'] = signatureBase64;
      final file = await writeFixture('bad_bypass', jsonEncode(envelope));
      final result = await runTool(tool, [file.path]);
      expect(result.exitCode, 1);
      expect(result.stdout, contains('signature: INVALID'));
    });

    test('missing path and malformed envelope exit two', () async {
      final missing = await runTool(tool, ['${tempDir.path}/missing.json']);
      expect(missing.exitCode, 2);
      expect(missing.stderr, contains('could not read'));

      final malformed = await writeFixture('malformed_bypass', '{');
      final result = await runTool(tool, [malformed.path]);
      expect(result.exitCode, 2);
      expect(result.stderr, contains('not a valid signed bundle'));
    });

    test('missing arguments prints usage and exits two', () async {
      final result = await runTool(tool, []);
      expect(result.exitCode, 2);
      expect(result.stderr, contains('usage:'));
    });
  });
}
