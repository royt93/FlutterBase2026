// T149 — the periodic backstop retry (`_scheduleNextRetry`) and the
// offline→online reconnect retry (`_onConnectivityChanged`) both have an
// `if (_umpFormAbandoned) unawaited(_recheckAbandonedUmpForm())` branch
// sitting right next to their sibling `else unawaited(_retryUmpConsent())`
// branch. Round-39 (see ump_retry_zone_guard_test.dart) wrapped the sibling
// in `runZonedGuarded` because `requestConsentInfoUpdate` is a callback API
// that throws from a future nobody awaits when the UMP channel is
// missing/misconfigured — an UNHANDLED ZONE ERROR no try/catch around the
// call can see. `_recheckAbandonedUmpForm()` awaits the exact same class of
// UMP channel call (`ConsentInformation#canRequestAds`/`getConsentStatus`,
// see ump_consent.dart's `recheckUmpConsentStatus()`) but was never given
// the same guard — on a device with flapping connectivity and a form the
// user abandoned mid-flow, each retry could crash the whole app with an
// unhandled zone error, repeatedly.

import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MinimalAdapter implements AdProviderAdapter {
  @override
  final AdSlot appOpenSlot = AdSlot(type: AdSlotType.appOpen);
  @override
  final AdSlot interstitialSlot = AdSlot(type: AdSlotType.interstitial);
  @override
  final AdSlot rewardedSlot = AdSlot(type: AdSlotType.rewarded);
  @override
  final AdSlot rewardedInterstitialSlot =
      AdSlot(type: AdSlotType.rewardedInterstitial);
  @override
  void applyConsent(AdConsent consent) {}
  @override
  Future<void> dispose() async {}
  @override
  Future<void> loadInterstitial() async {}
  @override
  Future<void> loadRewarded() async {}
  @override
  Future<void> loadRewardedInterstitial() async {}
  @override
  Future<void> loadAppOpen({void Function(bool)? onAdLoaded}) async {}
  @override
  Future<void> preloadBanner(Object key) async {}
  @override
  Future<void> preloadMrec(Object key) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _config = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'ca-app-pub-3940256099942544/1111111111',
    interstitialId: 'ca-app-pub-3940256099942544/2222222222',
    appOpenId: 'ca-app-pub-3940256099942544/3333333333',
    rewardedId: 'ca-app-pub-3940256099942544/4444444444',
  ),
);

Future<void> _flush() => Future<void>.delayed(const Duration(milliseconds: 5));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await AdPreferences.getInstance();
    await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
    AdSafetyConfig.resetForReinit();

    AdManager().debugSetAdapter(_MinimalAdapter());
    AdManager().debugConfig = _config; // isInitialised → true
    AdManager().debugVipManager = null;
    AdManager().debugReconnectDebounce = Duration.zero;
    AdManager().debugUmpAttemptFailed = true;
    AdManager().debugUmpFormAbandoned = true;
    AdManager().debugForceAutoUmpError =
        Exception('simulated unhandled UMP channel error');
  });

  tearDown(() {
    AdManager().debugSetAdapter(null);
    AdManager().debugConfig = null;
    AdManager().debugVipManager = null;
    AdManager().debugUmpAttemptFailed = false;
    AdManager().debugUmpFormAbandoned = false;
    AdManager().debugForceAutoUmpError = null;
  });

  test(
      'reconnect abandoned-form recheck does not escape as an unhandled '
      'zone error when the UMP channel throws', () async {
    var caught = false;
    Object? seen;
    await runZonedGuarded(() async {
      AdManager().debugConnectivityChanged(false); // baseline offline
      AdManager().debugConnectivityChanged(true); // reconnect → rechecks form
      await _flush();
    }, (e, st) {
      caught = true;
      seen = e;
    });

    expect(caught, isFalse,
        reason: 'the reconnect abandoned-form recheck must catch its own '
            'error internally — it must never escape to an outer zone as '
            'unhandled (saw: $seen)');
  });

  test(
      'periodic backstop abandoned-form recheck does not escape as an '
      'unhandled zone error when the UMP channel throws', () {
    var caught = false;
    var threw = false;
    runZonedGuarded(() {
      fakeAsync((async) {
        AdManager().debugConnectivityChanged(true); // isConnected → true
        AdManager().debugStartAdRetryTimer();
        try {
          async.elapse(const Duration(minutes: 5, seconds: 1));
        } catch (_) {
          threw = true;
        }
      });
    }, (e, st) {
      caught = true;
    });

    expect(caught || threw, isFalse,
        reason: 'the periodic backstop abandoned-form recheck must catch '
            'its own error internally — it must never escape as unhandled, '
            'whether to an outer zone or synchronously out of fakeAsync\'s '
            'elapse()');
  });
}
