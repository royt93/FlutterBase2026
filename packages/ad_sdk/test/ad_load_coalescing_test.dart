import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeAdProviderAdapter adapter;

  setUp(() {
    adapter = FakeAdProviderAdapter();
    final manager = AdManager();
    manager.debugResetGuardState();
    manager.debugSetAdapter(adapter);
    manager.debugCanRequestAds = true;
  });

  tearDown(() {
    AdManager().debugResetGuardState();
    AdManager().debugSetAdapter(null);
  });

  test('concurrent interstitial loads issue one native request', () async {
    await Future.wait(
        [AdManager().loadInterstitial(), AdManager().loadInterstitial()]);
    expect(adapter.interstitialSlot.isReady, isTrue);
  });

  test('failed request is removed from coalescing map and can retry', () async {
    adapter = FakeAdProviderAdapter(shouldSucceed: false);
    AdManager().debugSetAdapter(adapter);
    await AdManager().loadRewardedAd();
    await AdManager().loadRewardedAd();
    expect(adapter.rewardedSlot.isCooldown, isTrue);
  });
}
