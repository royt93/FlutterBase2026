import 'package:flutter/foundation.dart';

import '../state/ad_slot.dart';
import '../utils/safe_logger.dart';
import 'ad_manager.dart';

/// Package identifier grepped from `pubspec.yaml`'s `name:` field — the
/// substring every stack frame originating in this SDK contains
/// (`package:applovin_admob_sdk/...`).
const String _sdkPackage = 'package:applovin_admob_sdk/';

const String _tag = 'AdCrashGuard';

/// Whether [stack] contains at least one frame from this SDK's own package —
/// i.e. whether the error is attributable to a bug in ad-SDK code (as opposed
/// to a host-app bug that merely happened to be caught here).
@visibleForTesting
bool isSdkAttributable(StackTrace stack) =>
    stack.toString().contains(_sdkPackage);

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
    adapter.bannerSlot,
  ]) {
    if (slot.isShowing || slot.isLoading) {
      slot.markShowFailed();
    }
  }
}

/// Registers a process-wide crash guard for exceptions attributable to this
/// ad SDK, so a bug in an ad callback recovers the affected slot instead of
/// crashing the host app. Anything NOT attributable to this SDK is passed
/// through untouched to whatever handler was previously installed (the host
/// app's own, or Flutter's default).
///
/// Idempotent-ish: call once, typically gated behind
/// [AdConfig.enableCrashGuard] from [AdManager.initialize].
void installAdCrashGuard() {
  final previousOnError = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    if (isSdkAttributable(details.stack ?? StackTrace.empty)) {
      SafeLogger.e(
          _tag, 'caught SDK-attributable FlutterError: ${details.exception}');
      _recoverSlots();
      return;
    }
    if (previousOnError != null) {
      previousOnError(details);
    } else {
      FlutterError.presentError(details);
    }
  };

  final previousOnPlatformError = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    if (isSdkAttributable(stack)) {
      SafeLogger.e(_tag, 'caught SDK-attributable platform error: $error');
      _recoverSlots();
      return true; // handled — per PlatformDispatcher.onError convention.
    }
    // Not ours — chain to whatever was previously registered, per Flutter's
    // convention for this callback (false / previous result = not handled).
    return previousOnPlatformError?.call(error, stack) ?? false;
  };
}
