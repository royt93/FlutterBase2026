import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Android smoke: app-open callback fan-out stays one-per-caller',
      (tester) async {
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
}
