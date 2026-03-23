import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'home_screen.dart';

// ── AppLovin credentials ─────────────────────────────────────────────────────
// Replace with your own values from dash.applovin.com
// SDK Key (86 chars): dash.applovin.com/o/account
// Ad Unit IDs (16 chars): dash.applovin.com/o/mediation/ad_units
const _kAppLovinSdkKey =
    'REDACTED_APPLOVIN_SDK_KEY_ROUND68';
const _kAppLovinBannerId     = 'REDACTED_APPLOVIN_BANNER_ID';
const _kAppLovinInterstitialId = 'REDACTED_APPLOVIN_INTERSTITIAL_ID';
const _kAppLovinAppOpenId    = 'REDACTED_APPLOVIN_APPOPEN_ID';
const _kAppLovinRewardedId   = 'REDACTED_APPLOVIN_REWARDED_ID';
// ─────────────────────────────────────────────────────────────────────────────

// ── AdMob credentials (Google test IDs — replace with real ones for prod) ────
// Real IDs: console.admob.google.com
const _kAdmobBannerId        = 'ca-app-pub-3940256099942544/6300978111';
const _kAdmobInterstitialId  = 'ca-app-pub-3940256099942544/1033173712';
const _kAdmobAppOpenId       = 'ca-app-pub-3940256099942544/9257395921';
const _kAdmobRewardedId      = 'ca-app-pub-3940256099942544/5224354917';
// ─────────────────────────────────────────────────────────────────────────────


/// SplashScreen — initializes AdManager, shows App Open Ad, then navigates.
///
/// AdManager.initialize() is called HERE (not in main) so that
/// SimpleEventBus.fire() always happens AFTER the listener is registered.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  // ── State (ValueNotifier — no setState needed) ──
  final ValueNotifier<String> _statusNotifier = ValueNotifier('Initializing…');

  // ── Internal ──
  bool _hasNavigated = false;
  void Function(BoolEvent)? _eventListener;
  Timer? _hardCapTimer;

  @override
  void initState() {
    super.initState();
    AdManager().markSplashActive();
    AdManager().incrementSplashCount();

    // Skip ad flow if splash was already shown before (cold re-open)
    if (AdManager().countInitSplashScreen > 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _navigateHome());
      return;
    }

    // ──────────────────────────────────────────────────────────────
    // PLACEHOLDER CHECK — detect unfilled example IDs
    // ──────────────────────────────────────────────────────────────
    // AppLovin has NO universal test IDs (unlike AdMob).
    // You MUST create real ad units in your AppLovin MAX dashboard:
    //   https://dash.applovin.com/o/mediation/ad_units
    // Then replace the YOUR_* strings in the AdConfig below.
    //
    // SDK Key: 86-character string from https://dash.applovin.com/o/account
    // Ad Unit IDs: 16-character strings from MAX dashboard
    // ──────────────────────────────────────────────────────────────
    if (_hasPlaceholderIds()) {
      SafeLogger.e(
        'SplashExample',
        '══════════════════════════════════════════════════════\n'
        '  ⚠️  PLACEHOLDER IDs DETECTED — ads will NOT load   \n'
        '  Replace YOUR_* values in splash_screen.dart with:  \n'
        '  • SDK Key (86 chars): dash.applovin.com/o/account  \n'
        '  • Ad Unit IDs (16 chars): dash.applovin.com         \n'
        '  UI demo mode: navigating directly to HomeScreen.    \n'
        '══════════════════════════════════════════════════════',
      );
      _statusNotifier.value = 'Demo mode (no real Ad IDs)';
      // Skip ad init, go straight to UI demo
      _hardCapTimer = Timer(const Duration(seconds: 2), _navigateHome);
      return;
    }

    // Hard cap 8s — prevent stuck splash
    _hardCapTimer = Timer(const Duration(seconds: 8), () {
      SafeLogger.d('SplashExample', '⏰ Hard cap 8s → force navigate');
      _navigateHome();
    });

    // Register EventBus BEFORE calling initialize()
    _eventListener = (event) {
      SafeLogger.d('SplashExample', 'EventBus: ${event.value}');
      if (event.value) {
        _statusNotifier.value = 'Loading Ad…';
        _loadAndShowAppOpenAd();
      } else {
        _navigateHome(); // SDK init failed
      }
    };
    SimpleEventBus().listen(_eventListener!);

    // Initialize AdManager — fires EventBus when done
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AdManager().initialize(
        config: const AdConfig(
          // ← Switch provider here: AdProvider.admob or AdProvider.appLovin
          provider: AdProvider.appLovin,
          admob: AdMobConfig(
            bannerId: _kAdmobBannerId,
            interstitialId: _kAdmobInterstitialId,
            appOpenId: _kAdmobAppOpenId,
            rewardedId: _kAdmobRewardedId,
          ),
          appLovin: AppLovinConfig(
            sdkKey: _kAppLovinSdkKey,
            bannerId: _kAppLovinBannerId,
            interstitialId: _kAppLovinInterstitialId,
            appOpenId: _kAppLovinAppOpenId,
            rewardedId: _kAppLovinRewardedId,
          ),
          vipDeviceGaids: [],
          loadingBufferMs: 1000,
          adNotReadyMessage: 'Ad not ready — please wait and try again.',
          adLoadingMessage: 'Loading…',
        ),
        onComplete: (success, gaid) {
          SafeLogger.d('SplashExample', 'init done: success=$success, gaid=$gaid');
        },
      );
    });
  }

  /// Returns true if any AppLovin credential is still a placeholder.
  bool _hasPlaceholderIds() {
    return _kAppLovinSdkKey.startsWith('YOUR_') ||
        _kAppLovinBannerId.startsWith('YOUR_') ||
        _kAppLovinInterstitialId.startsWith('YOUR_');
  }


  void _loadAndShowAppOpenAd() {
    AdManager().loadAppOpenAd(onAdLoaded: (loaded) {
      SafeLogger.d('SplashExample', 'loadAppOpenAd result=$loaded');
      if (_hasNavigated) return;

      if (loaded) {
        if (!mounted) { _navigateHome(); return; }
        AdLoadingDialog.showAdBuffer(context, onComplete: () {
          if (!mounted) { _navigateHome(); return; }
          // Cancel hard cap BEFORE showing ad — timer must not interrupt an active ad
          _hardCapTimer?.cancel();
          _hardCapTimer = null;
          AdManager().showAppOpenAd(
            bypassSafety: true,
            onAdDismiss: (_) => _navigateHome(),
          );
        });
      } else {
        _navigateHome();
      }
    });
  }

  void _navigateHome() {
    if (_hasNavigated) return;
    _hasNavigated = true;

    // Clean up
    _hardCapTimer?.cancel();
    _hardCapTimer = null;
    if (_eventListener != null) {
      SimpleEventBus().remove(_eventListener!);
      _eventListener = null;
    }
    AdManager().markSplashInactive(); // Called exactly once here

    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
    );
  }

  @override
  void dispose() {
    _hardCapTimer?.cancel();
    // Guard: if disposed before navigated (e.g. hot restart in debug)
    if (_eventListener != null) {
      SimpleEventBus().remove(_eventListener!);
      _eventListener = null;
    }
    _statusNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.deepPurple.shade900,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.ads_click, size: 80, color: Colors.white),
            const SizedBox(height: 24),
            const Text(
              'ad_sdk',
              style: TextStyle(
                fontSize: 36,
                fontWeight: FontWeight.bold,
                color: Colors.white,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Dual-provider Ad SDK Demo',
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 40),
            ValueListenableBuilder<String>(
              valueListenable: _statusNotifier,
              builder: (_, status, __) => Text(
                status,
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),
            const SizedBox(height: 16),
            const CircularProgressIndicator(color: Colors.white),
            if (kDebugMode) ...[
              const SizedBox(height: 24),
              TextButton(
                onPressed: _navigateHome,
                child: const Text('Skip (debug)', style: TextStyle(color: Colors.white54)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
