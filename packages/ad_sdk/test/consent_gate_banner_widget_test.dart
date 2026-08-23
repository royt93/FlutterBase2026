// Round-13 QC (round 9), widget layer — the consent gate is only worth
// anything if a mounted ad surface obeys it, so this pins the round-9 fix
// where it actually costs money: BannerAdWidget must not request an ad while
// a permissive Privacy-Options apply is still in flight with a *refusal*
// already queued behind it.
//
// Before the fix, `_applyConsentResultOnce` opened the gate as soon as its own
// write landed, without looking at `_pendingConsentApply`. The user had by
// then already submitted a withdrawal — the form was gone — and the reopened
// gate was enough for every mounted banner to fire a fresh request under a
// consent that no longer existed. Unit coverage for the flag lives in
// tcf_personalisation_consent_test.dart; this file proves the widget.

import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/core/iab_storage.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mobile_ads/src/ump/user_messaging_codec.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

const _alChannel = MethodChannel('applovin_max');
const _gmaChannel = MethodChannel('plugins.flutter.io/google_mobile_ads');
final _umpChannel = MethodChannel(
  'plugins.flutter.io/google_mobile_ads/ump',
  StandardMethodCodec(UserMessagingCodec()),
);

const int _statusObtained = 3;
const int _privacyOptionsRequired = 1;
const int _privacyOptionsNotRequired = 0;

/// Purposes 1, 3 and 4 — the personalised-advertising set — consented.
const String _purposesAllow = '1011000000';

/// The same user with purpose 4 refused.
const String _purposesRefuse = '1010000000';

/// Counts what the widget layer actually asks the provider for.
class _BannerCountingAdapter implements AdProviderAdapter {
  @override
  final AdSlot appOpenSlot = AdSlot(type: AdSlotType.appOpen);
  @override
  final AdSlot interstitialSlot = AdSlot(type: AdSlotType.interstitial);
  @override
  final AdSlot rewardedSlot = AdSlot(type: AdSlotType.rewarded);
  @override
  final AdSlot rewardedInterstitialSlot =
      AdSlot(type: AdSlotType.rewardedInterstitial);

  final Map<Object, AdSlot> bannerSlotsByKey = {};
  final Map<Object, BannerListenables> bannerListenablesByKey = {};
  final List<AdConsent> applied = <AdConsent>[];
  int loadBannerCalls = 0;

  @override
  AdSlot bannerSlot(Object key) =>
      bannerSlotsByKey.putIfAbsent(key, () => AdSlot(type: AdSlotType.banner));
  @override
  Iterable<AdSlot> get bannerSlots => bannerSlotsByKey.values;
  @override
  BannerListenables banner(Object key) => bannerListenablesByKey.putIfAbsent(
      key,
      () => BannerListenables(
            isLoaded: ValueNotifier<bool>(false),
            hasError: ValueNotifier<bool>(false),
            adSize: ValueNotifier<Size?>(null),
            autoRefreshEnabled: ValueNotifier<bool>(true),
            visible: ValueNotifier<bool>(true),
          ));
  @override
  void disposeBannerInstance(Object key) {
    bannerSlotsByKey.remove(key);
    bannerListenablesByKey.remove(key);
  }

  @override
  String get tag => 'counting';
  @override
  Future<void> loadBannerIfNeeded(Object key, double widthPx) async =>
      loadBannerCalls++;
  @override
  Future<void> preloadBanner(Object key) async {}
  @override
  Future<void> preloadMrec(Object key) async {}
  @override
  Future<void> loadInterstitial() async {}
  @override
  Future<void> loadRewarded() async {}
  @override
  Future<void> loadRewardedInterstitial() async {}
  @override
  Future<void> loadAppOpen({void Function(bool)? onAdLoaded}) async {}
  @override
  Widget? buildAdmobBannerView(Object key) => null;
  @override
  void applyConsent(AdConsent consent) => applied.add(consent);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _admobConfig = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'ca-app-pub-3940256099942544/6300978111',
    interstitialId: 'ca-app-pub-3940256099942544/1033173712',
    appOpenId: 'ca-app-pub-3940256099942544/9257395921',
    rewardedId: 'ca-app-pub-3940256099942544/5224354917',
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late int status;
  late bool canRequestAds;
  late int privacyOptionsRequirement;

  void seedTcf(Map<String, Object> data) {
    IabStorage.debugResetForTest();
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData(data);
  }

  Widget host(Widget child) => MaterialApp(
        navigatorObservers: [adRouteObserver],
        home: Scaffold(body: Center(child: child)),
      );

  setUp(() async {
    status = _statusObtained;
    canRequestAds = true;
    privacyOptionsRequirement = _privacyOptionsNotRequired;

    messenger.setMockMethodCallHandler(_alChannel, (call) async {
      if (call.method == 'initialize') return <String, dynamic>{};
      return null;
    });
    messenger.setMockMethodCallHandler(_gmaChannel, (call) async => null);
    messenger.setMockMethodCallHandler(_umpChannel, (call) {
      switch (call.method) {
        case 'ConsentInformation#canRequestAds':
          return Future.value(canRequestAds);
        case 'ConsentInformation#getConsentStatus':
          return Future.value(status);
        case 'ConsentInformation#isConsentFormAvailable':
          return Future.value(true);
        case 'ConsentInformation#getPrivacyOptionsRequirementStatus':
          return Future.value(privacyOptionsRequirement);
        default:
          return Future.value(null);
      }
    });

    await AdManager().destroy();
    AdPreferences.resetForTest();
    ConsentManager.resetForTest();
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    AdManager.debugConsentWriteBarrier = null;
    AdManager.debugConsentApplyBarrier = null;
    AdManager().debugSetAdapter(null);
    AdManager().debugConfig = null;
    AdManager().debugCanRequestAds = true;
    await AdManager().destroy();
    messenger.setMockMethodCallHandler(_alChannel, null);
    messenger.setMockMethodCallHandler(_gmaChannel, null);
    messenger.setMockMethodCallHandler(_umpChannel, null);
  });

  testWidgets(
      'a mounted banner requests nothing while a queued refusal is waiting '
      'behind an in-flight grant', (tester) async {
    final adapter = _BannerCountingAdapter();
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _admobConfig;
    AdManager().debugResetBannerCooldown();

    // Shut the gate the honest way: UMP says it cannot request ads.
    canRequestAds = false;
    seedTcf({
      'IABTCF_gdprApplies': 1,
      'IABTCF_PurposeConsents': _purposesRefuse,
    });
    await tester.runAsync(() => AdManager().requestUmpConsent());
    expect(AdManager().canRequestAds, isFalse, reason: 'sanity: gate shut');

    await tester.pumpWidget(host(const BannerAdWidget()));
    await tester.pump(const Duration(milliseconds: 50));
    expect(adapter.loadBannerCalls, 0,
        reason: 'sanity: a shut gate means no request at mount');

    privacyOptionsRequirement = _privacyOptionsRequired;

    // A grant takes the apply runner and parks just before its write.
    final stuckWrite = Completer<void>();
    AdManager.debugConsentWriteBarrier = stuckWrite.future;
    canRequestAds = true;
    seedTcf({
      'IABTCF_gdprApplies': 1,
      'IABTCF_PurposeConsents': _purposesAllow,
    });
    final grant = AdManager().showPrivacyOptions();
    await tester.pump(const Duration(milliseconds: 50));

    // The user then withdraws. That refusal is queued behind the grant, and
    // parked at the apply *entry* barrier so it cannot tighten the gate
    // itself — otherwise the grant's premature open would never be visible.
    final stuckEntry = Completer<void>();
    AdManager.debugConsentApplyBarrier = stuckEntry.future;
    canRequestAds = false;
    seedTcf({
      'IABTCF_gdprApplies': 1,
      'IABTCF_PurposeConsents': _purposesRefuse,
    });
    final refusal = AdManager().showPrivacyOptions();
    await tester.pump(const Duration(milliseconds: 50));

    // Let the older grant's write land.
    stuckWrite.complete();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    // Asserted before the flag it derives from, so a regression fails on the
    // consequence (a real ad request) rather than on the internal state.
    expect(adapter.loadBannerCalls, 0,
        reason: 'this is the money line: one reopened gate here is a live ad '
            'request made under a consent the user has already withdrawn');
    expect(AdManager().canRequestAds, isFalse,
        reason: 'a withdrawal is already queued — the gate must stay shut');

    stuckEntry.complete();
    await tester.runAsync(() async {
      await grant;
      await refusal;
    });
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(adapter.loadBannerCalls, 0, reason: 'and it stays that way');
    expect(AdManager().consent.hasUserConsent, isFalse,
        reason: 'the withdrawal is what got applied to the provider');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the other half — a clean grant does let the banner request',
      (tester) async {
    final adapter = _BannerCountingAdapter();
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _admobConfig;
    AdManager().debugResetBannerCooldown();

    canRequestAds = false;
    seedTcf({
      'IABTCF_gdprApplies': 1,
      'IABTCF_PurposeConsents': _purposesRefuse,
    });
    await tester.runAsync(() => AdManager().requestUmpConsent());
    await tester.pumpWidget(host(const BannerAdWidget()));
    await tester.pump(const Duration(milliseconds: 50));
    expect(adapter.loadBannerCalls, 0);

    // Nothing queued behind it this time — the gate must actually reopen, or
    // the fix above would have cost every consenting user their ads.
    privacyOptionsRequirement = _privacyOptionsRequired;
    canRequestAds = true;
    seedTcf({
      'IABTCF_gdprApplies': 1,
      'IABTCF_PurposeConsents': _purposesAllow,
    });
    await tester.runAsync(() => AdManager().showPrivacyOptions());
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(AdManager().canRequestAds, isTrue);
    expect(adapter.loadBannerCalls, 1,
        reason: 'a consenting user must get their banner back');
    expect(tester.takeException(), isNull);
  });
}
