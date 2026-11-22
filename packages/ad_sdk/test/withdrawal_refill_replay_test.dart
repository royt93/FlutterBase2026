// Privacy Options withdrawal must refill the fullscreen slots promptly.
//
// Device finding (Pixel 7 Pro, hosted 3.7.6, 2026-11-22): after the user
// submitted "Do not consent", only App Open reloaded; Interstitial, Rewarded and
// Rewarded Interstitial stayed idle ~4 min until the 5-minute poll. The form
// dismiss raises a lifecycle resume while the apply is still running, so that
// resume is skipped and replayed later; the apply's own refill had already run
// against the still-closed gate and loaded nothing.

import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/core/ad_provider_adapter.dart';
import 'package:applovin_admob_sdk/src/core/iab_storage.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mobile_ads/src/ump/user_messaging_codec.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _CountingAdapter implements AdProviderAdapter {
  @override
  final AdSlot appOpenSlot = AdSlot(type: AdSlotType.appOpen);
  @override
  final AdSlot interstitialSlot = AdSlot(type: AdSlotType.interstitial);
  @override
  final AdSlot rewardedSlot = AdSlot(type: AdSlotType.rewarded);
  @override
  final AdSlot rewardedInterstitialSlot =
      AdSlot(type: AdSlotType.rewardedInterstitial);
  int inter = 0, rew = 0, rewInter = 0, appOpen = 0;
  final List<AdConsent> applied = [];
  @override
  AdEventSink? eventSink;
  @override
  bool Function() canReload = () => true;
  @override
  String get tag => 'counting';
  @override
  Future<bool> initialize(
    AdConfig config, {
    String deviceGaid = '',
    bool isAgeRestrictedUser = false,
    AdConsent? consent,
  }) async =>
      true;
  @override
  Future<void> dispose() async {}
  @override
  void applyConsent(AdConsent c) => applied.add(c);
  @override
  Future<void> loadInterstitial() async => inter++;
  @override
  Future<void> loadRewarded() async => rew++;
  @override
  Future<void> loadRewardedInterstitial() async => rewInter++;
  @override
  Future<void> loadAppOpen({void Function(bool loaded)? onAdLoaded}) async =>
      appOpen++;
  int discards = 0;
  @override
  Future<void> discardCachedFullscreenAds() async {
    // Same effect as the real adapters: only `ready` slots are dropped.
    for (final s in [
      appOpenSlot,
      interstitialSlot,
      rewardedSlot,
      rewardedInterstitialSlot
    ]) {
      if (s.isReady) {
        s.reset();
        discards++;
      }
    }
  }

  void markAllReady() {
    for (final s in [
      appOpenSlot,
      interstitialSlot,
      rewardedSlot,
      rewardedInterstitialSlot
    ]) {
      s.beginLoad();
      s.markReady();
    }
  }

  @override
  dynamic noSuchMethod(Invocation i) => Future<void>.value();
}

const _config = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'ca-app-pub-3940256099942544/1111111111',
    interstitialId: 'ca-app-pub-3940256099942544/2222222222',
    appOpenId: 'ca-app-pub-3940256099942544/3333333333',
    rewardedId: 'ca-app-pub-3940256099942544/4444444444',
  ),
  smartPreloadEnabled: false,
  firstInstallVipGrace: FirstInstallVipGrace.disabled,
);

const _allow = '1011000000';
const _refuse = '1010000000';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const al = MethodChannel('applovin_max');
  const gma = MethodChannel('plugins.flutter.io/google_mobile_ads');
  final ump = MethodChannel('plugins.flutter.io/google_mobile_ads/ump',
      StandardMethodCodec(UserMessagingCodec()));

  late Completer<void> formGate;
  late _CountingAdapter adapter;

  void seedTcf(String purposes) {
    IabStorage.debugResetForTest();
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData({
      'IABTCF_gdprApplies': 1,
      'IABTCF_PurposeConsents': purposes,
    });
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AdPreferences.resetForTest();
    formGate = Completer<void>();
    messenger.setMockMethodCallHandler(al, (c) async => <String, dynamic>{});
    messenger.setMockMethodCallHandler(gma, (c) async => null);
    messenger.setMockMethodCallHandler(ump, (c) {
      switch (c.method) {
        case 'ConsentInformation#canRequestAds':
          return Future.value(true);
        case 'ConsentInformation#getConsentStatus':
          return Future.value(3); // obtained
        case 'ConsentInformation#isConsentFormAvailable':
          return Future.value(true);
        case 'ConsentInformation#getPrivacyOptionsRequirementStatus':
          return Future.value(1); // required
        case 'UserMessagingPlatform#showPrivacyOptionsForm':
          return formGate.future.then((_) => null);
        default:
          return Future.value(null);
      }
    });
    await AdManager().destroy();
    AdManager().debugVipManager = null;
    seedTcf(_allow);
    adapter = _CountingAdapter();
    AdManager.debugAdapterFactory = (config) => adapter;
    AdManager().debugConnectivityInit = () async {};
    await AdManager().initialize(config: _config, onComplete: (_, _) {});
    expect(AdManager().isInitialised, isTrue, reason: 'sanity: real init ran');
    await pumpEventQueue(times: 200);
    AdManager().debugReconnectDebounce = Duration.zero;
    await AdManager().setConsent(const AdConsent(hasUserConsent: true));
    expect(adapter.applied.last.hasUserConsent, isTrue,
        reason: 'sanity: personalised consent reached the provider first');
    adapter.markAllReady();
    adapter.inter = adapter.rew = adapter.rewInter = adapter.appOpen = 0;
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(al, null);
    messenger.setMockMethodCallHandler(gma, null);
    messenger.setMockMethodCallHandler(ump, null);
    AdManager.debugAdapterFactory = null;
    AdManager().debugVipManager = null;
    AdManager().debugSetAdapter(null);
    AdManager().debugConfig = null;
    await AdManager().destroy();
  });

  /// Opens Privacy Options, then dismisses it the way Android does: an
  /// `inactive` + `resumed` lifecycle pair lands while the apply is running.
  Future<void> submitForm(String purposes, {bool withResume = true}) async {
    final f = AdManager().showPrivacyOptions();
    await pumpEventQueue(times: 20);
    if (withResume) {
      AdManager().didChangeAppLifecycleState(AppLifecycleState.inactive);
    }
    seedTcf(purposes);
    formGate.complete();
    if (withResume) {
      AdManager().didChangeAppLifecycleState(AppLifecycleState.resumed);
    }
    await f;
    await pumpEventQueue(times: 100);
  }

  test('withdrawal with the dismiss-time resume refills every fullscreen slot',
      () async {
    await submitForm(_refuse);

    expect(AdManager().consent.hasUserConsent, isFalse, reason: 'sanity');
    expect(AdManager().canRequestAds, isTrue,
        reason: 'non-personalised ads stay servable after a withdrawal');
    expect(adapter.inter, greaterThan(0), reason: 'Interstitial refilled');
    expect(adapter.rew, greaterThan(0), reason: 'Rewarded refilled');
    expect(adapter.rewInter, greaterThan(0),
        reason: 'Rewarded Interstitial refilled');
    expect(adapter.appOpen, greaterThan(0), reason: 'App Open refilled');
  });

  test('every provider write for the withdrawal precedes the first reload',
      () async {
    await submitForm(_refuse);
    // After the discard the adapter was told "refused" before any load went
    // out: the refill never requests under the old, personalised configuration.
    expect(adapter.applied.last.hasUserConsent, isFalse);
    expect(adapter.discards, 4, reason: 'all four cached ads dropped');
    expect(adapter.inter, greaterThan(0));
  });

  test('without a dismiss-time resume nothing refills until the poll',
      () async {
    // Documents the boundary of the fix: Android always raises the resume, but
    // if a platform did not, only the 5-minute poll refills. The gate was never
    // closed by a TCF-only withdrawal, so no "held slots" refill fires either.
    await submitForm(_refuse, withResume: false);
    expect(adapter.inter + adapter.rew + adapter.rewInter, 0);
    AdManager().debugRetryRefillAds();
    await pumpEventQueue(times: 50);
    expect(adapter.inter, greaterThan(0), reason: 'the poll path still works');
  });

  test('re-submitting the same consent with a resume does not double-refill',
      () async {
    await submitForm(_allow);
    final after = adapter.inter;
    expect(after, lessThanOrEqualTo(2),
        reason: 'one refill from the replayed resume at most');
  });

  test('an active VIP entry keeps every fullscreen slot unloaded', () async {
    final prefs = await AdPreferences.getInstance();
    final vip = VipManager(prefs);
    await vip.addVip(key: 'PAID', duration: const Duration(days: 1));
    AdManager().debugVipManager = vip;

    await submitForm(_refuse);

    expect(adapter.inter + adapter.rew + adapter.rewInter + adapter.appOpen, 0,
        reason: 'VIP suppresses all ad surfaces; the replay must not bypass it');
  });

  test('offline: the replayed refill loads nothing', () async {
    AdManager().debugConnectivityChanged(false);
    await pumpEventQueue(times: 20);
    await submitForm(_refuse);

    expect(adapter.inter + adapter.rew + adapter.rewInter, 0,
        reason: '_retryRefillAds returns early while offline');
  });

  test('a paused app drops the skipped resume: no refill from a stale replay',
      () async {
    final f = AdManager().showPrivacyOptions();
    await pumpEventQueue(times: 20);
    AdManager().didChangeAppLifecycleState(AppLifecycleState.inactive);
    seedTcf(_refuse);
    formGate.complete();
    AdManager().didChangeAppLifecycleState(AppLifecycleState.resumed);
    AdManager().didChangeAppLifecycleState(AppLifecycleState.inactive);
    AdManager().didChangeAppLifecycleState(AppLifecycleState.paused);
    await f;
    await pumpEventQueue(times: 100);

    expect(AdManager().consent.hasUserConsent, isFalse,
        reason: 'the withdrawal itself still applied');
    expect(adapter.applied.last.hasUserConsent, isFalse);
  });
}
