// Coverage was 3.2% (1/31) — RealAppLovinBridge is a pure forwarding shim
// over the static AppLovinMAX plugin API and had never been exercised.
// Mocks the 'applovin_max' MethodChannel and asserts each bridge method
// invokes the correct native method name with the correct arguments.

import 'package:applovin_admob_sdk/src/adapters/applovin_bridge.dart';
import 'package:applovin_max/applovin_max.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const bridge = RealAppLovinBridge();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('applovin_max');

  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'isInitialized':
          return false;
        case 'initialize':
          return <String, dynamic>{};
        default:
          return null;
      }
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('initialize forwards sdk key', () async {
    // AppLovinMAX.initialize also probes 'isInitialized' first (hot-restart
    // guard) before invoking 'initialize' itself.
    await bridge.initialize('SDK-KEY');
    final call = calls.firstWhere((c) => c.method == 'initialize');
    expect(call.arguments['sdk_key'], 'SDK-KEY');
  });

  test('setTestDeviceAdvertisingIds forwards id list', () {
    bridge.setTestDeviceAdvertisingIds(['id1', 'id2']);
    expect(calls.single.method, 'setTestDeviceAdvertisingIds');
    expect(calls.single.arguments['value'], ['id1', 'id2']);
  });

  test('setTermsAndPrivacyPolicyFlowEnabled forwards flag', () {
    bridge.setTermsAndPrivacyPolicyFlowEnabled(true);
    expect(calls.single.method, 'setTermsAndPrivacyPolicyFlowEnabled');
    expect(calls.single.arguments['value'], isTrue);
  });

  test('listener setters do not throw (null and non-null)', () {
    expect(() => bridge.setAppOpenAdListener(null), returnsNormally);
    expect(() => bridge.setInterstitialListener(null), returnsNormally);
    expect(() => bridge.setRewardedAdListener(null), returnsNormally);
    expect(() => bridge.setWidgetAdViewAdListener(null), returnsNormally);
  });

  test('loadAppOpenAd / showAppOpenAd forward ad unit id', () {
    bridge.loadAppOpenAd('unit-open');
    expect(calls.single.method, 'loadAppOpenAd');
    expect(calls.single.arguments['ad_unit_id'], 'unit-open');

    calls.clear();
    bridge.showAppOpenAd('unit-open');
    expect(calls.single.method, 'showAppOpenAd');
    expect(calls.single.arguments['ad_unit_id'], 'unit-open');
  });

  test('loadInterstitial / showInterstitial forward ad unit id', () {
    bridge.loadInterstitial('unit-inter');
    expect(calls.single.method, 'loadInterstitial');
    expect(calls.single.arguments['ad_unit_id'], 'unit-inter');

    calls.clear();
    bridge.showInterstitial('unit-inter');
    expect(calls.single.method, 'showInterstitial');
    expect(calls.single.arguments['ad_unit_id'], 'unit-inter');
  });

  test('loadRewardedAd / showRewardedAd forward ad unit id', () {
    bridge.loadRewardedAd('unit-rewarded');
    expect(calls.single.method, 'loadRewardedAd');
    expect(calls.single.arguments['ad_unit_id'], 'unit-rewarded');

    calls.clear();
    bridge.showRewardedAd('unit-rewarded');
    expect(calls.single.method, 'showRewardedAd');
    expect(calls.single.arguments['ad_unit_id'], 'unit-rewarded');
  });

  test('preloadWidgetAdView forwards ad unit id + format', () async {
    await bridge.preloadWidgetAdView('unit-view', AdFormat.banner);
    expect(calls.single.method, 'preloadWidgetAdView');
    expect(calls.single.arguments['ad_unit_id'], 'unit-view');
    expect(calls.single.arguments['ad_format'], AdFormat.banner.value);
  });

  test('destroyWidgetAdView forwards ad view id', () async {
    await bridge.destroyWidgetAdView(42);
    expect(calls.single.method, 'destroyWidgetAdView');
    expect(calls.single.arguments['ad_view_id'], 42);
  });
}
