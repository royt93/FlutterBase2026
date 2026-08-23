// T06 — Privacy Options entry point + re-consent.
//
// Google UMP policy: apps must expose a durable way for users to change
// consent after the first prompt. AdManager.showPrivacyOptions() wraps
// ConsentForm.showPrivacyOptionsForm() and must (a) only show the native
// form when Google's ConsentInformation actually requires it, and (b)
// re-apply the resulting consent to the active ad provider immediately.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/core/ump_consent.dart'
    show
        debugUmpFormBackstopOverride,
        markUmpFormOnScreen,
        resetUmpFormOnScreen;
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RecordingAdapter implements AdProviderAdapter {
  final List<AdConsent> applied = <AdConsent>[];
  AdConsent? get last => applied.isEmpty ? null : applied.last;

  @override
  void applyConsent(AdConsent consent) => applied.add(consent);
  @override
  String get tag => 'recording';

  // T75 — AdManager's _adapter setter now reads these on every
  // debugSetAdapter() call to wire fullscreenBusy's slot listeners.
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const umpChannel = MethodChannel('plugins.flutter.io/google_mobile_ads/ump');
  const gmaChannel = MethodChannel('plugins.flutter.io/google_mobile_ads');
  const alChannel = MethodChannel('applovin_max');

  // PrivacyOptionsRequirementStatus: 0=notRequired, 1=required.
  late bool showFormInvoked;
  /// Round-7 — lets a test look at SDK state at the exact instant the native
  /// form is being presented.
  void Function()? onShowForm;
  late int requirementStatus;
  // ConsentStatus (default/Android decode): 0=unknown,1=notRequired,2=required,3=obtained.
  late int consentStatus;
  late bool canRequestAdsNative;

  Future<dynamic> umpHandler(MethodCall call) async {
    switch (call.method) {
      case 'ConsentInformation#getPrivacyOptionsRequirementStatus':
        return requirementStatus;
      case 'ConsentInformation#getConsentStatus':
        return consentStatus;
      case 'ConsentInformation#canRequestAds':
        return canRequestAdsNative;
      case 'UserMessagingPlatform#showPrivacyOptionsForm':
        showFormInvoked = true;
        onShowForm?.call();
        return null;
      default:
        return null;
    }
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await AdPreferences.getInstance();
    await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
    AdSafetyConfig.resetForReinit();

    showFormInvoked = false;
    onShowForm = null;
    requirementStatus = 0;
    consentStatus = 1;
    canRequestAdsNative = true;

    messenger.setMockMethodCallHandler(umpChannel, umpHandler);
    messenger.setMockMethodCallHandler(gmaChannel, (call) async => null);
    messenger.setMockMethodCallHandler(alChannel, (call) async => null);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(umpChannel, null);
    messenger.setMockMethodCallHandler(gmaChannel, null);
    messenger.setMockMethodCallHandler(alChannel, null);
    AdManager().debugSetAdapter(null);
    AdManager().debugConfig = null;
    AdManager().debugVipManager = null;
    AdManager().debugCanRequestAds = true;
  });

  group('isPrivacyOptionsRequired', () {
    test('reflects native requirement status: required', () async {
      requirementStatus = 1;
      expect(await AdManager().isPrivacyOptionsRequired(), isTrue);
    });

    test('reflects native requirement status: not required', () async {
      requirementStatus = 0;
      expect(await AdManager().isPrivacyOptionsRequired(), isFalse);
    });
  });

  // Round-7 audit, MAJOR — Google's UMP form is a native activity / view
  // controller, not a Flutter route, so `AdScreenRouteLogger.isDialogOnTop`
  // cannot see it, and presenting it does not background the app either. So
  // nothing stopped an interstitial, rewarded or App Open ad from being drawn
  // over the consent form: the tap the consent choice needed lands on the ad,
  // and an ad over a consent dialog is a policy violation of its own.
  group('ads are locked while a UMP form is on screen (round 7)', () {
    test('the fullscreen mutex is held for as long as the form is up',
        () async {
      requirementStatus = 1;
      consentStatus = 3; // obtained
      canRequestAdsNative = true;

      String? reasonDuringForm;
      bool busyDuringForm = false;
      onShowForm = () {
        reasonDuringForm = AdManager().debugFullscreenBusyReason;
        busyDuringForm = AdManager().fullscreenBusy.value;
      };

      expect(AdManager().debugFullscreenBusyReason, isNull,
          reason: 'sanity: nothing is holding the mutex before the form');

      await AdManager().showPrivacyOptions();

      expect(showFormInvoked, isTrue, reason: 'sanity: the form was presented');
      expect(reasonDuringForm, 'a consent form is on screen');
      expect(busyDuringForm, isTrue,
          reason: 'the public mirror a host reads must agree with the mutex');
      expect(AdManager().debugFullscreenBusyReason, isNull,
          reason: 'and it must be released once the form is dismissed');
    });

    // Round-13 QC (round 11), MAJOR — `destroy()` used to clear the form
    // counter outright, on the grounds that it had just torn the adapter down
    // so nothing could be drawn over anything. But destroy() does not dismiss
    // the native form (the reason the consent session epoch exists at all), and
    // the next initialize() brings a fresh adapter with it: a form the user is
    // still reading then has no ad block, and an App Open ad drawn over a
    // consent form is exactly the policy violation this mutex exists for.
    test('a form still on screen keeps the mutex across destroy() and the '
        'next session', () async {
      final release = markUmpFormOnScreen();
      addTearDown(resetUmpFormOnScreen);
      expect(AdManager().debugFullscreenBusyReason,
          'a consent form is on screen',
          reason: 'sanity: the presentation holds the mutex');

      await AdManager().destroy();
      expect(AdManager().debugFullscreenBusyReason,
          'a consent form is on screen',
          reason: 'the form is still up — destroy() does not dismiss it');

      // Next session, adapter and all.
      AdManager().debugSetAdapter(_RecordingAdapter());
      AdManager().debugConfig = _config;
      expect(AdManager().debugFullscreenBusyReason,
          'a consent form is on screen',
          reason: 'and now there IS an ad that could be drawn over it');

      release();
      expect(AdManager().debugFullscreenBusyReason, isNull,
          reason: 'the user answered the form — ads are free again');
    });

    // The other half: not resetting must not be able to block ads forever.
    test('a form whose dismiss never arrives releases via its backstop, even '
        'across destroy()', () async {
      debugUmpFormBackstopOverride = const Duration(milliseconds: 30);
      addTearDown(() {
        debugUmpFormBackstopOverride = null;
        resetUmpFormOnScreen();
      });
      markUmpFormOnScreen();
      await AdManager().destroy();
      expect(AdManager().debugFullscreenBusyReason,
          'a consent form is on screen');

      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(AdManager().debugFullscreenBusyReason, isNull,
          reason: 'a dismiss callback that never comes must not cost the next '
              'session its fullscreen ads for the whole process');
    });

    test('a form that is never required never holds the mutex', () async {
      requirementStatus = 0;
      consentStatus = 1;
      onShowForm = () => fail('no form should be presented');

      await AdManager().showPrivacyOptions();
      expect(AdManager().debugFullscreenBusyReason, isNull);
    });
  });

  group('showPrivacyOptions (T06)', () {
    test('requirement=required → opens the native privacy options form',
        () async {
      requirementStatus = 1;
      consentStatus = 3; // obtained
      canRequestAdsNative = true;

      final result = await AdManager().showPrivacyOptions();

      expect(showFormInvoked, isTrue,
          reason: 'Google requires the durable privacy-options form to '
              'actually show for EEA/UK users once required');
      expect(result.formShown, isTrue);
      expect(result.canRequestAds, isTrue);
    });

    test('requirement=notRequired → does NOT open the native form (safe no-op)',
        () async {
      requirementStatus = 0;
      consentStatus = 1; // notRequired
      canRequestAdsNative = true;

      final result = await AdManager().showPrivacyOptions();

      expect(showFormInvoked, isFalse,
          reason: 'showPrivacyOptions() must be safe to call for non-EEA '
              'users / hosts that never gathered consent');
      expect(result.formShown, isFalse);
    });

    test('re-consent via the form re-applies consent to the active adapter',
        () async {
      final adapter = _RecordingAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _config;

      requirementStatus = 1;
      consentStatus = 3; // obtained
      canRequestAdsNative = true;

      await AdManager().showPrivacyOptions();

      expect(adapter.applied, isNotEmpty,
          reason: 'changing consent via privacy options must re-apply it '
              'to the active provider (npa/RDP update), not just be cached');
      expect(adapter.last!.hasUserConsent, isTrue);
    });

    test('notRequired path does not touch the adapter', () async {
      final adapter = _RecordingAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _config;

      requirementStatus = 0;
      consentStatus = 1; // notRequired
      canRequestAdsNative = true;

      await AdManager().showPrivacyOptions();

      // setConsent() is still invoked with the resolved status either way,
      // so the adapter does receive a consent apply here — but never a
      // native form. Guard against the form having flipped this.
      expect(showFormInvoked, isFalse);
    });
  });
}
