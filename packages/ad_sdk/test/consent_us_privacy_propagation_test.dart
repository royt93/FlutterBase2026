// Round-25 QC round 21 (`codex`, MAJOR) — the CCPA / US-states opt-out the SDK
// could read but never enforced.
//
// `IabStorage.usPrivacyOptedOut()` has parsed `IABUSPrivacy_String` since the
// round-5 audit (m10), and `AdManager.usPrivacyOptedOut` exposes it — but the
// only writer of `AdConsent.doNotSell` was the host. So a Californian who
// opted out through the app's CMP still had:
//
//   * AppLovin  → `setDoNotSell(false)`
//   * AdMob     → `restricted_data_processing` unset
//
// unless the host separately noticed the string and called `setConsent` itself.
// m10 fixed the compliance *report* and left the enforcement alone; this is the
// enforcement half. Two entry points, matching the TCF reconcile that already
// lives beside them: SDK init (a returning user's opt-out is already on disk)
// and app resume (the user opted out in a CMP or an OS privacy screen while the
// app was backgrounded).
//
// The three CONTROL tests matter as much as the two positives: this must be
// TIGHTEN-ONLY. A missing string (every non-US user) and a string that says
// "did not opt out" are both no authority to clear a `doNotSell` the host set
// deliberately, and neither may cost a user their personalised fill.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/adapters/admob_adapter.dart';
import 'package:applovin_admob_sdk/src/core/iab_storage.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

const _alChannel = MethodChannel('applovin_max');
const _gmaChannel = MethodChannel('plugins.flutter.io/google_mobile_ads');

/// IAB US Privacy string, 4 characters: version, notice, **sale opt-out**,
/// LSPA. Index 2 is the one that decides.
const _optedOut = '1YYN';
const _notOptedOut = '1YNN';

class _StubAdapter implements AdProviderAdapter {
  final List<AdConsent> applied = <AdConsent>[];

  @override
  void applyConsent(AdConsent consent) => applied.add(consent);

  @override
  Future<bool> initialize(
    AdConfig config, {
    String deviceGaid = '',
    bool isAgeRestrictedUser = false,
    AdConsent? consent,
  }) async =>
      true;

  @override
  String get tag => 'stub';

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
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// Every `setDoNotSell` that actually crossed the AppLovin method channel.
  late List<bool> doNotSellCalls;

  /// Seeds the platform's *default* store — the one a CMP writes and
  /// [IabStorage] reads (see its doc on which store and why).
  void seedIab(Map<String, Object> data) {
    IabStorage.debugResetForTest();
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData(data);
  }

  late _StubAdapter initAdapter;

  setUp(() async {
    doNotSellCalls = <bool>[];
    initAdapter = _StubAdapter();
    AdManager.debugAdapterFactory = (_) => initAdapter;
    messenger.setMockMethodCallHandler(_alChannel, (call) async {
      if (call.method == 'setDoNotSell') {
        doNotSellCalls
            .add((call.arguments as Map)['value'] as bool? ?? false);
      }
      if (call.method == 'initialize') return <String, dynamic>{};
      return null;
    });
    messenger.setMockMethodCallHandler(_gmaChannel, (call) async => null);
    await AdManager().destroy();
    AdPreferences.resetForTest();
    ConsentManager.resetForTest();
    SharedPreferences.setMockInitialValues({});
    seedIab(<String, Object>{});
  });

  tearDown(() async {
    AdManager.debugAdapterFactory = null;
    AdManager().debugSetAdapter(null);
    AdManager().debugConfig = null;
    await AdManager().destroy();
    messenger.setMockMethodCallHandler(_alChannel, null);
    messenger.setMockMethodCallHandler(_gmaChannel, null);
    seedIab(<String, Object>{});
  });

  Future<void> initSdk({AdProvider provider = AdProvider.appLovin}) async {
    await AdManager().initialize(
      config: AdConfig(
        provider: provider,
        admob: const AdMobConfig(
          bannerId: 'ca-app-pub-3940256099942544/1111111111',
          interstitialId: 'ca-app-pub-3940256099942544/2222222222',
          appOpenId: 'ca-app-pub-3940256099942544/3333333333',
          rewardedId: 'ca-app-pub-3940256099942544/4444444444',
        ),
        appLovin: const AppLovinConfig(
          sdkKey: 'test-sdk-key',
          bannerId: 'banner-id',
          interstitialId: 'interstitial-id',
          appOpenId: 'appopen-id',
          rewardedId: 'rewarded-id',
        ),
        safety: const AdSafetyParams(dryRun: true),
        autoRequestUmpConsent: false,
      ),
      onComplete: (_, __) {},
    );
  }

  group('init carries the device sale opt-out to both providers', () {
    test('IABUSPrivacy_String says opted out → doNotSell applied', () async {
      seedIab(<String, Object>{IabStorage.keyUsPrivacy: _optedOut});

      await initSdk();
      await pumpEventQueue(times: 20);

      expect(AdManager().consent.doNotSell, isTrue,
          reason: 'the user opted out of sale through the CMP before this '
              'launch; the SDK read that string and used to keep serving '
              'ads with no CCPA signal on them');
      expect(await AdManager().usPrivacyOptedOut, isTrue,
          reason: 'sanity: the reported value and the applied value must be '
              'the same thing — m10 fixed only the report');
      expect(doNotSellCalls, contains(true),
          reason: 'AppLovin must be told over its own channel, not just in '
              'our cache');
      expect(initAdapter.applied.last.doNotSell, isTrue,
          reason: 'the adapter is what turns this into AdMob RDP on every '
              'request — see the last test in this file');
    });

    test('CONTROL — a string that says "did not opt out" changes nothing',
        () async {
      seedIab(<String, Object>{IabStorage.keyUsPrivacy: _notOptedOut});

      await initSdk();
      await pumpEventQueue(times: 20);

      expect(AdManager().consent.doNotSell, isFalse,
          reason: 'index 2 is `N`. Reading that as an opt-out would cost '
              'every US user their personalised fill');
      expect(doNotSellCalls, isNot(contains(true)));
    });

    test('CONTROL — no string at all (the non-US case) changes nothing',
        () async {
      seedIab(<String, Object>{});

      await initSdk();
      await pumpEventQueue(times: 20);

      expect(AdManager().consent.doNotSell, isFalse,
          reason: '`null` means no CMP wrote a US Privacy string — the normal '
              'case outside the US, and not a signal of anything');
    });
  });

  group('resume carries an opt-out made while backgrounded', () {
    test('a sale opt-out written while backgrounded is applied on resume',
        () async {
      await initSdk();
      expect(AdManager().consent.doNotSell, isFalse, reason: 'sanity');

      final adapter = _StubAdapter();
      AdManager().debugSetAdapter(adapter);
      doNotSellCalls.clear();

      // The user opens the CMP (or the OS privacy screen) and opts out while
      // our process is in the background. No callback of ours ever fires —
      // the string on disk is the only evidence.
      seedIab(<String, Object>{IabStorage.keyUsPrivacy: _optedOut});

      AdManager().didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue(times: 50);

      expect(AdManager().consent.doNotSell, isTrue);
      expect(adapter.applied.last.doNotSell, isTrue,
          reason: 'the provider itself has to be told');
      expect(doNotSellCalls, contains(true));
    });

    test('CONTROL — an opt-out already applied is not re-applied on resume',
        () async {
      seedIab(<String, Object>{IabStorage.keyUsPrivacy: _optedOut});
      await initSdk();
      await pumpEventQueue(times: 20);
      expect(AdManager().consent.doNotSell, isTrue, reason: 'sanity');

      final adapter = _StubAdapter();
      AdManager().debugSetAdapter(adapter);

      AdManager().didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue(times: 50);

      expect(adapter.applied, isEmpty,
          reason: 'every resume must not rewrite consent and discard the ads '
              'already loaded under the correct, identical state');
    });

    test('CONTROL — the device never CLEARS a doNotSell the host set',
        () async {
      await initSdk();
      await AdManager()
          .setConsent(const AdConsent(hasUserConsent: true, doNotSell: true));
      expect(AdManager().consent.doNotSell, isTrue, reason: 'sanity');

      // The host's own switch is a newer, deliberate decision than whatever a
      // CMP left on disk. Tighten-only: this direction is never honoured.
      seedIab(<String, Object>{IabStorage.keyUsPrivacy: _notOptedOut});

      AdManager().didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue(times: 50);

      expect(AdManager().consent.doNotSell, isTrue,
          reason: 'a host that opted the user out — a settings toggle, a '
              'purchase flow — must not be overruled by an absent or '
              'negative device string');
    });
  });

  // The two groups above stop at `AdProviderAdapter.applyConsent`, because
  // that is where the SDK's own responsibility ends. This closes the chain on
  // the real adapter: the same call is what puts `restricted_data_processing`
  // on every AdMob request.
  test('AdMobAdapter turns an applied doNotSell into RDP', () {
    final adapter = AdMobAdapter();
    adapter.applyConsent(const AdConsent(hasUserConsent: true));
    expect(adapter.debugRestrictedDataProcessing, isFalse, reason: 'sanity');
    adapter
        .applyConsent(const AdConsent(hasUserConsent: true, doNotSell: true));
    expect(adapter.debugRestrictedDataProcessing, isTrue);
  });
}
