// Widget-level proof for Issue 1 — the SAME `canRequestAdsListenable` that
// BannerAdWidget/MrecAdWidget/NativeAdWidget subscribe to (see
// banner_ad_widget_test.dart's T101 group) must actually flip in a mounted
// widget tree when initialize()'s autoRequestUmpConsent branch fails open vs
// closed. This is the real contract boundary between Issue 1 (the UMP
// fail-open/closed decision) and Issue 4 (ad widgets reactively gating on
// it) — proves the decision is not just an internal flag but something a
// mounted widget observes.
//
// Runs the REAL initialize() (provider: AppLovin — see
// ump_auto_fail_open_closed_test.dart's header comment for why AdMob can't
// be used here), with AdManager().debugForceAutoUmpError forcing the exact
// exception under test.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _alChannel = MethodChannel('applovin_max');
const _gmaChannel = MethodChannel('plugins.flutter.io/google_mobile_ads');

AdConfig _appLovinConfig() => const AdConfig(
      provider: AdProvider.appLovin,
      appLovin: AppLovinConfig(
        sdkKey: 'test-sdk-key',
        bannerId: 'banner-id',
        interstitialId: 'interstitial-id',
        appOpenId: 'appopen-id',
        rewardedId: 'rewarded-id',
      ),
      safety: AdSafetyParams(dryRun: true),
      autoRequestUmpConsent: true,
    );

Widget _gateLabel() => MaterialApp(
      home: ValueListenableBuilder<bool>(
        valueListenable: AdManager().canRequestAdsListenable,
        builder: (context, canRequest, _) =>
            Text(canRequest ? 'GATE OPEN' : 'GATE CLOSED'),
      ),
    );

void main() {
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_alChannel, (call) async {
      if (call.method == 'initialize') return <String, dynamic>{};
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_gmaChannel, (call) async => null);
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_alChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_gmaChannel, null);
  });

  tearDown(() async {
    AdManager().debugForceAutoUmpError = null;
    await AdManager().destroy();
  });

  testWidgets(
      'MissingPluginException fails OPEN — mounted widget flips to OPEN',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    AdManager().debugForceAutoUmpError =
        MissingPluginException('forced for test');

    await tester.pumpWidget(_gateLabel());

    await tester.runAsync(() => AdManager().initialize(
          config: _appLovinConfig(),
          onComplete: (_, __) {},
        ));
    await tester.pump();

    expect(find.text('GATE OPEN'), findsOneWidget,
        reason: 'a mounted listener must observe the fail-open outcome, '
            'not just an internal flag');
  });

  testWidgets(
      'a non-MissingPluginException fails CLOSED — mounted widget stays '
      'CLOSED', (tester) async {
    SharedPreferences.setMockInitialValues({});
    AdManager().debugForceAutoUmpError = Exception('forced network failure');

    await tester.pumpWidget(_gateLabel());

    await tester.runAsync(() => AdManager().initialize(
          config: _appLovinConfig(),
          onComplete: (_, __) {},
        ));
    await tester.pump();

    expect(find.text('GATE CLOSED'), findsOneWidget,
        reason: 'a mounted listener must still see the gate closed after a '
            'real consent-fetch failure — the fail-closed decision must be '
            'reactive-visible, not just internally correct');
  });
}
