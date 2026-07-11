// Coverage was 6.2% (4/64) — RealGmaBridge forwards to the real
// google_mobile_ads plugin and had never been exercised beyond adapter-level
// fakes (see admob_behavioral_test.dart's FakeGmaBridge).
//
// Scope: verifies initialize/updateRequestConfiguration/load* forward the
// correct channel method + request shape (nonPersonalizedAds, RDP extras).
// Does NOT simulate the platform->Dart onAdLoaded/onAdFailedToLoad callback
// (that requires hand-crafting a platform-to-Dart method call through the
// channel's custom AdMessageCodec — out of proportion to the payoff here);
// the _AppOpenWrap/_InterstitialWrap/_RewardedWrap show/dispose paths stay
// covered only via admob_behavioral_test.dart's FakeGmaBridge substitute.

import 'package:applovin_admob_sdk/src/adapters/gma_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
// AdMessageCodec isn't exported from the public API — needed to construct a
// mock channel matching the plugin's own codec.
import 'package:google_mobile_ads/src/ad_instance_manager.dart'
    show AdMessageCodec;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const bridge = RealGmaBridge();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  // Must match the production channel's codec (AdMessageCodec) — it has
  // custom encode/decode for InitializationStatus and AdRequest, which the
  // default StandardMethodCodec can't (de)serialize.
  final channel = MethodChannel(
    'plugins.flutter.io/google_mobile_ads',
    StandardMethodCodec(AdMessageCodec()),
  );

  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'MobileAds#initialize':
          return InitializationStatus(const {});
        default:
          return null;
      }
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('initialize forwards MobileAds#initialize', () async {
    await bridge.initialize();
    // MobileAds.instance's first-ever access also fires a one-time '_init'
    // hot-restart-cleanup call (see mobile_ads.dart), hence firstWhere.
    expect(calls.firstWhere((c) => c.method == 'MobileAds#initialize').method,
        'MobileAds#initialize');
  });

  test('updateRequestConfiguration forwards test device ids', () async {
    await bridge.updateRequestConfiguration(['device1', 'device2']);
    expect(calls.single.method, 'MobileAds#updateRequestConfiguration');
    expect(calls.single.arguments['testDeviceIds'], ['device1', 'device2']);
  });

  test(
      'loadAppOpen forwards ad unit id + nonPersonalizedAds, no RDP extras '
      'by default', () async {
    await bridge.loadAppOpen(
      'unit-open',
      nonPersonalizedAds: true,
      onLoaded: (_) {},
      onFailed: (_, __) {},
    );
    expect(calls.single.method, 'loadAppOpenAd');
    expect(calls.single.arguments['adUnitId'], 'unit-open');
    final request = calls.single.arguments['request'] as AdRequest;
    expect(request.nonPersonalizedAds, isTrue);
    expect(request.extras, isNull);
  });

  test('loadInterstitial forwards RDP extras when restrictedDataProcessing',
      () async {
    await bridge.loadInterstitial(
      'unit-inter',
      nonPersonalizedAds: false,
      restrictedDataProcessing: true,
      onLoaded: (_) {},
      onFailed: (_, __) {},
    );
    expect(calls.single.method, 'loadInterstitialAd');
    expect(calls.single.arguments['adUnitId'], 'unit-inter');
    final request = calls.single.arguments['request'] as AdRequest;
    expect(request.nonPersonalizedAds, isFalse);
    expect(request.extras, {'rdp': '1'});
  });

  test('loadRewarded forwards ad unit id + request', () async {
    await bridge.loadRewarded(
      'unit-rewarded',
      nonPersonalizedAds: true,
      onLoaded: (_) {},
      onFailed: (_, __) {},
    );
    expect(calls.single.method, 'loadRewardedAd');
    expect(calls.single.arguments['adUnitId'], 'unit-rewarded');
    final request = calls.single.arguments['request'] as AdRequest;
    expect(request.nonPersonalizedAds, isTrue);
    expect(request.extras, isNull);
  });

  test('GmaShowCallbacks stores every callback field', () {
    var shown = false, dismissed = false, clicked = false, impression = false;
    String? failedMessage;
    num? rewardAmount;
    String? rewardType;

    final cb = GmaShowCallbacks(
      onShowed: () => shown = true,
      onDismissed: () => dismissed = true,
      onFailedToShow: (m) => failedMessage = m,
      onClicked: () => clicked = true,
      onImpression: () => impression = true,
      onUserEarnedReward: (amount, type) {
        rewardAmount = amount;
        rewardType = type;
      },
    );

    cb.onShowed!();
    cb.onDismissed!();
    cb.onFailedToShow!('boom');
    cb.onClicked!();
    cb.onImpression!();
    cb.onUserEarnedReward!(5, 'coins');

    expect(shown, isTrue);
    expect(dismissed, isTrue);
    expect(failedMessage, 'boom');
    expect(clicked, isTrue);
    expect(impression, isTrue);
    expect(rewardAmount, 5);
    expect(rewardType, 'coins');
  });
}
