// Round-21 QC (codex), BLOCKER — the init reconcile hands its re-apply to
// `_recoverConsentGate`, whose offline branch used to RE-READ the IAB TCF keys
// to establish a refusal the reconcile had already read a moment earlier. That
// second read can throw or come back `null` (a storage error, or `gdprApplies`
// cleared under us), and `null` means "assume allowed" — so with UMP
// unreachable AND that read failing, the withdrawal was silently dropped and
// both providers kept serving personalised ads under the user's refusal for the
// whole session.
//
// `knownTcfRefusal: true` carries the fact from the reconcile into the recovery
// (and into its bounded retry), so the offline path needs no second read at all.
//
// Provider is AppLovin, not AdMob, for the same reason as
// consent_persistence_on_init_test.dart: AdMobAdapter.initialize() needs far
// more native state than a mock channel can fake, so it can never succeed in a
// plain `flutter test` run, and the reconcile runs after adapter init.

import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:applovin_admob_sdk/src/core/iab_storage.dart';
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

/// A rejected personalisation purpose (purpose 3 off) — see
/// IabStorage.tcfAllowsPersonalisedAds.
const String _purposesRefuse = '1010000000';

AdConfig _appLovinConfig() => const AdConfig(
      provider: AdProvider.appLovin,
      autoRequestUmpConsent: false,
      appLovin: AppLovinConfig(
        sdkKey: 'test-sdk-key',
        bannerId: 'banner-id',
        interstitialId: 'interstitial-id',
        appOpenId: 'appopen-id',
        rewardedId: 'rewarded-id',
      ),
      safety: AdSafetyParams(dryRun: true),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// Wedges `getConsentStatus`, so the recovery's UMP read can be held open
  /// while the TCF keys are cleared underneath it and then failed — the exact
  /// shape of an offline device whose storage read also comes back empty.
  Completer<int>? statusGate;

  /// Writes the real IAB TCF keys where a CMP would, in the platform store
  /// IabStorage reads from — the same seam tcf_personalisation_consent_test
  /// uses.
  void seedTcf(Map<String, Object> data) {
    IabStorage.debugResetForTest();
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData(data);
  }

  setUp(() async {
    statusGate = null;
    messenger.setMockMethodCallHandler(_alChannel, (call) async {
      if (call.method == 'initialize') return <String, dynamic>{};
      return null;
    });
    messenger.setMockMethodCallHandler(_gmaChannel, (call) async => null);
    messenger.setMockMethodCallHandler(_umpChannel, (call) {
      switch (call.method) {
        case 'ConsentInformation#canRequestAds':
          return Future.value(true);
        case 'ConsentInformation#getConsentStatus':
          final gate = statusGate;
          if (gate != null) return gate.future;
          return Future.value(3); // obtained
        case 'ConsentInformation#isConsentFormAvailable':
          return Future.value(false);
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
    await AdManager().destroy();
    messenger.setMockMethodCallHandler(_alChannel, null);
    messenger.setMockMethodCallHandler(_gmaChannel, null);
    messenger.setMockMethodCallHandler(_umpChannel, null);
  });

  test(
      'an offline init reconcile applies the withdrawal even when the second '
      'TCF read comes back empty', () async {
    // A CMP recorded the refusal on the device; the value carried into this
    // launch (persisted, or set by the host's splash) still says granted.
    seedTcf({
      'IABTCF_gdprApplies': 1,
      'IABTCF_PurposeConsents': _purposesRefuse,
    });
    await AdManager().setConsent(const AdConsent(hasUserConsent: true));

    // UMP is unreachable — but not instantly: held open so the TCF keys can go
    // away while the recovery is parked on it.
    final wedge = Completer<int>();
    addTearDown(() {
      if (!wedge.isCompleted) wedge.completeError(StateError('torn down'));
    });
    statusGate = wedge;

    await AdManager().initialize(
        config: _appLovinConfig(), onComplete: (_, _) {});
    await pumpEventQueue(times: 20);

    expect(AdManager().canRequestAds, isFalse,
        reason: 'sanity: the reconcile saw the device refuse and gated ads '
            'until the refusal is re-applied');

    // The keys are gone by the time anyone would look again, and the channel
    // fails: nothing but what the reconcile already read says "do not
    // personalise".
    seedTcf({});
    wedge.completeError(StateError('the consent channel is gone'));
    await pumpEventQueue(times: 50);

    expect(AdManager().consent.hasUserConsent, isFalse,
        reason: 'the refusal was read off the device before the recovery was '
            'handed the re-apply; UMP being unreachable and a storage read '
            'coming back empty afterwards cannot turn it back into consent');
  });
}
