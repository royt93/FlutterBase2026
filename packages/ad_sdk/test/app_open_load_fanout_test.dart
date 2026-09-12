import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    AdManager().debugResetGuardState();
    AdManager().debugSetAdapter(null);
  });

  test('concurrent app-open callers each receive one callback', () async {
    final adapter = FakeAdProviderAdapter();
    final manager = AdManager();
    manager.debugResetGuardState();
    manager.debugSetAdapter(adapter);
    manager.debugCanRequestAds = true;
    var first = 0;
    var second = 0;
    await Future.wait([
      manager.loadAppOpenAd(onAdLoaded: (_) => first++),
      manager.loadAppOpenAd(onAdLoaded: (_) => second++),
    ]);
    expect(adapter.appOpenSlot.isReady, isTrue);
    expect(first, 1);
    expect(second, 1);
  });

  test('a throwing callback does not prevent other callbacks', () async {
    final adapter = FakeAdProviderAdapter();
    final manager = AdManager();
    manager.debugResetGuardState();
    manager.debugSetAdapter(adapter);
    manager.debugCanRequestAds = true;
    var delivered = 0;
    await Future.wait([
      manager.loadAppOpenAd(onAdLoaded: (_) => throw StateError('host')),
      manager.loadAppOpenAd(onAdLoaded: (_) => delivered++),
    ]);
    expect(delivered, 1);
  });
}
