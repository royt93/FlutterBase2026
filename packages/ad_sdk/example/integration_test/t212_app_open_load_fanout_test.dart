// On-device integration test for app-open load callback fan-out.
//
// codex/independent-audit fix — this file was missing
// IntegrationTestWidgetsFlutterBinding.ensureInitialized() and the
// integration_test import, so it could not actually run through the
// integration_test package's device-driving mechanism at all; it was a
// plain widget test mislabeled as a device smoke test (same gap an
// independent audit separately found in T210's device test file). Fixed
// here, and extended with the post-T218 audit-fix reentrant-callback case.
//
// Run with:
//   flutter test integration_test/t212_app_open_load_fanout_test.dart \
//     -d <device-or-sim-id>

import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('app-open callback fan-out stays one-per-caller, on a real '
      'device', (tester) async {
    final adapter = FakeAdProviderAdapter();
    final manager = AdManager();
    manager.debugResetGuardState();
    manager.debugSetAdapter(adapter);
    manager.debugCanRequestAds = true;
    var callbacks = 0;
    await Future.wait([
      manager.loadAppOpenAd(onAdLoaded: (_) => callbacks++),
      manager.loadAppOpenAd(onAdLoaded: (_) => callbacks++),
    ]);
    expect(callbacks, 2);
    manager.debugResetGuardState();
    manager.debugSetAdapter(null);
  });

  testWidgets(
      'T218 audit fix: a callback that reentrantly starts ANOTHER '
      'app-open load still gets its own callback invoked, on a real '
      'device', (tester) async {
    final adapter = FakeAdProviderAdapter();
    final manager = AdManager();
    manager.debugResetGuardState();
    manager.debugSetAdapter(adapter);
    manager.debugCanRequestAds = true;

    var firstDelivered = false;
    var secondDelivered = false;
    await manager.loadAppOpenAd(onAdLoaded: (_) {
      firstDelivered = true;
      unawaited(manager.loadAppOpenAd(onAdLoaded: (_) {
        secondDelivered = true;
      }));
    });
    for (var i = 0; i < 10 && !secondDelivered; i++) {
      await tester.pump();
    }

    expect(firstDelivered, isTrue);
    expect(secondDelivered, isTrue,
        reason: 'T218 — the reentrant call\'s own callback must actually '
            'fire, not join a phantom already-resolved future, on a real '
            'device process');
    manager.debugResetGuardState();
    manager.debugSetAdapter(null);
  });
}
