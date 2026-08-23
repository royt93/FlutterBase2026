// B1 (independent review of round 5) — withdrawing personalisation must
// invalidate ads that were already loaded under the old consent.
//
// The original MJ6 fix compared `_consent.hasUserConsent` against the incoming
// value inside `_syncConsentToAdapter`. That could never be true: `setConsent`
// assigns `_consent` first and only then calls `ConsentManager.set()`, whose
// `ValueNotifier` notifies listeners SYNCHRONOUSLY — so the listener always saw
// the new value on both sides. Every withdrawal route goes through exactly that
// sequence (`showPrivacyOptions()`, `requestUmpConsent()`, a host's own
// `setConsent`), so cached personalised fullscreen ads were still shown and
// banners kept refreshing, while the CHANGELOG claimed otherwise.
//
// 905 tests passed over that. This one fails without the fix.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _alChannel = MethodChannel('applovin_max');
const _gmaChannel = MethodChannel('plugins.flutter.io/google_mobile_ads');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() async {
    messenger.setMockMethodCallHandler(_alChannel, (call) async {
      if (call.method == 'initialize') return <String, dynamic>{};
      return null;
    });
    messenger.setMockMethodCallHandler(_gmaChannel, (call) async => null);
    await AdManager().destroy();
    AdPreferences.resetForTest();
    ConsentManager.resetForTest();
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await AdManager().destroy();
    messenger.setMockMethodCallHandler(_alChannel, null);
    messenger.setMockMethodCallHandler(_gmaChannel, null);
  });

  Future<void> initSdk() async {
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
        autoRequestUmpConsent: false,
        autoShowConsentDialog: false,
      ),
      onComplete: (_, __) {},
    );
    expect(AdManager().isInitialised, isTrue);
  }

  test('granting then withdrawing consent signals inline ads to rebuild',
      () async {
    await initSdk();
    await AdManager().setConsent(const AdConsent(hasUserConsent: true));

    final before = AdManager().personalisationRevision.value;

    await AdManager().setConsent(const AdConsent(hasUserConsent: false));

    expect(AdManager().personalisationRevision.value, greaterThan(before),
        reason: 'withdrawal must notify the inline ad widgets. Comparing '
            'against `_consent` here always read the NEW value on both sides '
            '(ConsentManager notifies synchronously, after setConsent has '
            'already assigned it), so this never fired.');
  });

  test('re-applying the SAME consent is not treated as a withdrawal', () async {
    await initSdk();
    await AdManager().setConsent(const AdConsent(hasUserConsent: false));

    final before = AdManager().personalisationRevision.value;
    await AdManager().setConsent(const AdConsent(hasUserConsent: false));

    expect(AdManager().personalisationRevision.value, before,
        reason: 'idempotent re-apply must not throw away good ads — the flag '
            'has to track a transition, not a value');
  });

  test('granting consent is never a withdrawal', () async {
    await initSdk();
    await AdManager().setConsent(const AdConsent(hasUserConsent: false));

    final before = AdManager().personalisationRevision.value;
    await AdManager().setConsent(const AdConsent(hasUserConsent: true));

    expect(AdManager().personalisationRevision.value, before);
  });

  // B1 (round-6 audit) — the guard above tracked exactly ONE of the three
  // axes a consent state can tighten along. `doNotSell` and
  // `isAgeRestrictedUser` were both left out, so a CCPA opt-out or a COPPA
  // flag flipped mid-session kept serving ads that were requested under the
  // looser consent. COPPA is the stricter axis of the two and had the weaker
  // protection.
  test('a CCPA opt-out mid-session invalidates ads loaded without rdp',
      () async {
    await initSdk();
    await AdManager().setConsent(
        const AdConsent(hasUserConsent: true, doNotSell: false));

    final before = AdManager().personalisationRevision.value;

    await AdManager().setConsent(
        const AdConsent(hasUserConsent: true, doNotSell: true));

    expect(AdManager().personalisationRevision.value, greaterThan(before),
        reason: 'the cached fullscreen ad and the mounted inline ads were '
            'requested WITHOUT the restricted-data-processing signal; opting '
            'out only for future requests leaves the old ones playing');
  });

  test('turning on the child-directed flag mid-session invalidates ads',
      () async {
    await initSdk();
    await AdManager().setConsent(
        const AdConsent(hasUserConsent: true, isAgeRestrictedUser: false));

    final before = AdManager().personalisationRevision.value;

    await AdManager().setConsent(
        const AdConsent(hasUserConsent: true, isAgeRestrictedUser: true));

    expect(AdManager().personalisationRevision.value, greaterThan(before),
        reason: 'a user just declared under 13 must not keep receiving the '
            'non-child-directed ads already in the cache');

    // Flipping the COPPA flag also kicks off the provider re-init path (M2),
    // which is fire-and-forget. Let it finish here, otherwise it lands in the
    // MIDDLE of the next test's initSdk() and that one fails on
    // `isInitialised` for reasons that have nothing to do with what it asserts.
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });

  test('clearing the CCPA opt-out is not a withdrawal', () async {
    await initSdk();
    await AdManager().setConsent(
        const AdConsent(hasUserConsent: true, doNotSell: true));

    final before = AdManager().personalisationRevision.value;
    await AdManager().setConsent(
        const AdConsent(hasUserConsent: true, doNotSell: false));

    expect(AdManager().personalisationRevision.value, before,
        reason: 'loosening must not throw away good ads — each axis has to '
            'track a tightening transition, not just a change');
  });

  test('clearing the child-directed flag is not a withdrawal', () async {
    await initSdk();
    await AdManager().setConsent(
        const AdConsent(hasUserConsent: true, isAgeRestrictedUser: true));

    final before = AdManager().personalisationRevision.value;
    await AdManager().setConsent(
        const AdConsent(hasUserConsent: true, isAgeRestrictedUser: false));

    expect(AdManager().personalisationRevision.value, before);
  });
}
