// T117 — SDK init splash screen (ATT/UMP-aware). Split out of main.dart.
import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';

import '../config/demo_config.dart';
import '../shared/home_page.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  // Compile-time (not Platform.environment — unreliable via `simctl launch`
  // env injection on iOS). Pass `--dart-define=SKIP_SPLASH_AD=true` when
  // building for scripted Simulator test runs, so the App-Open MAX test
  // creative (which can auto-click into an undismissable Safari sheet) never
  // fires on splash.
  static const _skipSplashAd = bool.fromEnvironment('SKIP_SPLASH_AD');
  // ponytail: the real ATT system dialog has no simctl pre-grant (no
  // "tracking" TCC service exists) and reprompts on every fresh install, so
  // it wedges every scripted `flutter test integration_test/...` run behind
  // an untappable system alert. Skip the real prompt under this flag; pass
  // `--dart-define=SKIP_ATT=true` for Simulator/CI integration-test runs.
  //
  // Known gap (2026-07-12 investigation): SKIP_ATT only suppresses THIS
  // Dart-level `AdManager().requestAtt()` call below — there is no second
  // Dart call site (checked packages/ad_sdk/lib + example/lib). But tapping
  // an App-Open ad's click-through can open AppLovin's in-app browser
  // (applovin.com), which independently triggers iOS's native ATT prompt
  // outside any Dart code path — no dart-define can reach or suppress that.
  // If a scripted run wedges on ATT despite SKIP_ATT=true, it's this path;
  // the test needs a UI-automation tap on "Allow"/"Ask App Not to Track"
  // (same class of fix as the App-Open dismiss-button handling), not a
  // change to this flag.
  static const _skipAtt = bool.fromEnvironment('SKIP_ATT');
  // ponytail: requestUmpConsentFlow() awaits a real ConsentForm dismiss
  // callback with no timeout (packages/ad_sdk/lib/src/core/ump_consent.dart)
  // — if the Simulator's IP/locale resolves to an EEA-like region this run,
  // Google serves a real consent form that no scripted test taps, wedging
  // the splash chain forever. Skip the Dart-level call for scripted runs;
  // pass `--dart-define=SKIP_UMP=true`. Same known gap as SKIP_ATT above:
  // only suppresses this call site, not any native prompt triggered from
  // elsewhere.
  static const _skipUmp = bool.fromEnvironment('SKIP_UMP');
  // T103 — plain bool, not ValueNotifier: nothing ever listens to this, it's
  // used purely as a guard flag. A ValueNotifier read/written after its own
  // dispose() throws ("A ValueNotifier was used after being disposed"); a
  // native ad-load callback arriving late (after the splash widget itself
  // disposed) hit exactly that. A plain field never has this problem —
  // reading/writing it after State.dispose() is always safe.
  bool _navigated = false;
  Timer? _hardCap;
  void Function(BoolEvent)? _listener;

  @override
  void initState() {
    super.initState();
    AdManager().markSplashActive();
    AdManager().incrementSplashCount();

    if (AdManager().countInitSplashScreen > 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _goHome());
      return;
    }

    _hardCap = Timer(const Duration(seconds: 8), _goHome);

    // ⚠️ Register listener BEFORE calling initialize() — EventBus only
    // delivers fire events to listeners that registered first.
    void onEvent(BoolEvent e) =>
        (e.value && !_skipSplashAd) ? _showAppOpen() : _goHome();
    _listener = onEvent;
    SimpleEventBus().listen(onEvent);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Consent ordering (recommended): ATT → UMP → initialize.
      // 1) iOS App Tracking Transparency. No-op on Android; never throws.
      //    Must run from the splash (UI is up), NOT from main() before runApp.
      if (!_skipAtt) {
        try {
          final att = await AdManager().requestAtt();
          debugPrint('ATT status: ${att.status.name}');
        } catch (e) {
          debugPrint('ATT skipped: $e');
        }
      }
      // 2) Google UMP consent form for EEA/UK users — before the first ad request.
      if (!_skipUmp) {
        try {
          final ump = await AdManager().requestUmpConsent(
            // See kUmpEeaDebug — debugGeography is only honoured when
            // testMode is on, and only for a device in testIdentifiers.
            testMode: kUmpEeaDebug,
            debugGeography:
                kUmpEeaDebug ? DebugGeography.debugGeographyEea : null,
            testIdentifiers: kUmpTestId.isEmpty ? const [] : const [kUmpTestId],
          );
          debugPrint('UMP: canRequestAds=${ump.canRequestAds} '
              'status=${ump.status} formShown=${ump.formShown} '
              'error=${ump.error}');
          // The IAB strings a CMP leaves behind. Worth printing in the sample:
          // these are what a third-party SDK asks the host for, and until the
          // round-5 audit the getters silently returned null on every device.
          debugPrint('IAB: tcf=${await AdManager().tcfConsentString} '
              'usPrivacyOptedOut=${await AdManager().usPrivacyOptedOut} '
              'gpp=${await AdManager().gppConsentString}');
        } catch (e) {
          debugPrint('UMP skipped: $e');
        }
      }
      // When SKIP_UMP=true we never call requestUmpConsent() above, so
      // AdManager's own consent-footgun check (ad_manager.dart's
      // consentFootgunWarning) has no signal that consent was handled and
      // trips `assert(false, ...)` inside initialize() (debug/test builds
      // only — see F4/N2). That's a real safeguard for production hosts,
      // but a false alarm for scripted test runs that deliberately skip the
      // real dialog. Record a stub consent to satisfy the check.
      if (_skipUmp) {
        await AdManager().setConsent(AdConsent.conservative);
      }
      // 3) Initialize the SDK (fires the EventBus completion event). Must run
      // even if the splash's hard-cap timer already navigated away (unmounting
      // this State) — otherwise a slow ATT/UMP dialog permanently skips SDK
      // init for the rest of the session.
      AdManager().initialize(
        config: DemoConfig.instance.build(),
        onComplete: (success, gaid) {},
      );
    });
  }

  void _showAppOpen() {
    AdManager().loadAppOpenAd(onAdLoaded: (loaded) {
      if (_navigated) return;
      if (!loaded || !mounted) {
        _goHome();
        return;
      }
      AdLoadingDialog.showAdBuffer(context, onComplete: () {
        if (!mounted) {
          _goHome();
          return;
        }
        // Cancel hard cap BEFORE showing ad — ad takes over the timer's job.
        _hardCap?.cancel();
        _hardCap = null;
        AdManager().showAppOpenAd(
          bypassSafety: true, // splash flow is the ONE place safety is bypassed
          onAdDismiss: (_) => _goHome(),
        );
      });
    });
  }

  void _goHome() {
    if (_navigated) return;
    _navigated = true;
    _hardCap?.cancel();
    _hardCap = null;
    final cb = _listener;
    if (cb != null) SimpleEventBus().remove(cb);
    _listener = null;
    AdManager().markSplashInactive();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const HomePage()),
    );
  }

  @override
  void dispose() {
    // T103 — set BEFORE anything else: a native ad-load callback already
    // handed to the platform SDK before this dispose() can still arrive
    // after it. That callback calls _goHome(), which must see _navigated
    // already true and bail out immediately instead of touching
    // Navigator/context on a widget mid-teardown.
    _navigated = true;
    _hardCap?.cancel();
    final cb = _listener;
    if (cb != null) SimpleEventBus().remove(cb);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.deepPurple.shade900,
        body: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.ads_click, size: 80, color: Colors.white),
              SizedBox(height: 24),
              Text('ad_sdk',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 36,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 2)),
              SizedBox(height: 32),
              CircularProgressIndicator(color: Colors.white),
            ],
          ),
        ),
      );
}
