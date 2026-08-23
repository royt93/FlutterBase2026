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

  /// Non-null wedges `getConsentStatus` — the call the gate recovery makes
  /// before it is allowed to reopen anything.
  Completer<void>? statusGate;

  /// True makes every `getConsentStatus` call fail, not just one — a channel
  /// that is down stays down, which is what exhausts a retry budget
  /// (round-16 QC).
  bool statusThrows = false;

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
    statusGate = null;
    statusThrows = false;

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
          if (statusThrows) {
            return Future<int>.error(StateError('the consent channel is gone'));
          }
          final gate = statusGate;
          if (gate != null) return gate.future.then((_) => status);
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

  testWidgets(
      'a banner mounted during a personalisation withdrawal requests nothing '
      'until the new config has landed', (tester) async {
    // Round-13 QC (round 10) at the widget layer. The withdrawal that
    // actually happens in the wild never trips `canRequestAds`: the user turns
    // personalisation off, non-personalised ads stay servable, and UMP keeps
    // saying yes. What changes is the TCF purposes — read halfway through the
    // apply, well before the provider has been reconfigured. Anything that
    // mounts or refreshes an ad surface in that window used to get a
    // *personalised* request out under a consent already withdrawn.
    final adapter = _BannerCountingAdapter();
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _admobConfig;
    AdManager().debugResetBannerCooldown();

    canRequestAds = true;
    seedTcf({
      'IABTCF_gdprApplies': 1,
      'IABTCF_PurposeConsents': _purposesAllow,
    });
    await tester.runAsync(() => AdManager().requestUmpConsent());
    expect(AdManager().consent.hasUserConsent, isTrue,
        reason: 'sanity: personalised ads are what the provider has applied');

    await tester.pumpWidget(host(const BannerAdWidget()));
    await tester.pump(const Duration(milliseconds: 50));
    expect(adapter.loadBannerCalls, 1, reason: 'sanity: the first banner');

    privacyOptionsRequirement = _privacyOptionsRequired;
    final stuckWrite = Completer<void>();
    AdManager.debugConsentWriteBarrier = stuckWrite.future;
    // UMP still reports canRequestAds=true — only the purposes changed.
    seedTcf({
      'IABTCF_gdprApplies': 1,
      'IABTCF_PurposeConsents': _purposesRefuse,
    });
    final withdrawal = AdManager().showPrivacyOptions();
    await tester.pump(const Duration(milliseconds: 50));

    // A second ad surface appears mid-write — a user navigating to another
    // screen while the withdrawal is still being applied.
    await tester.pumpWidget(host(const Column(children: [
      BannerAdWidget(key: ValueKey('a')),
      BannerAdWidget(key: ValueKey('b')),
    ])));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(adapter.loadBannerCalls, 1,
        reason: 'the provider still has hasUserConsent=true applied, so a '
            'request accepted here is a personalised ad served after an '
            'explicit withdrawal');

    stuckWrite.complete();
    await tester.runAsync(() => withdrawal);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(AdManager().consent.hasUserConsent, isFalse,
        reason: 'the withdrawal is applied to the provider');
    expect(AdManager().canRequestAds, isTrue,
        reason: 'withdrawing personalisation is not withdrawing ads — the '
            'gate must reopen for non-personalised ones');
    expect(adapter.loadBannerCalls, greaterThan(1),
        reason: 'and the banners come back, now under the new config');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a banner mounted while a purposes-only withdrawal is queued requests '
      'nothing', (tester) async {
    // Round-13 QC (round 11) at the widget layer: the round-10 window, but
    // with the withdrawal stuck in the queue behind another apply instead of
    // being the apply in flight. Nothing inside the runner has read its TCF
    // purposes yet, and its `canRequestAds` is true, so before the fix nothing
    // shut the gate at all — a surface mounting here got a personalised
    // request out under a consent the user had already turned off.
    final adapter = _BannerCountingAdapter();
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _admobConfig;
    AdManager().debugResetBannerCooldown();

    canRequestAds = true;
    seedTcf({
      'IABTCF_gdprApplies': 1,
      'IABTCF_PurposeConsents': _purposesAllow,
    });
    await tester.runAsync(() => AdManager().requestUmpConsent());
    await tester.pumpWidget(host(const BannerAdWidget()));
    await tester.pump(const Duration(milliseconds: 50));
    expect(adapter.loadBannerCalls, 1, reason: 'sanity: the first banner');

    privacyOptionsRequirement = _privacyOptionsRequired;
    // An unrelated apply takes the runner and parks at its write.
    final stuckWrite = Completer<void>();
    AdManager.debugConsentWriteBarrier = stuckWrite.future;
    final first = AdManager().showPrivacyOptions();
    await tester.pump(const Duration(milliseconds: 50));

    // The withdrawal lands behind it, parked at the apply entry barrier so
    // the runner cannot tighten on its behalf either.
    final stuckEntry = Completer<void>();
    AdManager.debugConsentApplyBarrier = stuckEntry.future;
    seedTcf({
      'IABTCF_gdprApplies': 1,
      'IABTCF_PurposeConsents': _purposesRefuse,
    });
    final withdrawal = AdManager().showPrivacyOptions();
    await tester.pump(const Duration(milliseconds: 50));

    // A second ad surface appears while it waits.
    await tester.pumpWidget(host(const Column(children: [
      BannerAdWidget(key: ValueKey('a')),
      BannerAdWidget(key: ValueKey('b')),
    ])));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(adapter.loadBannerCalls, 1,
        reason: 'the provider still holds the personalised config, so a '
            'request accepted here is a personalised ad served after an '
            'explicit withdrawal');

    stuckWrite.complete();
    stuckEntry.complete();
    await tester.runAsync(() async {
      await first;
      await withdrawal;
    });
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(AdManager().consent.hasUserConsent, isFalse,
        reason: 'the withdrawal is what got applied');
    expect(AdManager().canRequestAds, isTrue,
        reason: 'and non-personalised ads are allowed once it has landed');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'banners come back after a queued apply was superseded instead of '
      'staying dark', (tester) async {
    // Round-13 QC (round 12) at the widget layer, and the layer that matters:
    // the round-11 close is a guess, and when the apply that owed the reopen
    // was superseded by the host's own decision, nothing lifted it. The flag
    // being wrong is invisible; a permanently empty banner is the bug.
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
    expect(adapter.loadBannerCalls, 0, reason: 'sanity: gate shut');

    privacyOptionsRequirement = _privacyOptionsRequired;
    canRequestAds = true;
    seedTcf({
      'IABTCF_gdprApplies': 1,
      'IABTCF_PurposeConsents': _purposesAllow,
    });
    final stuckWrite = Completer<void>();
    AdManager.debugConsentWriteBarrier = stuckWrite.future;
    final first = AdManager().showPrivacyOptions();
    await tester.pump(const Duration(milliseconds: 50));
    final queued = AdManager().showPrivacyOptions();
    await tester.pump(const Duration(milliseconds: 50));

    // The host's own decision supersedes both, so neither reopens the gate.
    AdManager.debugConsentWriteBarrier = null;
    await tester.runAsync(
        () => AdManager().setConsent(const AdConsent(hasUserConsent: true)));
    stuckWrite.complete();
    await tester.runAsync(() async {
      await first;
      await queued;
    });
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(adapter.loadBannerCalls, greaterThan(0),
        reason: 'the consent state on the device allows ads, so the banner '
            'must load — a gate nobody reopens is a blank ad slot for the '
            'rest of the session');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a banner requests nothing while the gate recovery is overtaken by a '
      'real apply', (tester) async {
    // Round-13 QC (round 13) at the widget layer. The recovery has awaits of
    // its own, and a withdrawal can start inside one of them. If it reopens
    // the gate on the strength of the snapshot it took before parking, a
    // mounted banner refreshes against the old personalised configuration —
    // the exact request rounds 9-12 exist to prevent.
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
    expect(adapter.loadBannerCalls, 0, reason: 'sanity: gate shut');

    // Arm the round-11 debt, then have the host supersede the applies that
    // owed the reopen.
    privacyOptionsRequirement = _privacyOptionsRequired;
    canRequestAds = true;
    seedTcf({
      'IABTCF_gdprApplies': 1,
      'IABTCF_PurposeConsents': _purposesAllow,
    });
    final stuck = Completer<void>();
    AdManager.debugConsentWriteBarrier = stuck.future;
    final first = AdManager().showPrivacyOptions();
    await tester.pump(const Duration(milliseconds: 50));
    final queued = AdManager().showPrivacyOptions();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
        () => AdManager().setConsent(const AdConsent(hasUserConsent: true)));

    // The recovery parks inside its UMP read.
    final wedge = Completer<void>();
    statusGate = wedge;
    AdManager.debugConsentWriteBarrier = null;
    stuck.complete();
    await tester.runAsync(() async {
      await first;
      await queued;
    });
    await tester.pump(const Duration(milliseconds: 50));

    // A withdrawal starts while it is parked, held before its own TCF read.
    final entry = Completer<void>();
    AdManager.debugConsentApplyBarrier = entry.future;
    final withdrawal = AdManager().showPrivacyOptions();
    await tester.pump(const Duration(milliseconds: 50));

    wedge.complete();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(adapter.loadBannerCalls, 0,
        reason: 'the apply in flight owns the gate — a banner request here is '
            'a personalised ad under a configuration about to change');

    seedTcf({
      'IABTCF_gdprApplies': 1,
      'IABTCF_PurposeConsents': _purposesRefuse,
    });
    AdManager.debugConsentApplyBarrier = null;
    entry.complete();
    await tester.runAsync(() => withdrawal);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(AdManager().consent.hasUserConsent, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'banners come back after a transient consent-channel failure',
      (tester) async {
    // The other half of round 13: the recovery is retried, so a channel that
    // failed once does not cost the session its ads.
    AdManager.debugConsentGateRecoveryRetryDelay =
        const Duration(milliseconds: 20);
    addTearDown(() => AdManager.debugConsentGateRecoveryRetryDelay = null);

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

    privacyOptionsRequirement = _privacyOptionsRequired;
    canRequestAds = true;
    seedTcf({
      'IABTCF_gdprApplies': 1,
      'IABTCF_PurposeConsents': _purposesAllow,
    });
    final stuck = Completer<void>();
    AdManager.debugConsentWriteBarrier = stuck.future;
    final first = AdManager().showPrivacyOptions();
    await tester.pump(const Duration(milliseconds: 50));
    final queued = AdManager().showPrivacyOptions();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
        () => AdManager().setConsent(const AdConsent(hasUserConsent: true)));

    final broken = Completer<void>();
    statusGate = broken;
    AdManager.debugConsentWriteBarrier = null;
    stuck.complete();
    await tester.runAsync(() async {
      await first;
      await queued;
    });
    await tester.pump(const Duration(milliseconds: 50));
    broken.completeError(StateError('the consent channel is gone'));
    await tester.runAsync(() => Future<void>.delayed(
        const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 20));
    expect(adapter.loadBannerCalls, 0, reason: 'sanity: nothing confirmed yet');

    // The channel comes back; the retry finds it.
    statusGate = null;
    await tester.runAsync(() => Future<void>.delayed(
        const Duration(milliseconds: 80)));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(adapter.loadBannerCalls, greaterThan(0),
        reason: 'one failed channel call must not leave every ad slot in the '
            'app blank for the rest of the session');
    expect(tester.takeException(), isNull);
  });

  // Round-14 QC, MAJOR — at the widget layer: a host settings toggle landing
  // while the gate recovery is mid-flight used to leave every banner in the
  // app blank for the rest of the session.
  testWidgets('banners come back after a host decision lands mid-recovery',
      (tester) async {
    AdManager.debugConsentGateRecoveryRetryDelay =
        const Duration(milliseconds: 20);
    addTearDown(() => AdManager.debugConsentGateRecoveryRetryDelay = null);

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

    privacyOptionsRequirement = _privacyOptionsRequired;
    canRequestAds = true;
    seedTcf({
      'IABTCF_gdprApplies': 1,
      'IABTCF_PurposeConsents': _purposesAllow,
    });
    final stuck = Completer<void>();
    AdManager.debugConsentWriteBarrier = stuck.future;
    final first = AdManager().showPrivacyOptions();
    await tester.pump(const Duration(milliseconds: 50));
    final queued = AdManager().showPrivacyOptions();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
        () => AdManager().setConsent(const AdConsent(hasUserConsent: true)));

    final wedge = Completer<void>();
    statusGate = wedge;
    AdManager.debugConsentWriteBarrier = null;
    stuck.complete();
    await tester.runAsync(() async {
      await first;
      await queued;
    });
    await tester.pump(const Duration(milliseconds: 50));
    expect(adapter.loadBannerCalls, 0, reason: 'sanity: the gate is shut');

    // The host's own consent switch moves while the recovery is parked.
    await tester.runAsync(
        () => AdManager().setConsent(const AdConsent(hasUserConsent: true)));
    wedge.complete();
    statusGate = null;
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(adapter.loadBannerCalls, greaterThan(0),
        reason: 'a settings toggle must not leave every banner in the app '
            'blank for the rest of the session');
    expect(tester.takeException(), isNull);
  });

  // Round-15 QC, MAJOR — same consequence one await deeper: the host decision
  // lands while the recovery's own re-apply is in flight, so that re-apply
  // writes nothing and the kick it would have left behind is suppressed.
  testWidgets('banners come back after a host decision lands in the recovery '
      'own re-apply', (tester) async {
    AdManager.debugConsentGateRecoveryRetryDelay =
        const Duration(milliseconds: 20);
    addTearDown(() => AdManager.debugConsentGateRecoveryRetryDelay = null);

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

    privacyOptionsRequirement = _privacyOptionsRequired;
    canRequestAds = true;
    seedTcf({
      'IABTCF_gdprApplies': 1,
      'IABTCF_PurposeConsents': _purposesAllow,
    });
    final stuck = Completer<void>();
    AdManager.debugConsentWriteBarrier = stuck.future;
    final first = AdManager().showPrivacyOptions();
    await tester.pump(const Duration(milliseconds: 50));
    final queued = AdManager().showPrivacyOptions();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
        () => AdManager().setConsent(const AdConsent(hasUserConsent: true)));

    final wedge = Completer<void>();
    statusGate = wedge;
    AdManager.debugConsentWriteBarrier = null;
    stuck.complete();
    await tester.runAsync(() async {
      await first;
      await queued;
    });
    await tester.pump(const Duration(milliseconds: 50));

    // The device now disagrees with what is applied, so the recovery re-applies
    // instead of just reopening — and that re-apply is held at its entry.
    seedTcf({
      'IABTCF_gdprApplies': 1,
      'IABTCF_PurposeConsents': _purposesRefuse,
    });
    final entry = Completer<void>();
    AdManager.debugConsentApplyBarrier = entry.future;
    statusGate = null;
    wedge.complete();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 50));
    expect(adapter.loadBannerCalls, 0, reason: 'sanity: the gate is shut');

    await tester.runAsync(
        () => AdManager().setConsent(const AdConsent(hasUserConsent: true)));
    AdManager.debugConsentApplyBarrier = null;
    entry.complete();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(adapter.loadBannerCalls, greaterThan(0),
        reason: 'a decision landing inside the recovery must not leave every '
            'banner in the app blank for the rest of the session');
    expect(tester.takeException(), isNull);
  });

  // Round-16 QC, MAJOR — at the widget layer: the retry budget was
  // session-global, so once one gate debt had spent all three retries, the
  // NEXT guessed close got none and every banner in the app stayed blank for
  // the rest of the session.
  testWidgets('banners come back for a second gate debt after an older one '
      'gave up', (tester) async {
    AdManager.debugConsentGateRecoveryRetryDelay =
        const Duration(milliseconds: 20);
    addTearDown(() => AdManager.debugConsentGateRecoveryRetryDelay = null);
    addTearDown(() {
      AdManager.debugConsentWriteBarrier = null;
      statusThrows = false;
      statusGate = null;
    });

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

    privacyOptionsRequirement = _privacyOptionsRequired;
    canRequestAds = true;
    seedTcf({
      'IABTCF_gdprApplies': 1,
      'IABTCF_PurposeConsents': _purposesAllow,
    });

    // ── Debt #1, left to burn every retry it has against a dead channel.
    var stuck = Completer<void>();
    AdManager.debugConsentWriteBarrier = stuck.future;
    var first = AdManager().showPrivacyOptions();
    await tester.pump(const Duration(milliseconds: 50));
    var queued = AdManager().showPrivacyOptions();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
        () => AdManager().setConsent(const AdConsent(hasUserConsent: true)));
    // Armed only now: a wedge set any earlier parks the forms, not the
    // recovery.
    statusThrows = true;
    AdManager.debugConsentWriteBarrier = null;
    stuck.complete();
    await tester.runAsync(() async {
      await first;
      await queued;
    });
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(adapter.loadBannerCalls, 0,
        reason: 'sanity: the first debt gave up with the channel still dead');

    // ── The channel comes back and an ordinary decision settles debt #1.
    statusThrows = false;
    await tester.runAsync(() => AdManager().showPrivacyOptions());
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final settled = adapter.loadBannerCalls;
    expect(settled, greaterThan(0), reason: 'sanity: the gate reopened');

    // ── Debt #2, whose own first recovery hits a transient failure.
    stuck = Completer<void>();
    AdManager.debugConsentWriteBarrier = stuck.future;
    first = AdManager().showPrivacyOptions();
    await tester.pump(const Duration(milliseconds: 50));
    queued = AdManager().showPrivacyOptions();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
        () => AdManager().setConsent(const AdConsent(hasUserConsent: true)));
    final broken = Completer<void>();
    statusGate = broken;
    AdManager.debugConsentWriteBarrier = null;
    stuck.complete();
    await tester.runAsync(() async {
      await first;
      await queued;
    });
    await tester.pump(const Duration(milliseconds: 50));
    broken.completeError(StateError('the consent channel is gone'));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 20));

    // The channel comes back. This debt's own first retry must run.
    statusGate = null;
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(adapter.loadBannerCalls, greaterThan(settled),
        reason: 'an older debt that gave up must not leave every banner in '
            'the app blank for the rest of the session');
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
