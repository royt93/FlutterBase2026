import 'dart:async';

import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../utils/safe_logger.dart';

/// Result of [requestUmpConsentFlow].
class UmpConsentResult {
  const UmpConsentResult({
    required this.canRequestAds,
    required this.status,
    this.error,
    this.formShown = false,
  });

  /// Whether ads can be requested with the gathered consent. Equivalent to
  /// `ConsentInformation.canRequestAds()` after the form interaction.
  ///
  /// **In a non-EEA market** this is almost always `true` immediately —
  /// `notRequired` status implies the user doesn't need to consent to anything
  /// (still respect COPPA / CCPA via [AdManager.setConsent] separately).
  final bool canRequestAds;

  /// Final consent status from Google's UMP after the optional form interaction.
  final ConsentStatus status;

  /// Non-null if any step (info update / form load / form show) errored.
  /// The flow is best-effort: if [canRequestAds] is `true` you can still
  /// proceed with ad initialization despite a non-null [error].
  final String? error;

  /// True if the consent form was actually presented to the user during
  /// this call (vs. cached / not required).
  final bool formShown;

  bool get isObtained => status == ConsentStatus.obtained;
  bool get isRequired => status == ConsentStatus.required;
  bool get isNotRequired => status == ConsentStatus.notRequired;

  @override
  String toString() => 'UmpConsentResult(canRequestAds=$canRequestAds, '
      'status=${status.name}, formShown=$formShown, error=$error)';
}

/// Opt-in UMP (User Messaging Platform) flow for AdMob compliance.
///
/// This wraps Google's `ConsentInformation` + `ConsentForm` (built into
/// `google_mobile_ads` 6.x — no extra dependency) into a single async call:
///
/// ```dart
/// final r = await AdManager().requestUmpConsent(
///   testMode: kDebugMode,
///   debugGeography: DebugGeography.debugGeographyEea,
///   testIdentifiers: ['<hashed-device-id>'],
/// );
/// if (r.canRequestAds) {
///   await AdManager().initialize(config: ...);
/// }
/// ```
///
/// **Where to call**: before [AdManager.initialize] in your splash screen.
/// AdMob policy says you must show the form *before* the first ad request
/// for EEA/UK users. Calling after init may result in non-compliant
/// impressions.
///
/// **Idempotent**: status is cached across app sessions. Subsequent calls
/// return the cached `canRequestAds` immediately unless the user is in an
/// EEA region with status==required and the form is available.
///
/// **iOS ATT note**: this flow does NOT show the iOS App Tracking
/// Transparency prompt. Show ATT separately via the
/// `app_tracking_transparency` package (Apple requires it on every iOS
/// install regardless of region).
Future<UmpConsentResult> requestUmpConsentFlow({
  bool testMode = false,
  DebugGeography? debugGeography,
  List<String> testIdentifiers = const [],
  bool tagForUnderAgeOfConsent = false,
}) async {
  const tag = 'UmpConsent';

  ConsentDebugSettings? debug;
  if (testMode) {
    debug = ConsentDebugSettings(
      debugGeography: debugGeography,
      testIdentifiers: testIdentifiers,
    );
  }
  final params = ConsentRequestParameters(
    tagForUnderAgeOfConsent: tagForUnderAgeOfConsent,
    consentDebugSettings: debug,
  );

  // Step 1 — request info update.
  final updateCompleter = Completer<String?>();
  ConsentInformation.instance.requestConsentInfoUpdate(
    params,
    () => updateCompleter.complete(null),
    (FormError err) => updateCompleter.complete('${err.errorCode}:${err.message}'),
  );
  final updateError = await updateCompleter.future;
  if (updateError != null) {
    SafeLogger.w(tag, 'requestConsentInfoUpdate failed: $updateError');
    final canShow = await ConsentInformation.instance.canRequestAds();
    final st = await ConsentInformation.instance.getConsentStatus();
    return UmpConsentResult(
      canRequestAds: canShow,
      status: st,
      error: updateError,
    );
  }

  final status = await ConsentInformation.instance.getConsentStatus();
  SafeLogger.d(tag, () => 'consent status: ${status.name}');

  // Step 2 — if a form is available, load + show. We try regardless of
  // status because:
  //  - notRequired/obtained: form rarely available, no-op
  //  - required: form expected, must show before first ad
  bool formShown = false;
  String? formError;
  final available = await ConsentInformation.instance.isConsentFormAvailable();
  if (available) {
    final dismissCompleter = Completer<String?>();
    ConsentForm.loadConsentForm(
      (ConsentForm form) {
        try {
          form.show((FormError? err) {
            dismissCompleter.complete(err == null
                ? null
                : '${err.errorCode}:${err.message}');
          });
          formShown = true;
        } catch (e) {
          dismissCompleter.complete('show threw: $e');
        }
      },
      (FormError err) => dismissCompleter.complete(
          'load failed: ${err.errorCode}:${err.message}'),
    );
    formError = await dismissCompleter.future;
    if (formError != null) {
      SafeLogger.w(tag, 'consent form: $formError');
    }
  } else {
    SafeLogger.d(tag, 'consent form not available — skip');
  }

  final finalStatus = await ConsentInformation.instance.getConsentStatus();
  final canRequest = await ConsentInformation.instance.canRequestAds();
  SafeLogger.d(tag,
      () => '✅ done canRequestAds=$canRequest status=${finalStatus.name} formShown=$formShown');

  return UmpConsentResult(
    canRequestAds: canRequest,
    status: finalStatus,
    error: formError,
    formShown: formShown,
  );
}
