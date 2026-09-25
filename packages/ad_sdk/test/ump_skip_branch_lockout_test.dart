// Regression test for the UMP consent skip-branch permanent ad lockout.
//
// Real host order (documented in requestUmpConsent()'s own docstring): the
// host calls requestUmpConsent() itself in splash BEFORE initialize(). When
// initialize() then runs with autoRequestUmpConsent:true (the default), its
// auto-UMP block sets `_canRequestAds = false` (closing the gate until UMP
// resolves) and calls requestUmpConsent(skipIfAlreadyRequested: true) — which
// hits the early-return skip branch since `_umpRequested` is already true
// from the host's earlier manual call.
//
// Before the fix, that skip branch returned the cached UmpConsentResult
// WITHOUT restoring `_canRequestAds` from it — so the gate initialize() had
// just forced closed stayed closed forever, permanently blocking every ad
// load for the rest of the process, even though the host's own UMP call
// had `canRequestAds: true`.
//
// Same fake-channel setup as consent_persistence_on_init_test.dart (AppLovin
// provider — AdMobAdapter needs far more native state than a method channel
// can fake under `flutter test`).

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mobile_ads/src/ump/user_messaging_codec.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _alChannel = MethodChannel('applovin_max');

final _umpChannel = MethodChannel(
  'plugins.flutter.io/google_mobile_ads/ump',
  StandardMethodCodec(UserMessagingCodec()),
);

// applyConsentToProviders() touches MobileAds.instance regardless of the
// active provider — see consent_persistence_on_init_test.dart's comment on
// this same channel for why it must be mocked even for an AppLovin config.
const _gmaChannel = MethodChannel('plugins.flutter.io/google_mobile_ads');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUpAll(() {
    messenger.setMockMethodCallHandler(_alChannel, (call) async {
      if (call.method == 'initialize') return <String, dynamic>{};
      return null;
    });
    messenger.setMockMethodCallHandler(_gmaChannel, (call) async => null);
    messenger.setMockMethodCallHandler(_umpChannel, (call) {
      switch (call.method) {
        case 'ConsentInformation#requestConsentInfoUpdate':
          return Future.value(null);
        case 'ConsentInformation#canRequestAds':
          // Host's own manual UMP call reports consent obtained.
          return Future.value(true);
        case 'ConsentInformation#getConsentStatus':
          return Future.value(3); // obtained
        case 'ConsentInformation#isConsentFormAvailable':
          return Future.value(false);
        default:
          return Future.value(null);
      }
    });
  });

  tearDownAll(() {
    messenger.setMockMethodCallHandler(_alChannel, null);
    messenger.setMockMethodCallHandler(_gmaChannel, null);
    messenger.setMockMethodCallHandler(_umpChannel, null);
  });

  setUp(() async {
    await AdManager().destroy();
    AdPreferences.resetForTest();
    ConsentManager.resetForTest();
  });

  tearDown(() async {
    await AdManager().destroy();
  });

  test(
      'host calling requestUmpConsent() before initialize() does not '
      'permanently lock canRequestAds false via the auto-UMP skip branch',
      () async {
    SharedPreferences.setMockInitialValues({});

    // Real host pattern: call requestUmpConsent() manually first, exactly
    // as the SDK's own docstring recommends.
    final hostResult = await AdManager().requestUmpConsent();
    expect(hostResult.canRequestAds, isTrue,
        reason: 'the fake UMP channel reports consent obtained');
    expect(AdManager().canRequestAds, isTrue);

    // initialize() with autoRequestUmpConsent:true (the default) now runs:
    // its auto-UMP block force-closes the gate (_canRequestAds = false),
    // then calls requestUmpConsent(skipIfAlreadyRequested: true) — which
    // must hit the skip branch (host already requested) and restore the
    // gate from the cached result instead of leaving it stuck closed.
    await AdManager().initialize(
      config: const AdConfig(
        provider: AdProvider.appLovin,
        appLovin: AppLovinConfig(
          sdkKey: 'test-sdk-key',
          bannerId: 'banner-id',
          interstitialId: 'interstitial-id',
          appOpenId: 'appopen-id',
          rewardedId: 'rewarded-id',
        ),
        safety: AdSafetyParams(dryRun: true),
      ),
      onComplete: (_, _) {},
    );

    expect(AdManager().isInitialised, isTrue,
        reason: 'adapter init must have actually succeeded for this test '
            'to prove anything about the post-skip gate state');
    expect(AdManager().canRequestAds, isTrue,
        reason: 'the skip branch must restore _canRequestAds from the '
            'cached UMP result, not leave it stuck at the false '
            'initialize() force-closed it to — otherwise a host that '
            'follows the SDK\'s own documented "call requestUmpConsent() '
            'before initialize()" pattern gets permanently locked out of '
            'every ad load for the rest of the process');
  });
}
