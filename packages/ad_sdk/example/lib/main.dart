import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

// ── AppLovin credentials ──────────────────────────────────────────────────────
// Replace with your own values from dash.applovin.com
// SDK Key (86 chars): dash.applovin.com/o/account
// Ad Unit IDs (16 chars): dash.applovin.com/o/mediation/ad_units
const _kAppLovinSdkKey =
    'YOUR_86_CHAR_SDK_KEY_FROM_APPLOVIN_DASHBOARD';
const _kAppLovinBannerId       = 'YOUR_BANNER_AD_UNIT_ID';
const _kAppLovinInterstitialId = 'YOUR_INTERSTITIAL_AD_UNIT_ID';
const _kAppLovinAppOpenId      = 'YOUR_APP_OPEN_AD_UNIT_ID';
const _kAppLovinRewardedId     = 'YOUR_REWARDED_AD_UNIT_ID';
// ─────────────────────────────────────────────────────────────────────────────

// ── AdMob credentials (Google test IDs — replace with real ones for prod) ────
// Real IDs: console.admob.google.com
const _kAdmobBannerId       = 'ca-app-pub-3940256099942544/6300978111';
const _kAdmobInterstitialId = 'ca-app-pub-3940256099942544/1033173712';
const _kAdmobAppOpenId      = 'ca-app-pub-3940256099942544/9257395921';
const _kAdmobRewardedId     = 'ca-app-pub-3940256099942544/5224354917';
// ─────────────────────────────────────────────────────────────────────────────

// ════════════════════════════════════════════════════════════════════════════
// ENTRY POINT
// ════════════════════════════════════════════════════════════════════════════

/// Entry point — DO NOT initialize AdManager here.
/// AdManager is initialized inside SplashScreen so that
/// the EventBus fires AFTER the listener is registered.
final _navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Register navigator key so SDK can show loading dialogs from lifecycle observer
  AdManager().setNavigatorKey(_navigatorKey);
  runApp(const AdSdkExampleApp());
}

class AdSdkExampleApp extends StatelessWidget {
  const AdSdkExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ad_sdk Example',
      debugShowCheckedModeBanner: kDebugMode,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      // ⚠️ Required: register route observers for RouteAware banner lifecycle
      navigatorKey: _navigatorKey,
      navigatorObservers: [adRouteObserver, AdScreenRouteLogger()],
      home: const SplashScreen(),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// SPLASH SCREEN
// ════════════════════════════════════════════════════════════════════════════

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
        '  Replace YOUR_* values in main.dart with:           \n'
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

// ════════════════════════════════════════════════════════════════════════════
// HOME SCREEN
// ════════════════════════════════════════════════════════════════════════════

/// HomeScreen — extends AdScreen to get banner + interstitial + rewarded helpers.
class HomeScreen extends AdScreen {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends AdScreenState<HomeScreen> {
  // ── ValueNotifiers (no setState) ──
  final ValueNotifier<int> _interCountNotifier = ValueNotifier(0);
  final ValueNotifier<String> _rewardStatusNotifier = ValueNotifier('Unlock premium content');

  @override
  void dispose() {
    _interCountNotifier.dispose();
    _rewardStatusNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ad_sdk Demo'),
        backgroundColor: Colors.deepPurple,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          // ── Banner at top ── (RouteAware, lifecycle-managed automatically)
          buildBanner(),

          // ── Content ──
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Ad Touch Points',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),

                  // ── Interstitial ──
                  ValueListenableBuilder<int>(
                    valueListenable: _interCountNotifier,
                    builder: (_, count, __) => _DemoCard(
                      icon: Icons.fullscreen,
                      title: 'Interstitial Ad',
                      subtitle: 'Shown $count times',
                      color: Colors.blue,
                      onTap: () => showInterstitialAd(onDone: (shown) {
                        if (shown) _interCountNotifier.value++;
                      }),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // ── Rewarded ──
                  ValueListenableBuilder<String>(
                    valueListenable: _rewardStatusNotifier,
                    builder: (_, status, __) => _DemoCard(
                      icon: Icons.star,
                      title: 'Rewarded Ad',
                      subtitle: status,
                      color: Colors.orange,
                      onTap: () => showRewardedAd(onEarnedReward: (earned) {
                        _rewardStatusNotifier.value = earned
                            ? '✅ Reward earned!'
                            : '❌ Ad skipped or unavailable';
                      }),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // ── App Open info ──
                  const _DemoCard(
                    icon: Icons.open_in_new,
                    title: 'App Open Ad',
                    subtitle: 'Background the app and return',
                    color: Colors.green,
                    onTap: null,
                  ),
                  const SizedBox(height: 12),

                  // ── Navigate to Screen A (multi-screen demo) ──
                  _DemoCard(
                    icon: Icons.navigate_next,
                    title: 'Multi-screen Ad Flow',
                    subtitle: 'Screen A → B → C with banner + interstitial',
                    color: Colors.purple,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const ScreenA()),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // ── Safety status ──
                  ValueListenableBuilder<bool>(
                    valueListenable: AdManager().bannerIsLoaded,
                    builder: (_, loaded, __) => Text(
                      'Banner loaded: $loaded\n${AdSafetyConfig.getStatus()}',
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────
// Reusable demo card widget
// ─────────────────────────────────────────
class _DemoCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback? onTap;

  const _DemoCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.15),
          child: Icon(icon, color: color),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle),
        trailing: onTap != null
            ? Icon(Icons.play_arrow, color: color)
            : const Icon(Icons.info_outline, color: Colors.grey),
        onTap: onTap,
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// SCREEN A
// ════════════════════════════════════════════════════════════════════════════

/// Demo Screen A — demonstrates interstitial + rewarded ads using AdScreen.
class ScreenA extends AdScreen {
  const ScreenA({super.key});

  @override
  State<ScreenA> createState() => _ScreenAState();
}

class _ScreenAState extends AdScreenState<ScreenA> {
  final ValueNotifier<int> _coinsNotifier = ValueNotifier<int>(0);

  @override
  void dispose() {
    _coinsNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Screen A — Ad Demo')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ValueListenableBuilder<int>(
                      valueListenable: _coinsNotifier,
                      builder: (_, coins, __) => Text(
                        'Coins: $coins',
                        style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton.icon(
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Show Interstitial → Screen B'),
                      onPressed: () {
                        showInterstitialAd(onDone: (shown) {
                          SafeLogger.d('ScreenA', 'interstitial result: $shown');
                          Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const ScreenB()),
                          );
                        });
                      },
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      icon: const Icon(Icons.monetization_on),
                      label: const Text('Watch Ad for 10 Coins'),
                      onPressed: () {
                        showRewardedAd(
                          onEarnedReward: (earned) {
                            if (earned) {
                              SafeLogger.d('ScreenA', '🎉 Rewarded! +10 coins');
                              _coinsNotifier.value += 10;
                            }
                            // else: SDK already showed TopToast automatically
                          },
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
            buildBanner(),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// SCREEN B
// ════════════════════════════════════════════════════════════════════════════

/// Demo Screen B — demonstrates interstitial ad before navigation.
class ScreenB extends AdScreen {
  const ScreenB({super.key});

  @override
  State<ScreenB> createState() => _ScreenBState();
}

class _ScreenBState extends AdScreenState<ScreenB> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Screen B — Interstitial Demo'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Show Interstitial → Screen C'),
                  onPressed: () {
                    showInterstitialAd(onDone: (shown) {
                      SafeLogger.d('ScreenB', 'interstitial result: $shown');
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const ScreenC()),
                      );
                    });
                  },
                ),
              ),
            ),
            buildBanner(),
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// SCREEN C
// ════════════════════════════════════════════════════════════════════════════

/// Demo Screen C — final screen in the demo flow, shows a banner.
class ScreenC extends AdScreen {
  const ScreenC({super.key});

  @override
  State<ScreenC> createState() => _ScreenCState();
}

class _ScreenCState extends AdScreenState<ScreenC> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Screen C — Final'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            const Expanded(
              child: Center(
                child: Text(
                  '🎉 End of demo flow',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            buildBanner(),
          ],
        ),
      ),
    );
  }
}
