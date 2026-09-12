import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('T211 Android smoke: concurrent loads converge safely',
      (tester) async {
    final adapter = FakeAdProviderAdapter();
    final manager = AdManager();
    manager.debugResetGuardState();
    manager.debugSetAdapter(adapter);
    manager.debugCanRequestAds = true;
    await Future.wait([
      manager.loadInterstitial(),
      manager.loadInterstitial(),
      manager.loadInterstitial(),
    ]);
    expect(adapter.interstitialSlot.isReady, isTrue);
    manager.debugSetAdapter(null);
    manager.debugResetGuardState();
  });
}
