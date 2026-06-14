import 'dart:io';

import 'package:app_tracking_transparency/app_tracking_transparency.dart';

import '../utils/safe_logger.dart';

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
  String toString() => 'AttResult(status=${status.name}, hasIdfa=${idfa != null})';
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
Future<AttResult> requestAttIfNeeded({
  bool Function()? platformIsIosOverride,
  Future<TrackingStatus> Function()? readStatusOverride,
  Future<TrackingStatus> Function()? requestAuthorizationOverride,
  Future<String> Function()? readIdfaOverride,
}) async {
  const tag = 'AttConsent';

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

  try {
    var status = await readStatus();
    SafeLogger.d(tag, () => 'current status=${status.name}');

    if (status == TrackingStatus.notDetermined) {
      status = await requestAuthorization();
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
  }
}
