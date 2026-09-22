import 'dart:async';

import 'package:flutter/foundation.dart'
    show ValueNotifier, kReleaseMode, visibleForTesting;
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../utils/safe_logger.dart';

/// How long [requestUmpConsentFlow] waits for the user to answer the consent
/// form once UMP has said one is required. Bounds a person reading a GDPR
/// form, not a network call — see the call site for why it is far longer than
/// the 20 s guards on the network steps.
const Duration kFormDismissTimeout = Duration(seconds: 180);

/// Overrides [kFormDismissTimeout]. Exists for automated on-device runs: a
/// harness cannot tap a native dialog, so it would otherwise sit out the full
/// 180 s on every EEA-path test (observed: a 3.5-minute integration run).
/// Never set this in production — the long wait is the point.
@visibleForTesting
Duration? debugFormDismissTimeoutOverride;

/// Test-only: forces [_formDismissTimeout]'s release-mode guard to behave as
/// if `kReleaseMode` were true, since `kReleaseMode` itself is always false
/// under `flutter test`. See `ad_manager.dart`'s identical pattern.
@visibleForTesting
bool debugSimulateReleaseModeForFormDismissTimeout = false;

Duration get _formDismissTimeout =>
    ((kReleaseMode || debugSimulateReleaseModeForFormDismissTimeout)
        ? null
        : debugFormDismissTimeoutOverride) ??
    kFormDismissTimeout;

/// How long [requestUmpConsentFlow] waits for `requestConsentInfoUpdate`'s
/// network round-trip before giving up. See the call site for why.
const Duration kRequestConsentInfoUpdateTimeout = Duration(seconds: 20);

/// Overrides [kRequestConsentInfoUpdateTimeout]. Exists for the test suite —
/// round-71 audit fix made `AdManager.initialize()` actually await this flow
/// instead of firing it in the background, so any unit test that doesn't
/// mock the UMP method channel now pays this real 20s network timeout once
/// per `initialize()` call (previously invisible: nothing awaited it). Set in
/// `test/flutter_test_config.dart` for the whole suite. Never set this in
/// production — the real deadline is what protects a genuinely slow network.
@visibleForTesting
Duration? debugRequestConsentInfoUpdateTimeoutOverride;

Duration get _requestConsentInfoUpdateTimeout =>
    (kReleaseMode ? null : debugRequestConsentInfoUpdateTimeoutOverride) ??
    kRequestConsentInfoUpdateTimeout;

/// True while one of Google's native UMP forms — the consent form or the
/// Privacy Options form — is actually on screen.
///
/// Round-7 audit, MAJOR. `AdManager` folds this into its fullscreen mutex, so
/// no interstitial, rewarded or App Open ad can be drawn over a consent form.
/// The form is a native activity / view controller rather than a Flutter
/// route, so `AdScreenRouteLogger.isDialogOnTop` cannot see it, and presenting
/// it does not background the app, so the App Open resume guard never applied
/// either. An ad on top of a consent form takes the tap the consent choice
/// needed, and is a policy violation in its own right.
///
/// Scoped to the presentation window only, never to the whole flow: the
/// network steps around it take up to 20 s each and show nothing, and blocking
/// ads through those would cost the splash App Open on every cold start.
final ValueNotifier<bool> umpFormOnScreen = ValueNotifier<bool>(false);

/// How many presentations are currently counted as "on screen".
///
/// Round-7 final QC — a plain boolean released in a `finally` was wrong twice
/// over, and both cases put an ad over a live consent form, which is the exact
/// thing this flag exists to prevent:
///
///  * **The timeout does not dismiss the form.** `Future.timeout` only stops
///    the Dart side waiting; the native form is still up, and with the Privacy
///    Options flow that is after 20 s of a user reading a GDPR form. So the
///    release now hangs off the dismiss callback actually firing, not off the
///    await finishing.
///  * **Two flows can overlap.** A consent form and a Privacy Options form (or
///    two hosts calling in) each set/cleared one shared boolean, so whichever
///    finished first cleared the flag while the other form was still up.
int _umpFormsOnScreen = 0;

/// Backstop for a dismiss callback that never arrives at all — a native form
/// that is torn down without notifying Dart would otherwise block every
/// fullscreen ad for the rest of the process. Long on purpose: it must not
/// undercut a real user reading a real form, which is what the release-on-
/// timeout bug did.
const Duration kUmpFormOnScreenBackstop = Duration(minutes: 15);

/// Test-only shortening of [kUmpFormOnScreenBackstop].
@visibleForTesting
Duration? debugUmpFormBackstopOverride;

/// Live release closures, so [resetUmpFormOnScreen] can cancel their backstop
/// timers instead of leaving them to fire against a later form.
final Set<void Function()> _activeUmpReleases = <void Function()>{};

/// Counts one native UMP form as being on screen and returns its release.
///
/// The release is idempotent and safe to call from a dismiss callback that may
/// fire late, twice, or not at all.
void Function() markUmpFormOnScreen() {
  _umpFormsOnScreen++;
  umpFormOnScreen.value = true;
  var released = false;
  Timer? backstop;
  late void Function() release;
  release = () {
    if (released) return;
    released = true;
    backstop?.cancel();
    _activeUmpReleases.remove(release);
    if (_umpFormsOnScreen > 0) _umpFormsOnScreen--;
    if (_umpFormsOnScreen == 0) umpFormOnScreen.value = false;
  };
  _activeUmpReleases.add(release);

  backstop =
      Timer(debugUmpFormBackstopOverride ?? kUmpFormOnScreenBackstop, () {
    SafeLogger.w(
        'UmpConsent',
        'a UMP form never reported being dismissed — releasing the ad block '
            'after ${(debugUmpFormBackstopOverride ?? kUmpFormOnScreenBackstop).inMinutes}m '
            'rather than blocking ads for the whole process');
    release();
  });
  return release;
}

/// Drops every counted presentation. For tests — a module-level counter
/// otherwise leaks from a test that throws mid-flow into the next one.
///
/// Deliberately NOT called from `AdManager.destroy()`: that teardown does not
/// dismiss a native form, so a form still on screen must keep its ad block
/// (round-13 QC round 11). What bounds a leaked count in production is each
/// presentation's own [kUmpFormOnScreenBackstop].
void resetUmpFormOnScreen() {
  // Release every outstanding presentation rather than just zeroing the
  // counter: each one owns a 15-minute backstop timer, and a backstop that
  // outlives the reset fires against whatever form is up NEXT — it finds the
  // counter at 0, skips the decrement, and clears the ad block over a live
  // form. That is the same class of bug the ref-count fixed.
  for (final release in _activeUmpReleases.toList()) {
    release();
  }
  _activeUmpReleases.clear();
  _umpFormsOnScreen = 0;
  umpFormOnScreen.value = false;
}

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

  /// True if this call handed the consent form to UMP to present, i.e. the
  /// status going in was [ConsentStatus.required] (vs. cached / not required,
  /// where no form is requested at all).
  ///
  /// Prefer [status] for "has this user answered": `obtained` covers both
  /// accept and reject, and unlike this flag it survives across sessions.
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
  // Timeout guard: this is a network call to Google's consent servers and
  // has no built-in deadline — a slow/dead network would otherwise hang the
  // whole UMP flow (and, transitively, splash init) forever.
  final updateError = await updateCompleter.future.timeout(
    _requestConsentInfoUpdateTimeout,
    onTimeout: () =>
        'requestConsentInfoUpdate timed out after ${_requestConsentInfoUpdateTimeout.inSeconds}s',
  );
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

  // Step 2 — hand the "does this user actually need to see a form?" decision
  // to UMP itself, via Google's own `loadAndShowConsentFormIfRequired`.
  //
  // This used to gate on `isConsentFormAvailable()` + an unconditional
  // `form.show()`. That is wrong, and was confirmed wrong on a real device
  // (Pixel 7 Pro, debugGeography EEA): `isConsentFormAvailable()` reports
  // whether a form *exists*, not whether consent is *required*, and a form
  // stays available after the user has consented — that availability is
  // exactly what backs the Privacy Options entry point below. So an EEA user
  // who had already consented was shown the consent form again on EVERY
  // launch, logging `status=obtained formShown=true` each time. Re-presenting
  // a form the user already answered is both a bad experience and against
  // UMP's own guidance.
  //
  // The `status == required` guard in front of the call is not redundant with
  // the API's internal "if required" check: it keeps the common case (non-EEA,
  // or already-answered) from paying a platform round trip at all.
  bool formShown = false;
  String? formError;
  if (status == ConsentStatus.required) {
    final dismissCompleter = Completer<String?>();
    // Counted before the presentation call, not after: the native form is on
    // screen from the moment that call goes out. Released by the dismiss
    // callback below — NOT when this function stops waiting.
    final releaseForm = markUmpFormOnScreen();
    // Deliberately NOT awaited — same reasoning as requestPrivacyOptionsFlow()
    // below: the native call only returns once the form is dismissed, so
    // awaiting it here would bypass the timeout entirely.
    // Round-8 QC, MINOR — `.catchError` below only catches an async failure. A
    // synchronous throw out of the presentation call itself (a missing plugin
    // registration, a null Activity) would skip it, leaving the ad block
    // standing until the 15-minute backstop with no form ever on screen.
    try {
      unawaited(ConsentForm.loadAndShowConsentFormIfRequired((FormError? err) {
        // Released first, before the isCompleted guard: after a timeout the
        // completer is already done, and returning early there would leave the
        // ad block standing until the backstop.
        releaseForm();
        if (dismissCompleter.isCompleted) return;
        dismissCompleter
            .complete(err == null ? null : '${err.errorCode}:${err.message}');
      }).catchError((Object e) {
        releaseForm();
        if (!dismissCompleter.isCompleted) {
          dismissCompleter
              .complete('loadAndShowConsentFormIfRequired threw: $e');
        }
      }));
    } catch (e) {
      releaseForm();
      if (!dismissCompleter.isCompleted) {
        dismissCompleter
            .complete('loadAndShowConsentFormIfRequired threw sync: $e');
      }
    }
    formShown = true;
    // Timeout guard, deliberately much longer than step 1's. A cap still has
    // to exist — an iOS Simulator with nothing tapping through never dismisses
    // the form, which used to hang this flow (and, transitively, splash init)
    // forever. But this cap bounds a *human reading a GDPR form* (206
    // partners, an expandable "Learn more"), not a network call: the
    // no-network case is already bounded by step 1's 20 s above, and nothing
    // here even starts until UMP has said consent is required. At 20 s the
    // flow was observed abandoning a form that was still on screen and
    // resolving the ad gate before the user had answered.
    //
    // Note what this timeout does NOT do: release the ad block. The form is
    // still on screen — see [_umpFormsOnScreen].
    formError = await dismissCompleter.future.timeout(
      _formDismissTimeout,
      onTimeout: () => 'consent form dismiss timed out after '
          '${_formDismissTimeout.inSeconds}s',
    );
    if (formError != null) {
      SafeLogger.w(tag, 'consent form: $formError');
    }
  } else {
    SafeLogger.d(
        tag, () => 'consent form not required (status=${status.name}) — skip');
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

/// Re-reads UMP's current decision WITHOUT presenting a form or making a
/// network request — a pure local read of what Google's SDK already knows.
///
/// M-3 (independent review, 2026-08-22 audit): used by [AdManager] to
/// recover from an abandoned consent form (its own dismiss timeout fired,
/// but a native form may still be on screen). `Future.timeout` cannot close
/// that dialog, so calling [requestUmpConsentFlow] again there would risk
/// presenting a SECOND form on top of it; this never does, so it is always
/// safe to call, including on every periodic backstop tick.
Future<UmpConsentResult> recheckUmpConsentStatus() async {
  final canRequestAds = await ConsentInformation.instance.canRequestAds();
  final status = await ConsentInformation.instance.getConsentStatus();
  return UmpConsentResult(canRequestAds: canRequestAds, status: status);
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
/// entry point (e.g. a settings button) to the current user, once initial
/// consent has been gathered.
///
/// Audit round 43 — this used to say "true for EEA/UK users" specifically;
/// UMP's Privacy Options requirement also applies to the US-states/GPP
/// consent message type, not just the EEA/UK GDPR one, and this function
/// just proxies whatever the native SDK returns without branching on
/// region — no functional change, the old comment was just imprecise.
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
/// consent has been gathered (not EEA/UK-only — see [isPrivacyOptionsRequired]).
///
/// **Where to call**: from a host-provided "Privacy Settings" button, at
/// any point after [AdManager.initialize] — never during app startup, since
/// this is a *user-initiated* re-consent action, not part of the gating
/// flow that must complete before the first ad request.
///
/// No-ops (returns immediately with the current status, `formShown=false`)
/// if [isPrivacyOptionsRequired] would return `false` — i.e. this call is
/// always safe even for non-EEA users or hosts that never gathered consent.
///
/// [onLateDismiss] is invoked — with a freshly re-read result — if the
/// native form is dismissed *after* the wait below has already given up on
/// it. Device verification (2026-08-23, Pixel 7 Pro, EEA debug geography)
/// showed why it has to exist: the wait was 20 s, and a user who read the
/// 206-partner form for longer than that and then withdrew consent had that
/// withdrawal read at timeout time — i.e. before they made it — and nothing
/// ever re-read it, so personalised ads kept serving for the rest of the
/// session. The wait is now [kFormDismissTimeout], but no wait can be long
/// enough for every user, so the callback closes the case rather than
/// widening it. The returned result is still the at-timeout snapshot; the
/// callback carries the real one.
Future<PrivacyOptionsResult> requestPrivacyOptionsFlow({
  void Function(PrivacyOptionsResult result)? onLateDismiss,
}) async {
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
  // See the consent-form window above: counted before the call, released by
  // the dismiss callback rather than by this function giving up waiting.
  final releaseForm = markUmpFormOnScreen();
  // Deliberately NOT awaited: ConsentForm.showPrivacyOptionsForm() awaits the
  // native platform call internally before invoking the dismiss callback, so
  // awaiting it here directly would hang on that call forever, bypassing the
  // timeout below entirely — same fire-and-forget shape as
  // ConsentForm.loadConsentForm()/form.show() above in requestUmpConsentFlow().
  // Round-8 QC, MINOR — a synchronous throw here would skip `.catchError`
  // and leave the ad block standing until the backstop; see the same guard
  // in requestUmpConsentFlow().
  try {
    unawaited(ConsentForm.showPrivacyOptionsForm((FormError? err) {
      releaseForm();
      if (dismissCompleter.isCompleted) return;
      dismissCompleter
          .complete(err == null ? null : '${err.errorCode}:${err.message}');
    }).catchError((Object e) {
      releaseForm();
      if (!dismissCompleter.isCompleted) {
        dismissCompleter.complete('showPrivacyOptionsForm threw: $e');
      }
    }));
  } catch (e) {
    releaseForm();
    if (!dismissCompleter.isCompleted) {
      dismissCompleter.complete('showPrivacyOptionsForm threw sync: $e');
    }
  }
  // Timeout guard (T44) — the dismiss callback only fires once the user taps
  // through the native form, which can hang indefinitely if it's served but
  // never dismissed. Without this, a caller awaiting requestPrivacyOptionsFlow()
  // (e.g. a "Privacy Options" button's tap handler) would hang forever.
  //
  // As above, the timeout frees this caller, not the form: the ad block stays
  // until the form actually reports being dismissed.
  //
  // Uses the same human-reading bound as the initial consent form
  // ([kFormDismissTimeout]) rather than a network-call bound. This was 20 s,
  // and device verification (2026-08-23, Pixel 7 Pro, EEA debug geography)
  // caught it doing here exactly what the 20 s did there: the withdrawal form
  // is the *longer* read of the two — the user is hunting for the toggle they
  // want to turn off — and the status below was read while it was still up.
  final String? formError = await dismissCompleter.future.timeout(
    _formDismissTimeout,
    onTimeout: () => 'privacy options form dismiss timed out after '
        '${_formDismissTimeout.inSeconds}s',
  );
  if (formError != null) {
    SafeLogger.w(tag, 'privacy options form: $formError');
  }
  // The timeout above frees this caller but not the form, so the user's real
  // choice normally lands seconds later — and the status read below is taken
  // while the form is still up. Keep listening so the caller can re-apply
  // whatever they actually chose. Registered in the same zone as the
  // completer, so completion is always delivered here.
  final lateCallback = onLateDismiss;
  if (!dismissCompleter.isCompleted && lateCallback != null) {
    unawaited(dismissCompleter.future.then((String? lateError) async {
      final lateStatus = await ConsentInformation.instance.getConsentStatus();
      final lateCanRequest = await ConsentInformation.instance.canRequestAds();
      SafeLogger.w(
          tag,
          'privacy options form dismissed AFTER our timeout — re-applying: '
          'canRequestAds=$lateCanRequest status=${lateStatus.name}');
      lateCallback(PrivacyOptionsResult(
        canRequestAds: lateCanRequest,
        status: lateStatus,
        error: lateError,
        formShown: true,
      ));
    }).catchError((Object e) {
      SafeLogger.w(tag, 'late privacy-options re-read threw: $e');
    }));
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
