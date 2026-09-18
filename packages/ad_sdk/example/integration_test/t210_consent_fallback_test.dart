// Audit fix (post-T210) — this file was missing
// IntegrationTestWidgetsFlutterBinding.ensureInitialized(), so it never
// actually ran through the integration_test package's device-driving
// mechanism (same gap separately found in T211's, T215's, and T218's
// device test files). It also only round-tripped the pure
// ConsentFallbackState data class (encode/decode), which needs no device at
// all — every real, device-specific behavior (persisting through a REAL
// SharedPreferences plugin, not a mock) was untested.
//
// Rewritten to exercise ConsentManager's real staleRevision reclassification
// (see consent_manager.dart's _load()) through an actual on-device
// SharedPreferences round-trip: persist a fallback recorded under an old
// policy revision, bootstrap ConsentManager for real, and confirm the
// reclassification survives a genuine plugin round-trip, not just a mocked
// one (see the equivalent, mocked-prefs unit tests in
// packages/ad_sdk/test/consent_manager_test.dart).

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'T210 device smoke: a fallback recorded under an old policy revision '
      'is reclassified as staleRevision through a real SharedPreferences '
      'round-trip', (tester) async {
    ConsentManager.resetForTest();
    final prefs = await AdPreferences.getInstance();
    await prefs.clearConsentFallback();

    final old = ConsentFallbackState.create(
      policyRevision: 'ump-v0',
      reason: ConsentFallbackReason.timeout,
    );
    await prefs.setConsentFallbackRaw(old.encode());

    final cm = await ConsentManager.bootstrap(prefs: prefs);

    expect(cm.fallback?.reason, ConsentFallbackReason.staleRevision,
        reason: 'ump-v0 no longer matches kUmpPolicyRevision — this must '
            'hold with a real SharedPreferences plugin, not just a mock');
    expect(cm.fallback?.policyRevision, 'ump-v0');

    // Confirm the reclassification was actually written back to the real
    // plugin, not only held in memory.
    final rawAfter = prefs.getConsentFallbackRaw();
    expect(ConsentFallbackState.decode(rawAfter).reason,
        ConsentFallbackReason.staleRevision);

    await prefs.clearConsentFallback();
    ConsentManager.resetForTest();
  });
}
