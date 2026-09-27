// T222 — regression test: tool/api_surface.dart must walk ExtensionElement2
// members, not just InterfaceElement2 ones.
//
// Points computePublicApiSurface at the test-only fixture library
// (test/fixtures/api_surface_extension_fixture.dart) so the shipped golden
// file stays untouched. Before the T222 fix this failed: only the extension's
// own top-level declaration line was emitted, never its members.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/api_surface.dart';

void main() {
  test('extension members appear in computed API surface', () async {
    final surface = await computePublicApiSurface(
      packageRoot: Directory.current.path,
      entryLibraryRelativePath:
          'test/fixtures/api_surface_extension_fixture.dart',
    );

    // Declared members are emitted, in the same MemberName format.
    expect(surface, contains('FixturePublicExtension'));
    expect(surface,
        contains('FixturePublicExtension.fixtureLabel  [method]'));
    expect(surface,
        contains('FixturePublicExtension.fixtureDoubled  [getter]'));
    expect(surface,
        contains('FixturePublicExtension.fixtureIgnored  [setter]'));

    // Private and @visibleForTesting members are excluded by the same
    // convention _describeMembers already applies to classes.
    expect(surface, isNot(contains('_fixturePrivate')));
    expect(surface, isNot(contains('fixtureDebugSeam')));

    // A private extension must not leak into the surface at all.
    expect(surface, isNot(contains('_FixturePrivateExtension')));
    expect(surface, isNot(contains('fixtureHidden')));
  });
}
