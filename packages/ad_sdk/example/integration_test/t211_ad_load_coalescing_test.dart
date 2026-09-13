import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// Audit fix (post-T211) — this file was missing
// IntegrationTestWidgetsFlutterBinding.ensureInitialized() and the
// integration_test import, so it never actually ran through the
// integration_test package's device-driving mechanism (same gap
// separately found in T210's, T215's, and T218's device test files).
// Also switched the assertion from the slot's end state (which can't
// distinguish real coalescing from 3 native calls that all happened to
// succeed) to a real native-invocation counter — see the matching fix in
// packages/ad_sdk/test/ad_load_coalescing_test.dart.
class _CountingAdapter extends FakeAdProviderAdapter {
  int interstitialLoadCalls = 0;

  @override
  Future<void> loadInterstitial() {
    interstitialLoadCalls++;
    return super.loadInterstitial();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'T211 device smoke: concurrent loads converge into exactly one real '
      'native request', (tester) async {
    final adapter = _CountingAdapter();
    final manager = AdManager();
    manager.debugResetGuardState();
    manager.debugSetAdapter(adapter);
    manager.debugCanRequestAds = true;
    await Future.wait([
      manager.loadInterstitial(),
      manager.loadInterstitial(),
      manager.loadInterstitial(),
    ]);
    expect(adapter.interstitialLoadCalls, 1);
    expect(adapter.interstitialSlot.isReady, isTrue);
    manager.debugSetAdapter(null);
    manager.debugResetGuardState();
  });
}
