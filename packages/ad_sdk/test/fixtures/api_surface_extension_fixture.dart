// T222 — test-only fixture library for api_surface_extension_test.dart.
//
// The shipped public barrel (lib/applovin_admob_sdk.dart) exports no
// `extension` today, so there is nothing real for the golden test to prove
// `tool/api_surface.dart` now walks extension members. This library is
// analyzed directly by that test (computePublicApiSurface takes an
// entryLibraryRelativePath) so the extension walk is exercised for real
// WITHOUT adding an extension to the shipped API surface.
//
// Not exported anywhere; changing it only affects that one test.
library;

import 'package:flutter/foundation.dart';

/// Public extension whose members must appear in the computed API surface.
extension FixturePublicExtension on int {
  int get fixtureDoubled => this * 2;

  String fixtureLabel(String prefix) => '$prefix$this';

  set fixtureIgnored(int value) {}

  int _fixturePrivate() => this;

  @visibleForTesting
  int get fixtureDebugSeam => this;
}

/// Private extension — must be skipped entirely.
extension _FixturePrivateExtension on int {
  int get fixtureHidden => this;
}

// Keeps the private members above from tripping unused-element analysis.
int fixtureUse(int v) => v._fixturePrivate() + v.fixtureHidden;
