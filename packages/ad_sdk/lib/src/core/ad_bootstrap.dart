import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:google_mobile_ads/google_mobile_ads.dart' show DebugGeography;

import '../config/ad_config.dart';
import 'ad_manager.dart';
import 'att_consent.dart';
import 'ump_consent.dart';

/// Input to [bootstrap].
class AdBootstrapOptions {
  const AdBootstrapOptions({
    required this.config,
    this.requestAtt = true,
    this.umpTestMode = false,
    this.umpDebugGeography,
    this.umpTestIdentifiers = const [],
    this.tagForUnderAgeOfConsent = false,
    this.initTimeout = const Duration(seconds: 20),
  });

  /// Passed straight through to [AdManager.initialize].
  final AdConfig config;

  /// Whether to run the iOS ATT prompt first. No-op (and skipped) on
  /// non-iOS regardless. Turn off only if the host already requested ATT
  /// itself earlier (e.g. an onboarding screen before the splash).
  final bool requestAtt;

  /// Forwarded to [AdManager.requestUmpConsent] — see its doc for what each
  /// does. Use [umpTestMode]/[umpDebugGeography] to exercise the EEA form on
  /// a non-EEA test device.
  final bool umpTestMode;
  final DebugGeography? umpDebugGeography;
  final List<String> umpTestIdentifiers;
  final bool tagForUnderAgeOfConsent;

  /// Round-32 audit fix (MAJOR) — how long [bootstrap] waits for
  /// [AdManager.initialize] before giving up and returning with
  /// `initSuccess: false`. Bounds the worst case this function's own
  /// docstring already warned about: a wedged native init retries with
  /// [20s, 5s, 15s, 30s] backoff between four attempts, ~130s total, which
  /// with ATT/UMP on top could leave a bare `await bootstrap(...)` splash
  /// screen frozen for ~150s on a real device with no network. This does
  /// NOT cancel the real init — it keeps running and still updates
  /// [AdManager]'s own state / fires its usual completion event, this
  /// timeout only stops THIS call from waiting on it. Pass `null` to
  /// restore the old unbounded wait.
  final Duration? initTimeout;
}

/// Outcome of [bootstrap] — one struct instead of three separate
/// awaits/callbacks to thread through a splash screen.
class AdBootstrapResult {
  const AdBootstrapResult({
    required this.att,
    required this.ump,
    required this.initSuccess,
    required this.gaid,
  });

  /// `null` when [AdBootstrapOptions.requestAtt] was `false` — ATT was
  /// deliberately skipped, not attempted and failed.
  final AttResult? att;

  final UmpConsentResult ump;

  /// Mirrors [AdManager.initialize]'s `onComplete(success, ...)` argument.
  final bool initSuccess;

  /// Mirrors [AdManager.initialize]'s `onComplete(..., gaid)` argument.
  final String gaid;

  @override
  String toString() => 'AdBootstrapResult(att=$att, ump=$ump, '
      'initSuccess=$initSuccess, gaid=$gaid)';
}

/// T106 — sequences ATT → UMP → [AdManager.initialize] in the one order the
/// README already documents callers doing by hand (see "Integrate SDK"):
/// request ATT first so IDFA availability is settled before the UMP form,
/// then UMP so consent is settled before the first ad request, then init.
///
/// This is a convenience on top of existing lower-level API — it changes
/// nothing about [AdManager.requestAtt]/[AdManager.requestUmpConsent]/
/// [AdManager.initialize] themselves, and calling them by hand (or mixing
/// [bootstrap] with a custom step in between) still works exactly as before.
/// Splash UI concerns (hard-cap timer, App Open display) are NOT part of
/// this — pair with [AdReadinessSplashController] or the manual pattern in
/// README for that; [bootstrap] only covers the consent-then-init sequence.
///
/// ```dart
/// final result = await bootstrap(AdBootstrapOptions(config: myAdConfig));
/// if (result.initSuccess) {
///   // proceed to home / show splash App Open via AdManager().showAppOpenAd(...)
/// }
/// ```
///
/// The `debug*` parameters exist purely for unit testing this function's
/// sequencing without a real ATT/UMP platform channel — production callers
/// use `bootstrap(options)` with no extra arguments.
Future<AdBootstrapResult> bootstrap(
  AdBootstrapOptions options, {
  @visibleForTesting Future<AttResult> Function()? debugRequestAtt,
  @visibleForTesting Future<UmpConsentResult> Function()? debugRequestUmp,
}) async {
  AttResult? att;
  if (options.requestAtt) {
    att = await (debugRequestAtt ?? AdManager().requestAtt)();
  }

  final requestUmp = debugRequestUmp ??
      () => AdManager().requestUmpConsent(
            testMode: options.umpTestMode,
            debugGeography: options.umpDebugGeography,
            testIdentifiers: options.umpTestIdentifiers,
            tagForUnderAgeOfConsent: options.tagForUnderAgeOfConsent,
          );
  final ump = await requestUmp();

  bool? initSuccess;
  var gaid = '';
  final initDone = Completer<void>();
  unawaited(AdManager().initialize(
    config: options.config,
    onComplete: (success, deviceGaid) {
      initSuccess = success;
      gaid = deviceGaid;
      if (!initDone.isCompleted) initDone.complete();
    },
  ));
  final timeout = options.initTimeout;
  if (timeout != null) {
    // onTimeout intentionally does nothing — `initSuccess`/`gaid` above
    // just keep their not-yet-reported defaults (false/''), and the real
    // AdManager().initialize() call keeps running; it will still complete
    // `initDone` (a no-op by then) and update AdManager's own state.
    await initDone.future.timeout(timeout, onTimeout: () {});
  } else {
    await initDone.future;
  }

  return AdBootstrapResult(
    att: att,
    ump: ump,
    initSuccess: initSuccess ?? false,
    gaid: gaid,
  );
}
