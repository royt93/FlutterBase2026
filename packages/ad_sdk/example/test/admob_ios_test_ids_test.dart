// Audit round 42, MAJOR (codex) — every AdMob id in DemoConfig used to be
// Google's ANDROID test unit with no `ios*Id` override, so an iOS run of
// this example silently requested Android test units for every format and
// never actually validated AdMob on iOS. This locks in that each format now
// has a distinct, correct iOS override.

import 'package:ad_sdk_example/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every AdMob format has a distinct iOS test-unit override', () {
    final admob = DemoConfig.instance.build().admob!;

    // Google's published iOS test ad unit ids
    // (developers.google.com/admob/flutter/test-ads) — each must differ
    // from the ANDROID fallback value used as the constructor's shared id.
    expect(admob.iosBannerId, 'ca-app-pub-3940256099942544/2934735716');
    expect(admob.iosInterstitialId, 'ca-app-pub-3940256099942544/4411468910');
    expect(admob.iosAppOpenId, 'ca-app-pub-3940256099942544/5662855259');
    expect(admob.iosRewardedId, 'ca-app-pub-3940256099942544/1712485313');
    expect(admob.iosMrecId, 'ca-app-pub-3940256099942544/2934735716');
    expect(admob.iosNativeId, 'ca-app-pub-3940256099942544/3986624511');
    expect(admob.iosRewardedInterstitialId,
        'ca-app-pub-3940256099942544/6978759866');

    // Every iOS override must genuinely differ from DemoConfig's ANDROID
    // test-unit constructor values (bannerId/interstitialId/etc. below) — an
    // iOS override that happened to equal the Android one would still hide
    // an iOS-specific bug even though the field is technically populated.
    const androidIds = {
      'banner': 'ca-app-pub-3940256099942544/6300978111',
      'interstitial': 'ca-app-pub-3940256099942544/1033173712',
      'appOpen': 'ca-app-pub-3940256099942544/9257395921',
      'rewarded': 'ca-app-pub-3940256099942544/5224354917',
      'native': 'ca-app-pub-3940256099942544/2247696110',
      'rewardedInterstitial': 'ca-app-pub-3940256099942544/5354046379',
    };
    expect(admob.iosBannerId, isNot(equals(androidIds['banner'])));
    expect(
        admob.iosInterstitialId, isNot(equals(androidIds['interstitial'])));
    expect(admob.iosAppOpenId, isNot(equals(androidIds['appOpen'])));
    expect(admob.iosRewardedId, isNot(equals(androidIds['rewarded'])));
    expect(admob.iosNativeId, isNot(equals(androidIds['native'])));
    expect(admob.iosRewardedInterstitialId,
        isNot(equals(androidIds['rewardedInterstitial'])));
  });
}
