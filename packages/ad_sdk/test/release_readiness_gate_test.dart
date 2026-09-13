// Audit fix (post-T213) — the old test only read tool/release_readiness_gate.sh
// as plain text and asserted a few substrings were present (stage names,
// the "2048" size ceiling). That cannot observe the actual behavior of a
// shell script at all — in particular it completely missed a real,
// confirmed-live bug: `secret_scan()`'s `rg` call sits inside an `if (...)`,
// where bash's `set -e` does not apply, so a MISSING `rg` binary (exit 127,
// "command not found") was indistinguishable from "no secret found" and the
// stage reported "release gate: secret passed" with no scan having run at
// all. Reproduced on this exact machine before the fix, with `rg` genuinely
// absent from a clean subprocess PATH (confirmed via `command -v rg`).
//
// Rewritten to spawn the real script as a real subprocess (same pattern as
// vip_cli_security_test.dart) and inspect its real exit code/stderr, and to
// prove the fix's positive path too: a small `pcre2grep`-backed stub
// standing in for `rg` (this dev environment's `rg`/`grep` are themselves
// shell functions from the coding assistant tooling, not real binaries —
// `pcre2grep` is the one genuine regex-capable binary available to build a
// deterministic stub from) lets the tests prove secret_scan/api_check
// actually PASS on a clean fixture and FAIL on a fixture containing a real
// injected secret / a missing required export, not just "didn't crash".

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Locates the ad_sdk package root the same way `no_tracked_artefacts_test.dart`
/// and `vip_cli_security_test.dart` do.
Directory _packageRoot() {
  var dir = Directory.current;
  while (true) {
    if (File('${dir.path}/pubspec.yaml').existsSync() &&
        Directory('${dir.path}/tool').existsSync()) {
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

/// codex round-1 fix — the "rg is missing" tests originally relied on this
/// dev machine's PATH happening not to have a real `rg` binary. That is an
/// accident of this one environment, not something the tests actually
/// arranged: on a normal machine/CI runner with ripgrep genuinely installed
/// (common — e.g. GitHub's ubuntu-latest images ship it), `rg` would
/// resolve fine, `secret_scan`/`api_check` would genuinely succeed, and
/// these tests would fail.
///
/// codex round-2 fix — the first attempt built the PATH by keeping whole
/// directories that provide `bash`/`git`/`xargs`/`cat`, minus any directory
/// that ALSO happened to contain `rg`. On Ubuntu (this repo's own CI
/// runner), apt installs ripgrep to `/usr/bin` — the exact same directory
/// as bash/git/xargs/cat — so that approach discarded the one directory
/// providing every required tool, leaving an empty PATH and failing before
/// either assertion below ever ran. This builds a single staging directory
/// containing ONLY symlinks named after the specific tools needed, so `rg`
/// is absent from this one directory regardless of where the real binaries
/// (needed or not) happen to live on the host.
Future<String> _pathWithoutRg() async {
  final staging = await Directory.systemTemp.createTemp('t213_no_rg_bin_');
  for (final tool in ['bash', 'git', 'xargs', 'cat']) {
    final which = await Process.run('bash', ['-c', 'command -v $tool']);
    final realPath = (which.stdout as String).trim();
    if (which.exitCode != 0 || realPath.isEmpty) {
      fail('could not resolve a real path for required tool "$tool"');
    }
    await Link('${staging.path}/$tool').create(realPath);
  }
  return staging.path;
}

Future<ProcessResult> _runGate(
  Directory cwd,
  String stage, {
  Map<String, String>? extraEnv,
}) {
  final env = Map<String, String>.from(Platform.environment);
  if (extraEnv != null) env.addAll(extraEnv);
  // The script itself always lives in the REAL repo — an absolute path, so
  // a fixture repo (which has no tool/ directory of its own) still runs the
  // real script, with `git rev-parse --show-toplevel` resolving to
  // whichever repo `cwd` sits in.
  final scriptPath = '${_packageRoot().path}/tool/release_readiness_gate.sh';
  return Process.run(
    'bash',
    [scriptPath, stage],
    workingDirectory: cwd.path,
    environment: env,
  );
}

/// A minimal, deterministic `rg` stand-in backed by the real `pcre2grep`
/// binary (see file doc comment for why `rg`/`grep` themselves can't be
/// trusted in this dev environment). Returns `null` (caller should skip)
/// if `pcre2grep` genuinely isn't installed anywhere on this machine.
Future<Directory?> _rgStubDir() async {
  final which = await Process.run('bash', ['-lc', 'command -v pcre2grep']);
  final pcre2grep = (which.stdout as String).trim();
  if (which.exitCode != 0 || pcre2grep.isEmpty) return null;

  final dir = await Directory.systemTemp.createTemp('t213_rg_stub_');
  final stub = File('${dir.path}/rg');
  await stub.writeAsString('''
#!/bin/bash
set -e
opts=()
quiet=0
pattern=""
files=()
for a in "\$@"; do
  case "\$a" in
    -n) opts+=(-n) ;;
    -q) quiet=1 ;;
    --pcre2) : ;;
    *)
      if [ -z "\$pattern" ]; then pattern="\$a"; else files+=("\$a"); fi
      ;;
  esac
done
if [ "\$quiet" = "1" ]; then
  exec "$pcre2grep" -q -- "\$pattern" "\${files[@]}"
else
  exec "$pcre2grep" "\${opts[@]}" -- "\$pattern" "\${files[@]}"
fi
''');
  await Process.run('chmod', ['+x', stub.path]);
  return dir;
}

/// A throwaway git repo shaped like this one, just enough for
/// `secret_scan`/`api_check` (`git ls-files 'packages/ad_sdk/lib/**'` and
/// the barrel file) to have something real to scan — isolated so a test
/// fixture can safely include an injected "secret" without ever touching
/// the real repository.
Future<Directory> _fixtureRepo({
  required bool withSecret,
  required bool withRequiredExports,
}) async {
  final dir = await Directory.systemTemp.createTemp('t213_fixture_repo_');
  final libDir = Directory('${dir.path}/packages/ad_sdk/lib');
  await libDir.create(recursive: true);

  final barrel = File('${libDir.path}/applovin_admob_sdk.dart');
  await barrel.writeAsString(withRequiredExports
      ? "export 'src/core/ad_manager.dart';\n"
          "export 'src/consent/consent_fallback.dart';\n"
      : "export 'src/core/ad_manager.dart';\n");

  if (withSecret) {
    await File('${libDir.path}/leaked.dart').writeAsString(
        'private_key = abcdefghijklmnop1234567890 // must never ship\n');
  } else {
    await File('${libDir.path}/clean.dart')
        .writeAsString('int add(int a, int b) => a + b;\n');
  }

  await Process.run('git', ['init', '-q'], workingDirectory: dir.path);
  await Process.run('git', ['add', '-A'], workingDirectory: dir.path);
  return dir;
}

void main() {
  final root = _packageRoot();

  group('the real script, dispatched for real (not grepped as text)', () {
    test('an unknown stage prints usage and exits 2', () async {
      final result = await _runGate(root, 'bogus');
      expect(result.exitCode, 2);
      expect(result.stderr, contains('usage:'));
    });

    test('size stage passes against the real repo (no rg needed)', () async {
      final result = await _runGate(root, 'size');
      expect(result.exitCode, 0, reason: result.stderr);
      expect(result.stdout, contains('release gate: size passed'));
    });

    test('dependency stage passes against the real repo (no rg needed)',
        () async {
      final result = await _runGate(root, 'dependency');
      expect(result.exitCode, 0, reason: result.stderr);
      expect(result.stdout, contains('release gate: dependency passed'));
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('audit fix (post-T213) — a missing rg must fail loudly, never '
      'silently pass', () {
    test(
        'secret_scan reports a real FAILURE, not "passed", when rg is '
        'missing — this used to be a false pass', () async {
      final env = {'PATH': await _pathWithoutRg()};
      final result = await _runGate(root, 'secret', extraEnv: env);
      expect(result.exitCode, isNot(0),
          reason: 'the confirmed bug: rg (127, not found) inside an `if` '
              'was indistinguishable from "no secret found" and this used '
              'to print "release gate: secret passed" with exit 0');
      expect(result.stdout, isNot(contains('secret passed')));
      expect(result.stderr, contains('rg (ripgrep) is required'));
    });

    test('api_check also fails with a clear diagnostic when rg is missing',
        () async {
      final env = {'PATH': await _pathWithoutRg()};
      final result = await _runGate(root, 'api', extraEnv: env);
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('rg (ripgrep) is required'));
    });
  });

  group('with a real rg available (pcre2grep-backed stub) — proves the '
      'positive AND negative fixture, not just "didn\'t crash"', () {
    test('secret_scan passes on a clean fixture, fails on one with a real '
        'injected secret', () async {
      final stubDir = await _rgStubDir();
      if (stubDir == null) {
        markTestSkipped('no pcre2grep binary available to build the rg '
            'stub on this machine');
        return;
      }
      final env = {'PATH': '${stubDir.path}:${Platform.environment['PATH']}'};

      final clean = await _fixtureRepo(
          withSecret: false, withRequiredExports: true);
      final cleanResult = await _runGate(clean, 'secret', extraEnv: env);
      expect(cleanResult.exitCode, 0, reason: cleanResult.stderr);

      final leaked = await _fixtureRepo(
          withSecret: true, withRequiredExports: true);
      final leakedResult = await _runGate(leaked, 'secret', extraEnv: env);
      expect(leakedResult.exitCode, isNot(0));
      expect(leakedResult.stderr, contains('possible secret found'));
    });

    test('api_check passes when the required exports are present, fails '
        'when one is missing', () async {
      final stubDir = await _rgStubDir();
      if (stubDir == null) {
        markTestSkipped('no pcre2grep binary available to build the rg '
            'stub on this machine');
        return;
      }
      final env = {'PATH': '${stubDir.path}:${Platform.environment['PATH']}'};

      final complete = await _fixtureRepo(
          withSecret: false, withRequiredExports: true);
      final completeResult = await _runGate(complete, 'api', extraEnv: env);
      expect(completeResult.exitCode, 0, reason: completeResult.stderr);

      final incomplete = await _fixtureRepo(
          withSecret: false, withRequiredExports: false);
      final incompleteResult =
          await _runGate(incomplete, 'api', extraEnv: env);
      expect(incompleteResult.exitCode, isNot(0),
          reason: 'the consent_fallback export is missing from this '
              'fixture\'s barrel file — api_check must catch that');
    });
  });
}
