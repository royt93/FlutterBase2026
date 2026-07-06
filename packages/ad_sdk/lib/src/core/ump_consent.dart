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
/// `google_mobile_ads` ^7.0.0 — no extra dependency) into a single async call:
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
    (FormError err) =>
        updateCompleter.complete('${err.errorCode}:${err.message}'),
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
            dismissCompleter.complete(
                err == null ? null : '${err.errorCode}:${err.message}');
          });
          formShown = true;
        } catch (e) {
          dismissCompleter.complete('show threw: $e');
        }
      },
      (FormError err) => dismissCompleter
          .complete('load failed: ${err.errorCode}:${err.message}'),
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
  SafeLogger.d(
      tag,
      () =>
          '✅ done canRequestAds=$canRequest status=${finalStatus.name} formShown=$formShown');

  return UmpConsentResult(
    canRequestAds: canRequest,
    status: finalStatus,
    error: formError,
    formShown: formShown,
  );
}

/// Result of [requestPrivacyOptionsFlow].
class PrivacyOptionsResult {
  const PrivacyOptionsResult({
    required this.canRequestAds,
    required this.status,
    this.error,
    this.formShown = false,
  });

  /// Whether ads can be requested after the privacy options interaction.
  final bool canRequestAds;

  /// Final consent status from Google's UMP after the interaction.
  final ConsentStatus status;

  /// Non-null if the form failed to load/show. Best-effort: [canRequestAds]
  /// still reflects the last-known consent even when this is non-null.
  final String? error;

  /// True if the native privacy options form was actually presented (vs.
  /// skipped because Google doesn't require it for this user).
  final bool formShown;

  bool get isObtained => status == ConsentStatus.obtained;

  @override
  String toString() => 'PrivacyOptionsResult(canRequestAds=$canRequestAds, '
      'status=${status.name}, formShown=$formShown, error=$error)';
}

/// Whether Google requires this app to expose a durable "Privacy Options"
/// entry point (e.g. a settings button) to the current user — true for
/// EEA/UK users under UMP once initial consent has been gathered.
///
/// Host apps should call this after [requestUmpConsentFlow] to decide
/// whether to render a persistent "Privacy Settings" control, per Google's
/// UMP policy (a CMP must let users change their choice at any time).
Future<bool> isPrivacyOptionsRequired() async {
  final status =
      await ConsentInformation.instance.getPrivacyOptionsRequirementStatus();
  return status == PrivacyOptionsRequirementStatus.required;
}

/// Opens Google's native UMP "Privacy Options" form — the durable
/// re-consent entry point Google requires apps to expose once initial
/// consent has been gathered (EEA/UK users).
///
/// **Where to call**: from a host-provided "Privacy Settings" button, at
/// any point after [AdManager.initialize] — never during app startup, since
/// this is a *user-initiated* re-consent action, not part of the gating
/// flow that must complete before the first ad request.
///
/// No-ops (returns immediately with the current status, `formShown=false`)
/// if [isPrivacyOptionsRequired] would return `false` — i.e. this call is
/// always safe even for non-EEA users or hosts that never gathered consent.
Future<PrivacyOptionsResult> requestPrivacyOptionsFlow() async {
  const tag = 'UmpConsent';

  final requirement =
      await ConsentInformation.instance.getPrivacyOptionsRequirementStatus();
  if (requirement != PrivacyOptionsRequirementStatus.required) {
    SafeLogger.d(
        tag,
        () =>
            'privacy options: not required (status=${requirement.name}) — no-op');
    final status = await ConsentInformation.instance.getConsentStatus();
    final canRequest = await ConsentInformation.instance.canRequestAds();
    return PrivacyOptionsResult(canRequestAds: canRequest, status: status);
  }

  final dismissCompleter = Completer<String?>();
  try {
    await ConsentForm.showPrivacyOptionsForm((FormError? err) {
      dismissCompleter
          .complete(err == null ? null : '${err.errorCode}:${err.message}');
    });
  } catch (e) {
    dismissCompleter.complete('showPrivacyOptionsForm threw: $e');
  }
  final formError = await dismissCompleter.future;
  if (formError != null) {
    SafeLogger.w(tag, 'privacy options form: $formError');
  }

  final finalStatus = await ConsentInformation.instance.getConsentStatus();
  final canRequest = await ConsentInformation.instance.canRequestAds();
  SafeLogger.d(
      tag,
      () =>
          '🔐 privacy options done canRequestAds=$canRequest status=${finalStatus.name}');

  return PrivacyOptionsResult(
    canRequestAds: canRequest,
    status: finalStatus,
    error: formError,
    formShown: true,
  );
}
