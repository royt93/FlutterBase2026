// T293 point 6 — a device clock moved BACK after a fullscreen ad left the
// throttle and the hourly cap holding until the clock caught up again.
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const params = AdSafetyParams(
    minTimeBetweenFullscreenAds: 60000,
    minSessionDurationBeforeAd: 0,
    maxFullscreenAdsPerHour: 2,
    maxFullscreenAdsPerSession: 99,
    maxFullscreenAdsPerDay: 99,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AdPreferences.resetForTest();
    AdSafetyConfig.resetForReinit();
    await AdSafetyConfig.init(await AdPreferences.getInstance(),
        params: params);
  });

  bool allowed() => AdSafetyConfig.canShowFullscreenAdPeek().canShow;

  test('clock moved back a day does not block fullscreen for a day', () {
    AdSafetyConfig.recordFullscreenAdShown();
    AdSafetyConfig.debugMoveClockBack(const Duration(days: 1));
    // Healed: waits one normal throttle interval from now, not a day.
    expect(allowed(), isFalse, reason: 'throttle restarts from now');
    final r = AdSafetyConfig.canShowFullscreenAdPeek();
    final secs = double.parse(
        RegExp(r'wait ([\d.]+)s').firstMatch(r.reason)!.group(1)!);
    expect(secs, lessThanOrEqualTo(60), reason: r.reason);
  });

  test('moving the clock back never LIFTS the hourly cap', () {
    AdSafetyConfig.recordFullscreenAdShown();
    AdSafetyConfig.recordFullscreenAdShown();
    AdSafetyConfig.debugMoveClockBack(const Duration(days: 1));
    expect(allowed(), isFalse);
    expect(AdSafetyConfig.canShowFullscreenAdPeek().reason,
        anyOf(contains('Hourly'), contains('Throttle')));
  });

  test('without any rewind the throttle is unchanged', () {
    AdSafetyConfig.recordFullscreenAdShown();
    expect(allowed(), isFalse);
  });
}
