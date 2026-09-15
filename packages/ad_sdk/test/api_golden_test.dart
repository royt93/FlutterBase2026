// T217 — public API golden test. Fails whenever the resolved public API
// surface (everything a `import 'package:applovin_admob_sdk/
// applovin_admob_sdk.dart'` consumer sees — see tool/api_surface.dart's doc
// comment for exactly what counts) differs from the checked-in golden file,
// so an API change is always a conscious, reviewed diff — never an
// accidental side effect of an unrelated refactor.
//
// On a genuine, intentional API change: update CHANGELOG.md, then regenerate
// the golden file —
//   dart run tool/api_surface.dart > test/goldens/public_api_surface.txt
// — and review the diff before committing it.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/api_surface.dart';

void main() {
  test('public API surface matches test/goldens/public_api_surface.txt', () async {
    final golden =
        await File('test/goldens/public_api_surface.txt').readAsString();
    final actual =
        await computePublicApiSurface(packageRoot: Directory.current.path);

    if (actual.trim() == golden.trim()) return;

    final goldenLines = golden.trim().split('\n').toSet();
    final actualLines = actual.trim().split('\n').toSet();
    final added = actualLines.difference(goldenLines).toList()..sort();
    final removed = goldenLines.difference(actualLines).toList()..sort();

    fail(
      'Public API surface changed — this must be a conscious, reviewed '
      'change (with a CHANGELOG.md entry), not an accidental side effect.\n'
      'If intentional, regenerate the golden file:\n'
      '  dart run tool/api_surface.dart > test/goldens/public_api_surface.txt\n\n'
      'Added (${added.length}):\n${added.map((l) => '  + $l').join('\n')}\n\n'
      'Removed (${removed.length}):\n${removed.map((l) => '  - $l').join('\n')}',
    );
  });

  test('excludes @visibleForTesting members but keeps ordinary public ones',
      () async {
    final actual =
        await computePublicApiSurface(packageRoot: Directory.current.path);

    // AdManager.debugCanRequestAds is a real @visibleForTesting seam — if
    // this ever starts appearing, the exclusion filter regressed and every
    // debug*/test-only member would start forcing golden-file churn on
    // every unrelated change.
    expect(actual, isNot(contains('debugCanRequestAds')),
        reason: '@visibleForTesting members must be excluded');

    // An ordinary public member must still show up — otherwise the filter
    // could have regressed to "exclude everything" and the test above
    // would pass vacuously.
    expect(actual, contains('InlineAdController.refresh'));
  });
}
