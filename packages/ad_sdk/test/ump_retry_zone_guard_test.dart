// Round-39 audit (claude-cli independent review), MAJOR-3 — the init-time
// auto-UMP flow already wraps its `requestUmpConsent()` call in
// `runZonedGuarded` (see `initialize()`'s own comment: `requestConsentInfoUpdate`
// is a callback API that throws from a future nobody awaits when the UMP
// channel is missing/misconfigured, so the error escapes as an UNHANDLED ZONE
// ERROR that no try/catch around the call can see). The periodic backstop
// retry (`_scheduleNextRetry`) and the offline→online reconnect retry
// (`_onConnectivityChanged`) both call the exact same `_retryUmpConsent()`
// unawaited, with NO zone guard — on a device with flapping connectivity and
// a broken UMP integration, each retry can crash the whole app with an
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
    AdManager().debugForceAutoUmpError =
        Exception('simulated unhandled UMP channel error');
  });

  tearDown(() {
    AdManager().debugSetAdapter(null);
    AdManager().debugConfig = null;
    AdManager().debugVipManager = null;
    AdManager().debugUmpAttemptFailed = false;
    AdManager().debugForceAutoUmpError = null;
  });

  test(
      'reconnect UMP retry does not escape as an unhandled zone error when '
      'requestUmpConsent throws', () async {
    var caught = false;
    Object? seen;
    await runZonedGuarded(() async {
      AdManager().debugConnectivityChanged(false); // baseline offline
      AdManager().debugConnectivityChanged(true); // reconnect → retries UMP
      await _flush();
    }, (e, st) {
      caught = true;
      seen = e;
    });

    expect(caught, isFalse,
        reason: 'the reconnect UMP retry must catch its own error internally '
            '— it must never escape to an outer zone as unhandled '
            '(saw: $seen)');
  });

  test(
      'periodic backstop UMP retry does not escape as an unhandled zone '
      'error when requestUmpConsent throws', () {
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
        reason: 'the periodic backstop UMP retry must catch its own error '
            'internally — it must never escape as unhandled, whether to an '
            'outer zone or synchronously out of fakeAsync\'s elapse()');
  });
}
