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
    show AdMessageCodec, instanceManager;

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
      onFailed: (_, _) {},
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
      onFailed: (_, _) {},
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
      onFailed: (_, _) {},
    );
    expect(calls.single.method, 'loadRewardedAd');
    expect(calls.single.arguments['adUnitId'], 'unit-rewarded');
    final request = calls.single.arguments['request'] as AdRequest;
    expect(request.nonPersonalizedAds, isTrue);
    expect(request.extras, isNull);
  });

  // m36 (audit_claude.md MINOR) — every _XxxWrap.dispose() nulled
  // fullScreenContentCallback but left onPaidEvent wired, so a paid-event
  // arriving after the ad was disposed still ran the closure
  // setPaidEventListener installed and _emit()ed revenue for a dead ad.
  //
  // Unlike the rest of this file these tests reach the real _XxxWrap: they
  // drive the plugin's own platform->Dart `onAdEvent`/`onAdLoaded` dispatch to
  // obtain the wrap the production onLoaded callback builds, and then fire the
  // exact field the plugin's own _invokePaidEvent invokes
  // (`ad.onPaidEvent?.call(...)`) — not a substitute of our own.
  group('m36 — dispose() unwires onPaidEvent', () {
    Future<void> checkDisposeUnwiresPaidEvent(
      String label,
      Future<void> Function(void Function(GmaFullscreenAd ad) onLoaded) load,
    ) async {
      calls.clear();
      GmaFullscreenAd? wrap;
      await load((a) => wrap = a);
      final adId = calls.last.arguments['adId'] as int;
      final ad = instanceManager.adFor(adId)! as AdWithoutView;

      await messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(
          MethodCall('onAdEvent', <dynamic, dynamic>{
            'adId': adId,
            'eventName': 'onAdLoaded',
            'responseInfo': null,
          }),
        ),
        (_) {},
      );
      expect(wrap, isNotNull,
          reason: '$label: onAdLoaded must hand back the production wrap');

      var paidEvents = 0;
      wrap!.setPaidEventListener((_, _, _) => paidEvents++);
      expect(ad.onPaidEvent, isNotNull, reason: '$label: listener wired');

      wrap!.dispose();

      expect(ad.onPaidEvent, isNull,
          reason: '$label: dispose() must unwire onPaidEvent');
      ad.onPaidEvent?.call(ad, 1234, PrecisionType.estimated, 'USD');
      expect(paidEvents, 0,
          reason: '$label: a paid-event after dispose must not reach the sink');
    }

    test('app open', () async {
      await checkDisposeUnwiresPaidEvent(
        'appOpen',
        (onLoaded) => bridge.loadAppOpen('unit-open',
            nonPersonalizedAds: false, onLoaded: onLoaded, onFailed: (_, _) {}),
      );
    });

    test('interstitial', () async {
      await checkDisposeUnwiresPaidEvent(
        'interstitial',
        (onLoaded) => bridge.loadInterstitial('unit-inter',
            nonPersonalizedAds: false, onLoaded: onLoaded, onFailed: (_, _) {}),
      );
    });

    test('rewarded', () async {
      await checkDisposeUnwiresPaidEvent(
        'rewarded',
        (onLoaded) => bridge.loadRewarded('unit-rewarded',
            nonPersonalizedAds: false, onLoaded: onLoaded, onFailed: (_, _) {}),
      );
    });

    test('rewarded interstitial', () async {
      await checkDisposeUnwiresPaidEvent(
        'rewardedInterstitial',
        (onLoaded) => bridge.loadRewardedInterstitial('unit-ri',
            nonPersonalizedAds: false, onLoaded: onLoaded, onFailed: (_, _) {}),
      );
    });
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
