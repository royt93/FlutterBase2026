import 'package:flutter/foundation.dart';

import '../state/ad_slot.dart';
import '../utils/safe_logger.dart';
import 'ad_manager.dart';

/// Package identifier grepped from `pubspec.yaml`'s `name:` field — the
/// substring every stack frame originating in this SDK contains
/// (`package:applovin_admob_sdk/...`).
const String _sdkPackage = 'package:applovin_admob_sdk/';

const String _tag = 'AdCrashGuard';

/// Whether [stack]'s throw site (its first frame) is inside this SDK's own
/// package — i.e. whether the error is attributable to a bug in ad-SDK code,
/// as opposed to a host-app bug that merely happened to be caught here.
///
/// Deliberately checks only the first frame, not the whole trace: the SDK is
/// always on the stack beneath a host ad-callback (`onReward`,
/// `onAdDismiss`, ...) because it's what invoked the callback, so a
/// whole-trace substring search would misattribute every bug in a host's own
/// callback to this SDK and silently swallow it (see [installAdCrashGuard]'s
/// doc comment) instead of reporting it to the host's own crash tool.
@visibleForTesting
bool isSdkAttributable(StackTrace stack) {
  final firstLine = stack
      .toString()
      .split('\n')
      .firstWhere((line) => line.trim().isNotEmpty, orElse: () => '');
  return firstLine.contains(_sdkPackage);
}

/// Best-effort recovery: any slot currently stuck `showing`/`loading` can't
/// finish its normal callback (the callback is what crashed), so it would
/// otherwise be stranded forever. Kick it back to `cooldown` via the same
/// primitive a real show-failure uses.
void _recoverSlots() {
  final adapter = AdManager().adapter;
  if (adapter == null) return;
  for (final slot in <AdSlot>[
    adapter.appOpenSlot,
    adapter.interstitialSlot,
    adapter.rewardedSlot,
    // MJ23 — rewardedInterstitial, mrec and native were all missing. This is
    // the only recovery path for a slot stuck `showing`: those three formats
    // have no show-watchdog (deliberately — a rewarded ad can legitimately be
    // on screen for minutes), so if the callback that would have moved the
    // slot on is the very thing that crashed, the slot stayed `showing`
    // forever and no further ad of that format could ever be requested.
    adapter.rewardedInterstitialSlot,
    // T65 (phase 2): every currently-tracked widget instance, not just one.
    ...adapter.bannerSlots,
    ...adapter.mrecSlots,
    ...adapter.nativeSlots,
  ]) {
    if (slot.isShowing || slot.isLoading) {
      slot.markShowFailed();
    }
  }
}

/// The handlers [installAdCrashGuard] installed, so a repeat call can tell
/// "the current handler is still exactly the one I installed last time" from
/// "something else (a fresh call after `destroy()` + `initialize()`, or a
/// test's own `tearDown`) replaced it since" (round-27 backlog B6).
/// Comparing against these rather than a plain `bool` means a call that
/// genuinely needs to (re)install — because the previous handler is gone —
/// still does, instead of silently no-op-ing forever after the first call
/// ever made in the process.
void Function(FlutterErrorDetails)? _installedOnError;
bool Function(Object, StackTrace)? _installedOnPlatformError;
void Function(FlutterErrorDetails)? _previousOnError;
bool Function(Object, StackTrace)? _previousOnPlatformError;

/// Registers a process-wide crash guard for exceptions attributable to this
/// ad SDK, so a bug in an ad callback recovers the affected slot instead of
/// crashing the host app. Anything NOT attributable to this SDK is passed
/// through untouched to whatever handler was previously installed (the host
/// app's own, or Flutter's default).
///
/// Idempotent: a call that finds its own previously-installed handler still
/// in place (nothing else replaced it since) is a no-op — repeated
/// `initialize()` calls in one process (provider switch, logout/login,
/// re-init without `destroy()`) do not stack another wrapper layer around
/// `FlutterError.onError`/`PlatformDispatcher.onError` on top of the last
/// one, each holding the previous layer alive forever.
void installAdCrashGuard() {
  // Round 52 audit fix (MAJOR) — each handler is now checked and
  // (re)installed independently. The old code treated both handlers as one
  // all-or-nothing unit: if a host replaced ONLY `FlutterError.onError`
  // since the last install, the combined `&&` check failed, so BOTH
  // handlers were reinstalled — including `PlatformDispatcher.onError`,
  // which the host never touched and still held this guard's OWN previous
  // wrapper. That wrapper got re-captured as "the previous handler" and
  // wrapped again, permanently losing the real original underneath it: a
  // later `uninstallAdCrashGuard()` restored the guard's own stale wrapper
  // instead of the host's true original, so an SDK-attributed platform
  // error kept being intercepted (and slot-recovery kept firing) forever
  // after `destroy()`.
  if (_installedOnError == null ||
      !identical(FlutterError.onError, _installedOnError)) {
    final previousOnError = FlutterError.onError;
    _previousOnError = previousOnError;
    void onError(FlutterErrorDetails details) {
      if (isSdkAttributable(details.stack ?? StackTrace.empty)) {
        SafeLogger.e(_tag,
            'caught SDK-attributable FlutterError: ${details.exception}');
        _recoverSlots();
        return;
      }
      if (previousOnError != null) {
        previousOnError(details);
      } else {
        FlutterError.presentError(details);
      }
    }

    FlutterError.onError = onError;
    _installedOnError = onError;
  }

  if (_installedOnPlatformError == null ||
      !identical(
          PlatformDispatcher.instance.onError, _installedOnPlatformError)) {
    final previousOnPlatformError = PlatformDispatcher.instance.onError;
    _previousOnPlatformError = previousOnPlatformError;
    bool onPlatformError(Object error, StackTrace stack) {
      if (isSdkAttributable(stack)) {
        SafeLogger.e(_tag, 'caught SDK-attributable platform error: $error');
        _recoverSlots();
        return true; // handled — per PlatformDispatcher.onError convention.
      }
      // Not ours — chain to whatever was previously registered, per
      // Flutter's convention for this callback (false/previous result =
      // not handled).
      return previousOnPlatformError?.call(error, stack) ?? false;
    }

    PlatformDispatcher.instance.onError = onPlatformError;
    _installedOnPlatformError = onPlatformError;
  }
}

/// Removes the guard only when it still owns each global handler. A host
/// replacement made after installation is preserved.
void uninstallAdCrashGuard() {
  if (identical(FlutterError.onError, _installedOnError)) {
    FlutterError.onError = _previousOnError;
  }
  if (identical(
      PlatformDispatcher.instance.onError, _installedOnPlatformError)) {
    PlatformDispatcher.instance.onError = _previousOnPlatformError;
  }
  _installedOnError = null;
  _installedOnPlatformError = null;
  _previousOnError = null;
  _previousOnPlatformError = null;
}
