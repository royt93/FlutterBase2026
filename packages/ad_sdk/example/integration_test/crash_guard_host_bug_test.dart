// On-device integration test for round-35's AdCrashGuard fix.
//
// The bug: `isSdkAttributable()` used to match this SDK's package name
// against the WHOLE stack trace, so a genuine bug thrown inside a host app's
// own ad callback (onReward, onAdDismiss, ...) — which always has this SDK
// somewhere beneath it on the stack, since the SDK is what invoked the
// callback — was misattributed to the SDK and silently swallowed by
// `installAdCrashGuard()` instead of reaching the host's own crash
// reporting.
//
// This runs the check on a REAL device/simulator (real ARM64 hardware, real
// Flutter engine, not just the headless VM test in `test/
// ad_crash_guard_test.dart`) to rule out any difference in stack-trace
// formatting between the desktop test VM and an on-device Flutter engine.
// Not covered here: a true `--release --obfuscate` build, which
// `flutter test integration_test/` does not produce — obfuscation would
// strip the `package:applovin_admob_sdk/` path entirely, which is a
// documented, separate concern from this fix (an obfuscated build already
// can't use this attribution mechanism at all, with or without this fix).
//
// Run with:
//   flutter test integration_test/crash_guard_host_bug_test.dart -d <device-or-sim-id>

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/core/ad_crash_guard.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

Future<void> _waitForInit(WidgetTester tester) async {
  for (var i = 0; i < 90; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (AdManager().isInitialised) return;
  }
  fail('SDK must finish initialising on device');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'a host bug thrown inside a real SDK call is NOT swallowed as an '
      'SDK-attributed error, on real device hardware', (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    // Install a recorder BEFORE (re)installing the real crash guard: since
    // this replaces whatever handler is currently in place, the guard's own
    // "something else replaced my handler since last time" check (round-27
    // B6) makes it re-wrap around this recorder as its `previousOnError` —
    // so this test exercises the SDK's actual, real `installAdCrashGuard()`
    // chain, not just a plain FlutterError.onError set by the test itself.
    FlutterErrorDetails? seenByPrevious;
    final originalOnError = FlutterError.onError;
    FlutterError.onError = (details) => seenByPrevious = details;
    installAdCrashGuard();
    addTearDown(() => FlutterError.onError = originalOnError);

    // MonetizationArbitrator.decide() calls a host-supplied estimator
    // synchronously and unguarded — a real, on-device stand-in for
    // onReward/onAdDismiss for the purpose of getting a genuine device
    // stack trace with this SDK on it beneath the actual throw site.
    final arbitrator = MonetizationArbitrator();
    arbitrator.registerVipLikelihoodEstimator(
        () => throw StateError('host bug — device integration check'));

    late StackTrace realDeviceStack;
    try {
      arbitrator.decide(AdSlotType.interstitial);
      fail('expected decide() to propagate the estimator\'s exception');
    } catch (_, st) {
      realDeviceStack = st;
    }

    expect(
      realDeviceStack.toString(),
      contains('package:applovin_admob_sdk/'),
      reason: 'sanity — must be a real on-device stack where the SDK '
          'genuinely appears beneath the throw site, on this exact device\'s '
          'Flutter engine build',
    );

    FlutterError.reportError(FlutterErrorDetails(
      exception: StateError('host bug — device integration check'),
      stack: realDeviceStack,
    ));

    expect(seenByPrevious, isNotNull,
        reason: 'the host bug must reach the previously-installed error '
            'handler on real device hardware, not be swallowed as if it '
            'were an SDK bug');
  });
}
