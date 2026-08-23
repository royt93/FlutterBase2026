// Round-6 QC — 124KB of `.bak` files were committed into `lib/` and only found
// by a reviewer reading the tree. `lib/` is always included in the published
// archive, so they would have shipped to pub.dev.
//
// The habit that created them is one worth keeping (`sed -i.bak` while doing
// revert-to-red experiments), and `.gitignore` alone did not help: the files
// were already staged by `git add -A` before the ignore rule existed. So the
// check lives here, where it runs on every `flutter test`.
//
// It deliberately asks git what is TRACKED rather than scanning the working
// tree: `pub publish` ships tracked files, so untracked local noise (a dozen
// `.DS_Store`s, in this repo's case) is not the risk and flagging it would
// train people to ignore this test.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('no editor/experiment artefacts are tracked under lib/, test/ or tool/',
      () {
    const suspiciousSuffixes = [
      '.bak',
      '.orig',
      '.rej',
      '.tmp',
      '.swp',
      '.DS_Store',
    ];

    // Anchor on this package's own root rather than the process CWD. Round-6
    // QC v3 caught the first version reporting a false GREEN when the suite was
    // run from the monorepo root: `git ls-files lib test tool` matches nothing
    // there, because the paths are `packages/ad_sdk/lib/...`. A guard that
    // quietly passes from the wrong directory is worse than no guard.
    Directory packageRoot = Directory.current;
    while (!File('${packageRoot.path}/pubspec.yaml').existsSync()) {
      final parent = packageRoot.parent;
      if (parent.path == packageRoot.path) break;
      packageRoot = parent;
    }
    final dirsToCheck = ['lib', 'test', 'tool']
        .where((d) => Directory('${packageRoot.path}/$d').existsSync())
        .toList();
    expect(dirsToCheck, isNotEmpty,
        reason: 'could not locate this package root from '
            '${Directory.current.path} — the guard would silently pass');

    final ProcessResult result;
    try {
      result = Process.runSync(
        'git',
        ['ls-files', ...dirsToCheck],
        workingDirectory: packageRoot.path,
      );
    } on ProcessException {
      // No git available (some CI images, a published-package consumer running
      // this suite) — nothing to assert rather than a false failure.
      return;
    }
    if (result.exitCode != 0) return;

    final offenders = (result.stdout as String)
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .where((path) => suspiciousSuffixes.any(path.endsWith))
        .toList();

    expect(offenders, isEmpty,
        reason: 'these are tracked, so they ship inside the published archive. '
            'Delete them with `git rm --cached` — note that adding a '
            '.gitignore rule does NOT untrack a file that is already '
            'committed, which is exactly how the round-6 batch survived');
  });
}
