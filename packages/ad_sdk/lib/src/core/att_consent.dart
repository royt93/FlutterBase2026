import 'dart:async' show Completer, unawaited;
import 'dart:io';

import 'package:app_tracking_transparency/app_tracking_transparency.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../utils/safe_logger.dart';
import 'ump_consent.dart' show markUmpFormOnScreen;

/// SDK-stable mirror of the iOS App Tracking Transparency authorization state.
///
/// We expose our own enum instead of leaking the
/// `app_tracking_transparency` package's [TrackingStatus] so partner apps get
/// a stable type that survives a dependency bump.
enum AttStatus {
  /// Platform is not iOS, or iOS < 14 — ATT does not apply. The IDFA is
  /// available without a prompt on these platforms.
  notSupported,

  /// The user has not yet been asked. A prompt can (and should) be shown.
  notDetermined,

  /// Authorization is restricted by device policy (e.g. parental controls);
  /// the prompt cannot be shown and tracking is unavailable.
  restricted,

  /// The user explicitly denied tracking. IDFA is zeroed; serve
  /// non-personalized / SKAdNetwork-attributed ads only.
  denied,

  /// The user authorized tracking. IDFA is available for personalized ads.
  authorized,
}

/// Result of [requestAttIfNeeded].
class AttResult {
  const AttResult({required this.status, this.idfa});

  final AttStatus status;

  /// The IDFA when [status] is [AttStatus.authorized] (and non-zero), else
  /// `null`. On a denied/restricted device Apple returns the all-zero IDFA,
  /// which we normalise to `null`.
  final String? idfa;

  /// Whether personalized/IDFA-based ads are permitted by ATT. True when
  /// authorized, or when ATT does not apply at all (non-iOS / iOS < 14).
  bool get allowsTracking =>
      status == AttStatus.authorized || status == AttStatus.notSupported;

  @override
  String toString() =>
      'AttResult(status=${status.name}, hasIdfa=${idfa != null})';
}

const _zeroIdfa = '00000000-0000-0000-0000-000000000000';

AttStatus _map(TrackingStatus s) {
  switch (s) {
    case TrackingStatus.notDetermined:
      return AttStatus.notDetermined;
    case TrackingStatus.restricted:
      return AttStatus.restricted;
    case TrackingStatus.denied:
      return AttStatus.denied;
    case TrackingStatus.authorized:
      return AttStatus.authorized;
    case TrackingStatus.notSupported:
      return AttStatus.notSupported;
  }
}

/// Show the iOS App Tracking Transparency prompt when (and only when) it is
/// needed, and report the resulting authorization.
///
/// Behaviour:
/// - **Non-iOS** → returns [AttStatus.notSupported] immediately (no-op).
/// - **iOS, already decided** (authorized/denied/restricted) → returns the
///   cached status without re-prompting (Apple only allows the prompt once).
/// - **iOS, not yet asked** → presents the system prompt and returns the
///   user's choice.
///
/// **Where to call**: on iOS the app must already be foregrounded and showing
/// UI, so call this from your splash screen (after the first frame), not from
/// `main()` before `runApp`. Apple rejects ATT prompts shown over a blank
/// screen.
///
/// **Ordering vs UMP**: request ATT *before* the AdMob UMP form so the IDFA
/// availability is settled before the first ad request. The
/// `NSUserTrackingUsageDescription` key must be present in `Info.plist` or the
/// prompt silently fails.
///
/// The optional `*Override` parameters exist purely for unit testing (the
/// real platform/plugin APIs are not reachable from the test environment).
/// Production callers use `requestAttIfNeeded()` with no args.
///
/// T161 — guarded against overlapping calls: if a call is already in
/// flight (the previous one hasn't resolved yet — e.g. a caller bug, or a
/// user tapping a "grant permission" button twice before the system
/// prompt appears), a second call joins the SAME in-flight request rather
/// than presenting Apple's native prompt a second time. Apple's own
/// `ATTrackingManager` has no documented behavior for two concurrent
/// `requestTrackingAuthorization` calls — this avoids relying on
/// whatever the OS happens to do.
Completer<AttResult>? _pendingAttRequest;

/// Test seam: clears the in-flight-request guard. Every real call path
/// clears it automatically once it resolves — this exists only for a test
/// that intentionally leaves a request unresolved (e.g. to assert the
/// guard's join behavior) and needs to isolate that from later tests.
@visibleForTesting
void resetPendingAttRequest() => _pendingAttRequest = null;

Future<AttResult> requestAttIfNeeded({
  bool Function()? platformIsIosOverride,
  Future<TrackingStatus> Function()? readStatusOverride,
  Future<TrackingStatus> Function()? requestAuthorizationOverride,
  Future<String> Function()? readIdfaOverride,
}) {
  final pending = _pendingAttRequest;
  if (pending != null) return pending.future;

  final completer = Completer<AttResult>();
  _pendingAttRequest = completer;

  // codex re-review (P2, twice) — the guard must not release until BOTH:
  // (1) the underlying native interaction has actually settled, not
  // merely until this function's own (possibly 20s-timed-out) Future
  // resolves — same distinction `markUmpFormOnScreen`'s release (below)
  // exists for: a `Future.timeout` only stops THIS Dart call waiting, the
  // real native alert can still be up. AND (2) this call's own result
  // processing (e.g. the `readIdfa()` call after an authorized result)
  // has also finished — releasing right after (1) alone let a second call
  // arrive mid-IDFA-read and start an entirely separate request, possibly
  // resolving with a different result than the one it should have joined.
  // `_requestAttIfNeededImpl` completes [nativeSettled] exactly once, on
  // every exit path (including a thrown error), tied to the RAW native
  // future for the one path where a prompt was shown.
  final nativeSettled = Completer<void>();
  var nativeDone = false;
  var resultDone = false;
  void maybeReleaseGuard() {
    if (nativeDone && resultDone && identical(_pendingAttRequest, completer)) {
      _pendingAttRequest = null;
    }
  }

  unawaited(nativeSettled.future.then((_) {
    nativeDone = true;
    maybeReleaseGuard();
  }));

  _requestAttIfNeededImpl(
    platformIsIosOverride: platformIsIosOverride,
    readStatusOverride: readStatusOverride,
    requestAuthorizationOverride: requestAuthorizationOverride,
    readIdfaOverride: readIdfaOverride,
    nativeSettled: nativeSettled,
  ).then((result) {
    resultDone = true;
    maybeReleaseGuard();
    completer.complete(result);
  }, onError: (Object e, StackTrace st) {
    // codex re-review (P2) — _requestAttIfNeededImpl is designed to never
    // throw (its own try/catch degrades every failure to a safe
    // AttResult), but nothing enforces that at the type level — if it
    // ever did, the guard must still release and the caller must still
    // get a result rather than hanging forever.
    if (!nativeSettled.isCompleted) nativeSettled.complete();
    resultDone = true;
    maybeReleaseGuard();
    completer.completeError(e, st);
  });
  return completer.future;
}

Future<AttResult> _requestAttIfNeededImpl({
  bool Function()? platformIsIosOverride,
  Future<TrackingStatus> Function()? readStatusOverride,
  Future<TrackingStatus> Function()? requestAuthorizationOverride,
  Future<String> Function()? readIdfaOverride,
  required Completer<void> nativeSettled,
}) async {
  const tag = 'AttConsent';
  // Whether the prompt branch below has taken over responsibility for
  // completing [nativeSettled] (tied to the raw native future instead of
  // completing it immediately) — read in the `finally` below.
  var settledByPrompt = false;

  try {
    final isIos = (platformIsIosOverride ?? () => Platform.isIOS)();
    if (!isIos) {
      return const AttResult(status: AttStatus.notSupported);
    }

    final readStatus = readStatusOverride ??
        () => AppTrackingTransparency.trackingAuthorizationStatus;
    final requestAuthorization = requestAuthorizationOverride ??
        () => AppTrackingTransparency.requestTrackingAuthorization();
    final readIdfa = readIdfaOverride ??
        () => AppTrackingTransparency.getAdvertisingIdentifier();

    var status = await readStatus();
    SafeLogger.d(tag, () => 'current status=${status.name}');

    if (status == TrackingStatus.notDetermined) {
      // ponytail: the plugin has no way to detect a missing Info.plist key —
      // it just calls into ATTrackingManager, which silently no-ops/crashes
      // natively. This assert-only reminder fires loudly in debug builds
      // (stripped in release) so a missing NSUserTrackingUsageDescription is
      // caught during development, not after an App Store rejection.
      assert(() {
        SafeLogger.e(
            tag,
            '⚠️ Về chuẩn bị gọi ATT prompt — xác nhận Info.plist có key '
            'NSUserTrackingUsageDescription. Thiếu key này khiến prompt fail '
            'âm thầm hoặc app crash trên thiết bị thật. (Chỉ log ở debug build.)');
        return true;
      }());
      // Timeout guard: the native prompt can hang indefinitely if the OS
      // never presents it (observed on iOS Simulator after repeated rapid
      // launches) or the user backgrounds the app mid-prompt. Without this,
      // requestAttIfNeeded() never returns and callers who sequence
      // ATT → UMP → initialize() (see example app) never reach initialize().
      //
      // Round-31 audit fix (MAJOR) — the native ATT alert is exactly the
      // same class of thing `markUmpFormOnScreen` exists for (a native,
      // non-Flutter-route dialog the fullscreen-ad mutex has no other way
      // to see): AdScreenRouteLogger.isDialogOnTop can't see it, and
      // presenting it doesn't background the app, so the App Open
      // resume guard doesn't apply either. Without this, a splash flow
      // whose ATT prompt is slow to appear (or the 20s-timeout path below)
      // could show a fullscreen ad — including the splash App Open, which
      // uses `bypassSafety: true` — right on top of, or immediately before,
      // the system alert, stealing the user's tap. Reusing the exact same
      // ref-counted/backstopped mechanism UMP forms use rather than
      // building a parallel one.
      //
      // Deliberately NOT released in a `finally` around the `.timeout()`
      // below — that is precisely the bug `markUmpFormOnScreen`'s own doc
      // comment documents fixing for UMP forms: `Future.timeout` only
      // stops the DART side waiting, the native alert can still be up. The
      // `app_tracking_transparency` plugin exposes no separate "the alert
      // was actually dismissed" signal, so the release is attached to the
      // RAW (untimed) future — it fires whenever the alert genuinely
      // closes, however much later than the synthetic 20s timeout that
      // only unblocks this function's own caller.
      final releaseAttForm = markUmpFormOnScreen();
      final rawAuthorization = requestAuthorization();
      settledByPrompt = true;
      unawaited(rawAuthorization.then((_) {}, onError: (_) {}).whenComplete(() {
        releaseAttForm();
        if (!nativeSettled.isCompleted) nativeSettled.complete();
      }));
      status = await rawAuthorization.timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          SafeLogger.w(
              tag,
              'ATT prompt timed out after 20s — treating as '
              'notDetermined so SDK init can proceed');
          return TrackingStatus.notDetermined;
        },
      );
      SafeLogger.d(tag, () => 'prompt result=${status.name}');
    }

    String? idfa;
    if (status == TrackingStatus.authorized) {
      final raw = await readIdfa();
      idfa = (raw.isEmpty || raw == _zeroIdfa) ? null : raw;
    }

    final result = AttResult(status: _map(status), idfa: idfa);
    SafeLogger.d(tag, () => '✅ $result');
    return result;
  } catch (e) {
    // Plugin missing / Info.plist key absent / platform quirk — degrade to a
    // safe "denied" so callers serve non-personalized ads rather than crash.
    SafeLogger.w(tag, 'ATT request failed, treating as denied: $e');
    return const AttResult(status: AttStatus.denied);
  } finally {
    // Every exit path EXCEPT the prompt-shown one (which took over via
    // `settledByPrompt`, tied to the raw native future instead) has no
    // outstanding native interaction to wait for — release the guard now.
    if (!settledByPrompt && !nativeSettled.isCompleted) {
      nativeSettled.complete();
    }
  }
}
