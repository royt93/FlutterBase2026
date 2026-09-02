import 'package:applovin_max/applovin_max.dart';

import '../state/ad_event.dart';
import '../state/ad_placement.dart';
import '../state/ad_slot.dart';

/// Round-32 audit fix — shared by every AppLovin surface that reports
/// revenue (fullscreen formats in `applovin_adapter.dart`, and the
/// per-widget `MaxAdView`/`MaxNativeAdView` listeners in
/// `banner_ad_widget.dart`/`mrec_ad_widget.dart`/`native_ad_widget.dart`, all
/// of which need the exact same event shape from an `onAdRevenuePaidCallback`
/// but don't share a common base class to hang one method off of).
///
/// Pulled out as a pure function specifically so its mapping logic (the
/// `revenue <= 0` skip, the micros conversion, which `MaxAd` fields feed
/// which event field) has a direct unit test — the callback wiring itself,
/// through a third-party platform view's native channel, has no test seam in
/// this repo and can only be verified on a real device.
///
/// Returns `null` for `ad.revenue <= 0` (test mode / no revenue data —
/// AppLovin's own documented meaning for that value), matching
/// `AppLovinAdapter._emitRevenueIfPresent`'s existing skip for the
/// fullscreen formats.
AdRevenueEvent? appLovinRevenueEvent(
  MaxAd ad, {
  required AdSlotType type,
  required AdPlacement placement,
}) {
  final amount = ad.revenue;
  if (amount <= 0) return null;
  return AdRevenueEvent(
    providerTag: '[AppLovin]',
    type: type,
    placement: placement,
    valueMicros: (amount * 1000000).round(),
    currencyCode: 'USD',
    networkName: ad.networkName,
    precision: ad.revenuePrecision,
    // AppLovin only reports the winning network per impression — not a
    // step-by-step waterfall like AdMob's ResponseInfo.adapterResponses.
    mediationWaterfall: [ad.networkName],
  );
}
