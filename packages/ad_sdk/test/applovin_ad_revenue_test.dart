// Round-32 audit fix — `appLovinRevenueEvent` is the pure mapping logic
// pulled out of `AppLovinAdapter._emitRevenueIfPresent` so the 3 widget-level
// AppLovin surfaces (banner/mrec/native `MaxAdView`/`MaxNativeAdView`
// listeners) can build the same event shape without duplicating it. See
// applovin_ad_revenue.dart's doc comment for why the callback wiring itself
// isn't tested here (no platform-view channel test seam in this repo).
import 'package:applovin_admob_sdk/src/adapters/applovin_ad_revenue.dart';
import 'package:applovin_admob_sdk/src/state/ad_placement.dart';
import 'package:applovin_admob_sdk/src/state/ad_slot.dart';
import 'package:applovin_max/applovin_max.dart';
import 'package:flutter_test/flutter_test.dart';

// MaxAd's constructor is positional, not named (see applovin_adapter_test.dart
// _fakeAd() for the same pattern): adUnitId, adFormat, adViewId, networkName,
// networkPlacement, revenue, revenuePrecision, creativeId, dspName,
// placement, latencyMillis, waterfall, nativeAd, size.
MaxAd _adWithRevenue(double revenue, {String networkName = 'unity_ads'}) =>
    MaxAd('unit', 'BANNER', null, networkName, '', revenue, 'exact', 'cid',
        'dsp', '', 0, MaxAdWaterfallInfo('', '', const [], 0), null, null);

void main() {
  group('appLovinRevenueEvent', () {
    test('revenue > 0 maps every MaxAd field to the matching event field',
        () {
      final ad = _adWithRevenue(1.23, networkName: 'unity_ads');
      final event = appLovinRevenueEvent(ad,
          type: AdSlotType.banner, placement: AdPlacement.unspecified);

      expect(event, isNotNull);
      expect(event!.providerTag, '[AppLovin]');
      expect(event.type, AdSlotType.banner);
      expect(event.placement, AdPlacement.unspecified);
      expect(event.valueMicros, 1230000,
          reason: r'$1.23 -> 1_230_000 micros');
      expect(event.currencyCode, 'USD');
      expect(event.networkName, 'unity_ads');
      expect(event.mediationWaterfall, ['unity_ads'],
          reason: 'AppLovin only reports the winning network, not a '
              'step-by-step waterfall like AdMob');
    });

    test('revenue == 0 (test mode / no fill data) returns null, not a '
        'zero-value event', () {
      final ad = _adWithRevenue(0);
      expect(
          appLovinRevenueEvent(ad,
              type: AdSlotType.mrec, placement: AdPlacement.unspecified),
          isNull);
    });

    test('negative revenue (should never happen, but a malformed native '
        'payload should not be trusted) also returns null', () {
      final ad = _adWithRevenue(-1);
      expect(
          appLovinRevenueEvent(ad,
              type: AdSlotType.native, placement: AdPlacement.unspecified),
          isNull);
    });
  });
}
