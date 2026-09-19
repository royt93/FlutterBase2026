// Audit fix (post-T205) — this used to be a "grep the source code" test:
// it read tool/*.dart as plain text and asserted certain substrings were
// present (e.g. "opts['priv-file']"). That proves nothing about actual
// runtime behavior — the whole point of this task is that a real process's
// argv/stdout must never contain the private key material, which a string
// match against source text cannot observe at all. It also can't catch a
// real bug: e.g. the substring could exist in dead code while the live path
// leaks the secret some other way.
//
// Rewritten to actually spawn each CLI as a real subprocess (`dart run
// tool/*.dart`) and inspect its REAL stdout/stderr/exit code — the same
// surface a shell history, `ps`, or a CI log would expose. The completion
// doc's "device/CI smoke" claim for this task was also misleading: these
// are dev-machine/CI shell tools with no device-specific behavior to prove
// (same class of gap found in T215's CompatibilityMatrix tool test) — the
// real proof is a real subprocess run, which is what this file does, not a
// phone.
//
// Slower than a typical unit test (each `dart run` cold-compiles a small
// script) — acceptable for the security property this task exists to prove.

import 'dart:convert';
import 'dart:io';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

String _join(String a, String b) => '$a${Platform.pathSeparator}$b';

/// Locates the ad_sdk package root the same way `no_tracked_artefacts_test.dart`
/// does, so this file also works when `flutter test` is invoked from a
/// different working directory.
Directory _packageRoot() {
  var dir = Directory.current;
  while (true) {
    if (File(_join(dir.path, 'pubspec.yaml')).existsSync() &&
        Directory(_join(dir.path, 'tool')).existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      fail('could not locate the ad_sdk package root from '
          '${Directory.current.path}');
    }
    dir = parent;
  }
}

Future<ProcessResult> _runDart(
  Directory root,
  String script,
  List<String> args, {
  String? stdinInput,
}) async {
  // Bare `dart <file>` (not `dart run <file>`) — `dart run` triggers Dart's
  // native-assets build-hooks step on Dart 3.10+ toolchains, which prints
  // "Running build hooks..." to STDOUT ahead of the script's own output and
  // corrupts every assertion below that parses stdout as the minted key/CRL.
  final process = await Process.start(
      'dart', [_join('tool', script), ...args],
      workingDirectory: root.path);
  if (stdinInput != null) {
    process.stdin.write(stdinInput);
  }
  await process.stdin.close();
  final stdout = await process.stdout.transform(utf8.decoder).join();
  final stderr = await process.stderr.transform(utf8.decoder).join();
  final code = await process.exitCode;
  return ProcessResult(process.pid, code, stdout, stderr);
}

/// codex round-2 fix — a fixed `.tmp-t205-priv*` path under the package root
/// could collide with a concurrent test-suite invocation sharing the same
/// checkout (each keygen call used `--force`, so one run could silently
/// overwrite or delete the private-key file another still-running
/// invocation depends on), and could even clobber a real developer's own
/// file of that name. Each call now gets its own unique temp directory, so
/// there is nothing to collide with and no `--force` is needed.
class _GeneratedKey {
  _GeneratedKey(this.privValue, this.publicKeyBase64, this.stdout,
      this.stderr, this.privFile);
  final String privValue;
  final String publicKeyBase64;
  final String stdout;
  final String stderr;
  final File privFile;
}

Future<_GeneratedKey> _generateKey(Directory root) async {
  final tempDir = await Directory.systemTemp.createTemp('t205_vip_');
  addTearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });
  final privPath = _join(tempDir.path, 'priv');
  final result =
      await _runDart(root, 'vip_keygen.dart', ['--private-out', privPath]);
  expect(result.exitCode, 0, reason: result.stderr);

  final privFile = File(privPath);
  expect(privFile.existsSync(), isTrue);
  final privValue = (await privFile.readAsString()).trim();

  final pubMatch = RegExp(r'PUBLIC.*?:\s*(\S+)').firstMatch(result.stdout);
  expect(pubMatch, isNotNull,
      reason: 'could not find the public key in keygen stdout');

  return _GeneratedKey(
      privValue, pubMatch!.group(1)!, result.stdout, result.stderr, privFile);
}

void main() {
  final root = _packageRoot();

  test(
      '--priv is rejected outright, with no secret ever reaching stdout/stderr',
      () async {
    const fakeSecret = 'thisIsASecretThatMustNeverAppearInOutput123';
    final result =
        await _runDart(root, 'vip_mint.dart', ['--priv', fakeSecret, '--days', '1']);

    expect(result.exitCode, isNot(0),
        reason: '--priv must be a hard rejection, not a warning');
    final combined = '${result.stdout}${result.stderr}';
    expect(combined, isNot(contains(fakeSecret)),
        reason: 'the secret must never be echoed back, in any form');
    expect(combined, contains('argv is observable'));
  }, timeout: const Timeout(Duration(seconds: 60)));

  test(
      'vip_mint --priv-file mints a genuinely verifiable key without '
      'leaking the private key value to stdout', () async {
    final key = await _generateKey(root);

    expect(key.stdout, isNot(contains(key.privValue)),
        reason: 'keygen must never print the private key value itself');
    expect(key.stderr, isNot(contains(key.privValue)),
        reason: 'stderr is a CI log surface too — the contract covers both '
            'streams, not only stdout');

    if (!Platform.isWindows) {
      final mode = key.privFile.statSync().mode;
      // Last 3 octal digits of the POSIX mode must be exactly 600 (rw-------).
      expect(mode & 0x1FF, 0x180,
          reason: 'private key file must be 0600, not group/world readable');
    }

    final mintResult = await _runDart(root, 'vip_mint.dart',
        ['--priv-file', key.privFile.path, '--days', '1', '--kid', 't205']);
    expect(mintResult.exitCode, 0, reason: mintResult.stderr);
    expect(mintResult.stdout, isNot(contains(key.privValue)),
        reason: 'mint must never echo the private key it read from the file');
    expect(mintResult.stderr, isNot(contains(key.privValue)));

    final code = mintResult.stdout.trim();
    expect(code, startsWith('AVP2.'));

    // The real end-to-end proof: the code this real subprocess just minted
    // must actually verify against the SDK's own real verifier — not just
    // "the CLI exited 0 and printed something AVP2-shaped".
    final verified = await verifySignedVipKey(code,
        publicKeyBase64: key.publicKeyBase64);
    expect(verified.duration, const Duration(days: 1));
  }, timeout: const Timeout(Duration(seconds: 60)));

  test(
      'vip_mint --priv-stdin mints a genuinely verifiable key without '
      'leaking the piped private key to stdout', () async {
    final key = await _generateKey(root);

    final mintResult = await _runDart(
      root,
      'vip_mint.dart',
      ['--priv-stdin', '--seconds', '3600', '--kid', 't205stdin'],
      stdinInput: key.privValue,
    );
    expect(mintResult.exitCode, 0, reason: mintResult.stderr);
    expect(mintResult.stdout, isNot(contains(key.privValue)));
    expect(mintResult.stderr, isNot(contains(key.privValue)));

    final code = mintResult.stdout.trim();
    final verified = await verifySignedVipKey(code,
        publicKeyBase64: key.publicKeyBase64);
    expect(verified.duration, const Duration(seconds: 3600));
  }, timeout: const Timeout(Duration(seconds: 60)));

  test(
      'vip_crl_mint --priv-stdin mints a genuinely verifiable CRL without '
      'leaking the piped private key to stdout', () async {
    final key = await _generateKey(root);

    final crlResult = await _runDart(
      root,
      'vip_crl_mint.dart',
      ['--priv-stdin', '--kids', 'K3,K4'],
      stdinInput: key.privValue,
    );
    expect(crlResult.exitCode, 0, reason: crlResult.stderr);
    expect(crlResult.stdout, isNot(contains(key.privValue)));
    expect(crlResult.stderr, isNot(contains(key.privValue)));

    final code = crlResult.stdout.trim();
    final revoked =
        await verifySignedCrl(code, publicKeyBase64: key.publicKeyBase64);
    expect(revoked.revokedKeyIds, containsAll(['K3', 'K4']));
  }, timeout: const Timeout(Duration(seconds: 60)));

  test(
      'vip_crl_mint --priv-file mints a genuinely verifiable CRL without '
      'leaking the private key to stdout', () async {
    final key = await _generateKey(root);

    final crlResult = await _runDart(root, 'vip_crl_mint.dart',
        ['--priv-file', key.privFile.path, '--kids', 'K1,K2']);
    expect(crlResult.exitCode, 0, reason: crlResult.stderr);
    expect(crlResult.stdout, isNot(contains(key.privValue)));
    expect(crlResult.stderr, isNot(contains(key.privValue)));

    final code = crlResult.stdout.trim();
    expect(code, startsWith('CRL1.'));
    final revoked =
        await verifySignedCrl(code, publicKeyBase64: key.publicKeyBase64);
    expect(revoked.revokedKeyIds, containsAll(['K1', 'K2']));
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('--priv is rejected the same way for vip_crl_mint', () async {
    const fakeSecret = 'anotherSecretThatMustNeverLeak456';
    final result = await _runDart(
        root, 'vip_crl_mint.dart', ['--priv', fakeSecret, '--kids', 'K1']);
    expect(result.exitCode, isNot(0));
    final combined = '${result.stdout}${result.stderr}';
    expect(combined, isNot(contains(fakeSecret)));
    // codex round-1 fix — without asserting on the SPECIFIC diagnostic, this
    // test would still pass if the dedicated --priv guard were removed
    // entirely: --priv's value is never read into the signing path at all
    // (only --priv-file/--priv-stdin are), so the CLI would still exit
    // non-zero (a generic "no key source" error) and never echo the fake
    // secret either way, masking the missing guard.
    expect(combined, contains('argv is observable'));
  }, timeout: const Timeout(Duration(seconds: 60)));
}
