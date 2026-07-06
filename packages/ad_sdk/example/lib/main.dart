// ═══════════════════════════════════════════════════════════════════════════
// applovin_admob_sdk — single-file example
//
// 11 demo pages, all in this one file so a developer can read top-to-bottom
// without jumping between files. Sections in order:
//   §1  Constants + DemoConfig + VIP validator
//   §2  LogBuffer (in-memory ring of SDK logs)
//   §3  Entry: main() + SplashScreen
//   §4  Shared: DemoTile widget
//   §5  HomePage (list of all demos)
//   §6  Demo: Banner
//   §7  Demo: Interstitial
//   §8  Demo: Rewarded
//   §9  Demo: App Open
//   §10 Demo: VIP redeem (Cupertino dialog)
//   §11 Demo: Consent / GDPR / COPPA / CCPA flags
//   §12 Demo: Safety status + presets
//   §13 Demo: Log viewer (ring buffer)
//   §14 Demo: Revenue dashboard
//   §15 Demo: Slot state panel (+ manual destroy/reinit)
//   §16 Demo: AdEvent stream live viewer
//
// Note: provider (AdMob vs AppLovin) is chosen ONCE at app startup via
// `AdConfig.provider` and is **not** swappable at runtime. To switch
// providers, change `kProvider` in §1 and rebuild.
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ═══════════════════════════════════════════════════════════════════════════
// §1  Constants + DemoConfig + VIP validator
// ═══════════════════════════════════════════════════════════════════════════

/// Replace with your own AppLovin keys; AdMob test IDs below are public and
/// always valid (Google's test units).
const _kAppLovinSdkKey = 'YOUR_86_CHAR_SDK_KEY_FROM_APPLOVIN_DASHBOARD';
const _kAppLovinBannerId = 'YOUR_BANNER_AD_UNIT_ID';
const _kAppLovinInterstitialId = 'YOUR_INTERSTITIAL_AD_UNIT_ID';
const _kAppLovinAppOpenId = 'YOUR_APP_OPEN_AD_UNIT_ID';
const _kAppLovinRewardedId = 'YOUR_REWARDED_AD_UNIT_ID';

/// Provider for this app — chosen once. Replace the 5 YOUR_* constants
/// above with real values from dash.applovin.com BEFORE running.
const AdProvider kProvider = AdProvider.admob;

/// VIP demo keys (Q28 — user-supplied).
const Map<String, Duration> kDemoVipKeys = {
  'TEST_VIP_7': Duration(days: 7),
  'TEST_VIP_30': Duration(days: 30),
  'TEST_VIP_90': Duration(days: 90),
};

/// T18 — offline SIGNED VIP keys. The public key below verifies the keys; the
/// matching private key (never shipped) minted them via tool/vip_mint.dart.
/// DEMO keypair — generate your own with tool/vip_keygen.dart before release.
const String kDemoVipPublicKey = 'nqmoUYYjAH_dVDcO5fZk8EagjLIq688hPbAzIYD0DWY=';
const Map<String, String> kDemoSignedVipKeys = {
  '1d':
      'AVP1.ODY0MDB8ZGVtbzFk.NFrAVXDD8FUNpZzBQG_MDq_dgKVyE6HmRTn7TTxmbWT0_hIZX2_9PO1tX2SBMMWh-Mp5nt3d3hnNSbYuDI-tCA==',
  '7d':
      'AVP1.NjA0ODAwfGRlbW83ZA==.7lj_TWdPk3h8LWcBAQzU5dfwmfMeu0--inrlLckEgqtlx3LpNpPNOX4TNZ7ypHmfKRamSWErp6uyRDP54jAaAg==',
  '30d':
      'AVP1.MjU5MjAwMHxkZW1vMzBk.nCPvlNoexldaulVWw5IycTDM1Cr_pUmQQMuf0myVogbnTcrccs69LB40t1MtvPLNhakK0OPIM3e_GaXOsXKrDg==',
};

/// Validator wired into [AdConfig.vipKeyValidator] — only the demo keys above
/// are valid. In a real app this calls your server.
Future<bool> demoVipValidator(String key) async {
  await Future<void>.delayed(const Duration(milliseconds: 600));
  return kDemoVipKeys.containsKey(key);
}

/// Builds the [AdConfig] used by the demo. Provider is a compile-time const
/// (`kProvider` above) — runtime swap is intentionally NOT exposed because
/// the SDK is designed to be initialised once per app process.
class DemoConfig {
  DemoConfig._();

  static final DemoConfig instance = DemoConfig._();

  AdConfig build() {
    return AdConfig(
      provider: kProvider,
      admob: const AdMobConfig(
        bannerId: 'ca-app-pub-3940256099942544/6300978111',
        interstitialId: 'ca-app-pub-3940256099942544/1033173712',
        appOpenId: 'ca-app-pub-3940256099942544/9257395921',
        rewardedId: 'ca-app-pub-3940256099942544/5224354917',
        // Optional per-platform overrides (T15) — omit to use the same id
        // on both platforms, as above:
        // androidBannerId: 'ca-app-pub-.../android-banner',
        // iosBannerId: 'ca-app-pub-.../ios-banner',
      ),
      appLovin: const AppLovinConfig(
        sdkKey: _kAppLovinSdkKey,
        bannerId: _kAppLovinBannerId,
        interstitialId: _kAppLovinInterstitialId,
        appOpenId: _kAppLovinAppOpenId,
        rewardedId: _kAppLovinRewardedId,
      ),
      logLevel: AdLogLevel.verbose,
      onLog: LogBuffer.instance.sink,
      vipKeyValidator: demoVipValidator,
      // Cap the total stacked VIP window (cộng dồn) — demo at 90 days. null = uncapped.
      maxVipStackDuration: const Duration(days: 90),
      adNotReadyMessage: 'Ad not ready — please wait.',
      adLoadingMessage: 'Loading…',
      splashMaxDuration: const Duration(seconds: 8),
      // Demo always uses the loose preset (999 caps, 2 s throttle, 0 s
      // warm-up) regardless of debug/release. Lets QA pound the buttons
      // without hitting any safety wall.
      // ⚠️ DO NOT copy this into a production app — use AdSafetyParams.auto
      // (default) or AdSafetyParams.production there.
      safety: kDemoSafetyParams,
      // First-install VIP grace: 30 s in debug (so QA can verify "after
      // grace expires, ads return" without waiting 24 h), 24 h in release.
      // Other options:
      //   FirstInstallVipGrace.disabled                    → never grant
      //   FirstInstallVipGrace.day                         → force 24 h both modes
      //   FirstInstallVipGrace(Duration(hours: 12))        → custom
      firstInstallVipGrace: FirstInstallVipGrace.auto,
      // Auto-show Cupertino consent dialog ~1 s after splash → home (skipped
      // for VIP users — first 30 s of debug install stays silent because
      // grace is active). Strings default to English; consumers override
      // via consentDialogStrings: ConsentDialogStrings.vi etc.
      autoShowConsentDialog: true,
      consentDialogPostSplashDelay: const Duration(seconds: 1),
    );
  }
}

/// Single set of safety params used by this demo for both debug and release.
/// All caps are 999 / throttle 2 s / no warm-up — chosen for easy QA testing.
const AdSafetyParams kDemoSafetyParams = AdSafetyParams(
  minTimeBetweenFullscreenAds: 2000, // 2 s between fullscreen ads
  maxFullscreenAdsPerSession: 999,
  maxFullscreenAdsPerHour: 999,
  maxFullscreenAdsPerDay: 999,
  minSessionDurationBeforeAd: 0,
  minTimeAppOpenResume: 0,
  maxClicksPerMinute: 999,
  suspiciousCtrThreshold: 1.0, // CTR fraud check effectively disabled
  maxRapidResumesPerMinute: 999,
  dryRun: false,
);

// ═══════════════════════════════════════════════════════════════════════════
// §2  LogBuffer — in-memory ring of SDK logs
// ═══════════════════════════════════════════════════════════════════════════

class LogBuffer {
  LogBuffer._();

  static final LogBuffer instance = LogBuffer._();

  static const int _maxEntries = 200;
  final List<LogEntry> _entries = [];

  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  void Function(AdLogLevel, String, String) get sink => _onLog;

  void _onLog(AdLogLevel level, String tag, String message) {
    _entries.add(LogEntry(
      timestamp: DateTime.now(),
      level: level,
      tag: tag,
      message: message,
    ));
    if (_entries.length > _maxEntries) {
      _entries.removeAt(0);
    }
    revision.value = revision.value + 1;
  }

  List<LogEntry> snapshot() => List.unmodifiable(_entries);

  void clear() {
    _entries.clear();
    revision.value = revision.value + 1;
  }
}

class LogEntry {
  const LogEntry({
    required this.timestamp,
    required this.level,
    required this.tag,
    required this.message,
  });

  final DateTime timestamp;
  final AdLogLevel level;
  final String tag;
  final String message;
}

// ═══════════════════════════════════════════════════════════════════════════
// §3  Entry: main() + SplashScreen
// ═══════════════════════════════════════════════════════════════════════════

final _navigatorKey = GlobalKey<NavigatorState>();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Edge-to-edge: status bar + nav bar transparent, content paints behind them.
  // Required on Android 15+ (target SDK 35) and recommended on older versions.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  // ⚠️ Required: register navigator key BEFORE runApp so the SDK can show
  // loading dialogs from lifecycle observer (App Open on resume).
  AdManager().setNavigatorKey(_navigatorKey);
  runApp(MaterialApp(
    title: 'ad_sdk demo',
    debugShowCheckedModeBanner: kDebugMode,
    navigatorKey: _navigatorKey,
    // ⚠️ Required: register route observers for RouteAware banner lifecycle.
    navigatorObservers: [adRouteObserver, AdScreenRouteLogger()],
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      useMaterial3: true,
    ),
    // DebugAdOverlay floats over every screen (kDebugMode only). Wrapping
    // here instead of inside HomePage means the overlay stays visible while
    // the user navigates into any demo page.
    builder: (context, child) {
      if (child == null) return const SizedBox.shrink();
      return Stack(
        children: [
          child,
          const DebugAdOverlay(),
        ],
      );
    },
    home: const SplashScreen(),
  ));
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  final ValueNotifier<bool> _navigated = ValueNotifier<bool>(false);
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
    void onEvent(BoolEvent e) => e.value ? _showAppOpen() : _goHome();
    _listener = onEvent;
    SimpleEventBus().listen(onEvent);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Consent ordering (recommended): ATT → UMP → initialize.
      // 1) iOS App Tracking Transparency. No-op on Android; never throws.
      //    Must run from the splash (UI is up), NOT from main() before runApp.
      try {
        final att = await AdManager().requestAtt();
        debugPrint('ATT status: ${att.status.name}');
      } catch (e) {
        debugPrint('ATT skipped: $e');
      }
      // 2) Google UMP consent form for EEA/UK users — before the first ad request.
      try {
        final ump = await AdManager().requestUmpConsent();
        debugPrint('UMP: canRequestAds=${ump.canRequestAds}');
      } catch (e) {
        debugPrint('UMP skipped: $e');
      }
      if (!mounted) return;
      // 3) Initialize the SDK (fires the EventBus completion event).
      AdManager().initialize(
        config: DemoConfig.instance.build(),
        onComplete: (success, gaid) {},
      );
    });
  }

  void _showAppOpen() {
    AdManager().loadAppOpenAd(onAdLoaded: (loaded) {
      if (_navigated.value) return;
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
    if (_navigated.value) return;
    _navigated.value = true;
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
    _hardCap?.cancel();
    final cb = _listener;
    if (cb != null) SimpleEventBus().remove(cb);
    _navigated.dispose();
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

// ═══════════════════════════════════════════════════════════════════════════
// §4  Shared: DemoTile widget + edge-to-edge helpers
// ═══════════════════════════════════════════════════════════════════════════

/// Adds the system nav-bar inset to the bottom of [base] so the last item in a
/// scrollable isn't hidden behind the (transparent) Android nav bar in
/// edge-to-edge mode.
EdgeInsets _bottomSafe(BuildContext context, EdgeInsets base) {
  final inset = MediaQuery.paddingOf(context).bottom;
  return EdgeInsets.fromLTRB(
      base.left, base.top, base.right, base.bottom + inset);
}

class DemoTile extends StatelessWidget {
  const DemoTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.color = Colors.blue,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) => Card(
        elevation: 1,
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: color.withValues(alpha: 0.15),
            child: Icon(icon, color: color),
          ),
          title:
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.chevron_right, color: Colors.grey),
          onTap: onTap,
        ),
      );
}

// ═══════════════════════════════════════════════════════════════════════════
// §5  HomePage — list of all demos
// ═══════════════════════════════════════════════════════════════════════════

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ad_sdk demo'),
        backgroundColor: Colors.deepPurple,
        foregroundColor: Colors.white,
      ),
      // DebugAdOverlay is mounted at MaterialApp.builder so it floats over
      // every page, not just HomePage.
      body: ListView(
        padding: _bottomSafe(context, const EdgeInsets.symmetric(vertical: 8)),
        children: [
          DemoTile(
            icon: Icons.image,
            title: 'Banner ad',
            subtitle: 'Anchored adaptive banner with route lifecycle',
            color: Colors.blue,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const BannerDemoPage())),
          ),
          DemoTile(
            icon: Icons.fullscreen,
            title: 'Interstitial ad',
            subtitle: 'Show + safety gate + counter',
            color: Colors.indigo,
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const InterstitialDemoPage())),
          ),
          DemoTile(
            icon: Icons.star,
            title: 'Rewarded ad',
            subtitle: 'Show + reward + VIP auto-grant toggle',
            color: Colors.orange,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const RewardedDemoPage())),
          ),
          DemoTile(
            icon: Icons.open_in_new,
            title: 'App-open ad',
            subtitle: 'Background → foreground triggers',
            color: Colors.green,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const AppOpenDemoPage())),
          ),
          DemoTile(
            icon: Icons.workspace_premium,
            title: 'VIP / redeem',
            subtitle: 'Shared VipRedeemScreen (identical to host)',
            color: Colors.purple,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => VipRedeemScreen(
                  publicKeyBase64: kDemoVipPublicKey,
                  onPrivacyPolicyTap: () =>
                      debugPrint('[example] privacy policy tapped'),
                ),
              ),
            ),
          ),
          DemoTile(
            icon: Icons.science_outlined,
            title: 'VIP API playground',
            subtitle: 'Raw redeem / signed keys / watch-ad buttons',
            color: Colors.deepPurple,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const VipDemoPage())),
          ),
          DemoTile(
            icon: Icons.privacy_tip,
            title: 'Consent / GDPR',
            subtitle: 'Consent flags + provider propagation',
            color: Colors.teal,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const ConsentDemoPage())),
          ),
          DemoTile(
            icon: Icons.shield,
            title: 'Safety status',
            subtitle: 'Caps, throttle, dryRun mode, presets',
            color: Colors.red,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const SafetyDemoPage())),
          ),
          DemoTile(
            icon: Icons.terminal,
            title: 'Log viewer',
            subtitle: 'Ring buffer of SDK logs',
            color: Colors.grey,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const LogViewerDemoPage())),
          ),
          DemoTile(
            icon: Icons.attach_money,
            title: 'Revenue dashboard',
            subtitle: '\$ from onPaidEvent stream',
            color: Colors.lightGreen,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const RevenueDemoPage())),
          ),
          DemoTile(
            icon: Icons.dashboard,
            title: 'Slot state panel',
            subtitle: 'Live AdSlot state + manual destroy/reinit',
            color: Colors.cyan,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const StatePanelDemoPage())),
          ),
          DemoTile(
            icon: Icons.stream,
            title: 'AdEvent stream',
            subtitle: 'All load/show/click/reward/revenue events live',
            color: Colors.deepOrange,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const EventsDemoPage())),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// §6  Demo: Banner
// ═══════════════════════════════════════════════════════════════════════════

class BannerDemoPage extends AdScreen {
  const BannerDemoPage({super.key});

  @override
  State<BannerDemoPage> createState() => _BannerDemoPageState();
}

class _BannerDemoPageState extends AdScreenState<BannerDemoPage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Banner demo')),
      body: Column(
        children: [
          buildBanner(),
          Expanded(
            child: ListView(
              padding: _bottomSafe(context, EdgeInsets.zero),
              children: [
                ListTile(
                  leading: const Icon(Icons.navigate_next),
                  title:
                      const Text('Push another screen (verifies pause/resume)'),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const _BannerSecondScreen()),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Banner refreshes here. Push the second screen — banner '
                    'pauses on AppLovin / hides on AdMob. Pop back to resume.',
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BannerSecondScreen extends AdScreen {
  const _BannerSecondScreen();

  @override
  State<_BannerSecondScreen> createState() => _BannerSecondScreenState();
}

class _BannerSecondScreenState extends AdScreenState<_BannerSecondScreen> {
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Second route')),
        body: SafeArea(
          top: false,
          child: Column(children: [
            const Expanded(
                child: Center(child: Text('Banner pauses on previous'))),
            buildBanner(),
          ]),
        ),
      );
}

// ═══════════════════════════════════════════════════════════════════════════
// §7  Demo: Interstitial
// ═══════════════════════════════════════════════════════════════════════════

class InterstitialDemoPage extends AdScreen {
  const InterstitialDemoPage({super.key});

  @override
  State<InterstitialDemoPage> createState() => _InterstitialDemoPageState();
}

class _InterstitialDemoPageState extends AdScreenState<InterstitialDemoPage> {
  final ValueNotifier<int> _shownCount = ValueNotifier<int>(0);
  final ValueNotifier<String> _lastResult = ValueNotifier<String>('—');

  @override
  void dispose() {
    _shownCount.dispose();
    _lastResult.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Interstitial demo')),
      body: Padding(
        padding: _bottomSafe(context, const EdgeInsets.all(24)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ValueListenableBuilder<int>(
              valueListenable: _shownCount,
              builder: (_, c, __) => Text('Shown: $c times',
                  style: const TextStyle(
                      fontSize: 22, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 8),
            ValueListenableBuilder<String>(
              valueListenable: _lastResult,
              builder: (_, r, __) =>
                  Text('Last: $r', style: const TextStyle(color: Colors.grey)),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () {
                // `placement` tags the impression for revenue analytics — it
                // flows into `AdShowEvent.placement` / `AdRevenueEvent`. Use a
                // preset (home/shop/levelComplete/gameOver/settings) or
                // `AdPlacement.custom('my_screen')`.
                showInterstitialAd(
                  placement: AdPlacement.levelComplete,
                  onDone: (shown) {
                    _lastResult.value = shown ? 'shown ✅' : 'skipped/blocked ❌';
                    if (shown) _shownCount.value = _shownCount.value + 1;
                  },
                );
              },
              child: const Text('Show interstitial (placement: levelComplete)'),
            ),
            const SizedBox(height: 12),
            const Text(
              'SDK runs: pre-check (canShowInterstitial) → 1 s loading dialog → '
              'native show. If safety blocks, "skipped" returns immediately.',
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// §8  Demo: Rewarded
// ═══════════════════════════════════════════════════════════════════════════

class RewardedDemoPage extends AdScreen {
  const RewardedDemoPage({super.key});

  @override
  State<RewardedDemoPage> createState() => _RewardedDemoPageState();
}

class _RewardedDemoPageState extends AdScreenState<RewardedDemoPage> {
  final ValueNotifier<int> _coins = ValueNotifier<int>(0);
  final ValueNotifier<bool> _vipAutoGrant = ValueNotifier<bool>(false);
  final ValueNotifier<String> _last = ValueNotifier<String>('—');

  @override
  void dispose() {
    _coins.dispose();
    _vipAutoGrant.dispose();
    _last.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Rewarded demo')),
      body: Padding(
        padding: _bottomSafe(context, const EdgeInsets.all(24)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ValueListenableBuilder<int>(
              valueListenable: _coins,
              builder: (_, c, __) => Text('Coins: $c',
                  style: const TextStyle(
                      fontSize: 28, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 8),
            ValueListenableBuilder<String>(
              valueListenable: _last,
              builder: (_, r, __) =>
                  Text('Last: $r', style: const TextStyle(color: Colors.grey)),
            ),
            const SizedBox(height: 24),
            ValueListenableBuilder<bool>(
              valueListenable: _vipAutoGrant,
              builder: (_, on, __) => SwitchListTile(
                value: on,
                onChanged: (v) => _vipAutoGrant.value = v,
                title: const Text('VIP auto-grant'),
                subtitle: const Text(
                    'When VIP, auto-mark reward earned (Q12B: opt-in only).'),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () {
                showRewardedAd(
                  vipAutoGrant: _vipAutoGrant.value,
                  onEarnedReward: (earned) {
                    _last.value = earned ? 'earned 🏆' : 'skipped/blocked ❌';
                    if (earned) _coins.value = _coins.value + 10;
                  },
                );
              },
              child: const Text('Watch ad for +10 coins'),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// §9  Demo: App Open
// ═══════════════════════════════════════════════════════════════════════════

class AppOpenDemoPage extends StatelessWidget {
  const AppOpenDemoPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('App-open demo')),
      body: Padding(
        padding: _bottomSafe(context, const EdgeInsets.all(24)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'How to test:\n'
                  '1. Press the home button to background the app.\n'
                  '2. Wait > 5 s.\n'
                  '3. Tap the app icon to return — you should see the App Open ad.\n'
                  '\n'
                  'Cold start protection skips the very first foreground event.',
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () {
                AdManager().loadAppOpenAd(onAdLoaded: (loaded) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content:
                        Text(loaded ? 'App open ad ready ✅' : 'Load failed ❌'),
                  ));
                });
              },
              child: const Text('Force load App Open'),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// §10  Demo: VIP redeem (Cupertino dialog)
// ═══════════════════════════════════════════════════════════════════════════

class VipDemoPage extends StatefulWidget {
  const VipDemoPage({super.key});

  @override
  State<VipDemoPage> createState() => _VipDemoPageState();
}

class _VipDemoPageState extends State<VipDemoPage> {
  final TextEditingController _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _redeem(String key, Duration duration) async {
    final vip = AdManager().vip;
    if (vip == null) return;
    await vip.redeemVip(
      context,
      key: key,
      duration: duration,
      validator: AdManager().config?.vipKeyValidator,
      strings: AdManager().config?.vipDialogStrings ?? const VipDialogStrings(),
      // stack: true → global stacking: ADDS time on top of the latest expiry
      // across ALL VIP entries (cộng dồn toàn cục) instead of latest-wins.
      stack: true,
    );
  }

  /// T18 — redeem an offline SIGNED VIP key (Ed25519, verified against the
  /// embedded public key; no network; per-device one-time-use).
  Future<void> _redeemSigned(String code) async {
    final vip = AdManager().vip;
    if (vip == null) return;
    final r = await vip.redeemSignedKey(code,
        publicKeyBase64: kDemoVipPublicKey, stack: true);
    if (!mounted) return;
    final msg = switch (r.status) {
      VipRedeemStatus.success => '✅ Signed key OK — VIP granted',
      VipRedeemStatus.alreadyUsed => '⏭️ Key already used on this device',
      VipRedeemStatus.invalid => '❌ Invalid key: ${r.error}',
    };
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Watch a real rewarded ad to EXTEND VIP — works even while already VIP
  /// (`bypassVipGuard: true` plays a real ad; the SDK loads it on demand). The
  /// reward is granted into a fixed key with `stack: true` so repeats add up.
  Future<void> _watchAdToExtend() async {
    final vip = AdManager().vip;
    if (vip == null) return;
    AdManager().showRewardedAd(
      bypassVipGuard: true,
      onEarnedReward: (earned) {
        if (!earned) return;
        vip.addVip(
          key: 'REWARDED_VIP',
          duration: const Duration(days: 3),
          stack: true,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: AdManager().initRevision,
      builder: (context, _, __) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final vip = AdManager().vip;
    return Scaffold(
      appBar: AppBar(title: const Text('VIP demo')),
      body: ListView(
        padding: _bottomSafe(context, const EdgeInsets.all(16)),
        children: [
          // GAID allow-list — a second VIP mechanism alongside key redeem:
          // mark specific devices VIP by their Google Advertising ID. The
          // SUPPORTED way is the startup config `AdConfig.vipDeviceGaids:
          // ['gaid1', ...]` (auto-migrated to VipManager entries on first
          // init). `AdManager().isVIPMember()` reports the current state.
          // (The runtime add/deleteVIPMember mutators are deprecated — prefer
          // `AdManager().vip.addVip(...)` / `revokeVip(...)`.)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('GAID VIP allow-list',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  const Text(
                    'Set at startup via AdConfig.vipDeviceGaids: [...]. '
                    'Tap to read the live VIP state:',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: () {
                      final isVip = AdManager().isVIPMember();
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('isVIPMember() = $isVip')),
                      );
                    },
                    child: const Text('Check isVIPMember()'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          // Status card
          if (vip != null)
            ValueListenableBuilder<bool>(
              valueListenable: vip.activeListenable,
              builder: (_, active, __) {
                final exp = vip.expiresAt;
                return Card(
                  color: active ? Colors.purple.shade50 : Colors.grey.shade100,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          active ? '🟣 VIP active' : '⚪ VIP inactive',
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        if (active && exp != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                                'Until ${exp.toLocal().toIso8601String().substring(0, 16)}'),
                          ),
                        if (vip.entries.isNotEmpty) ...[
                          const Divider(),
                          const Text('Entries:',
                              style: TextStyle(fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                          ...vip.entries.map((e) => Text(
                                '• ${e.key} → ${e.expiresAt.toLocal().toIso8601String().substring(0, 16)}',
                                style: const TextStyle(fontSize: 12),
                              )),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
          const SizedBox(height: 16),

          // Quick redeem buttons
          const Text('Quick redeem',
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: kDemoVipKeys.entries
                .map((e) => OutlinedButton(
                      onPressed: () => _redeem(e.key, e.value),
                      child: Text('${e.key}\n(${e.value.inDays} days)',
                          textAlign: TextAlign.center),
                    ))
                .toList(),
          ),
          const SizedBox(height: 24),

          // T18 — signed offline keys (Ed25519). Redeeming twice shows the
          // per-device one-time-use guard ("already used").
          const Text('Signed keys (T18 — offline, forge-proof)',
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: kDemoSignedVipKeys.entries
                .map((e) => FilledButton.tonal(
                      onPressed: () => _redeemSigned(e.value),
                      child: Text('signed ${e.key}'),
                    ))
                .toList(),
          ),
          const SizedBox(height: 24),

          // Custom redeem
          const Text('Custom key (1-day duration)',
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  decoration: const InputDecoration(
                    hintText: 'enter key',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => _redeem(_ctrl.text, const Duration(days: 1)),
                child: const Text('Redeem'),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // Watch ad → +3 days VIP (stacks; works even while already VIP)
          const Text('Extend by watching an ad',
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _watchAdToExtend,
            icon: const Icon(Icons.play_circle_outline),
            label: const Text('Watch ad → +3 days VIP (stack)'),
          ),
          const SizedBox(height: 24),

          // Revoke
          FilledButton.tonal(
            onPressed: () async {
              await vip?.revokeAll();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('All VIP entries revoked')),
                );
              }
            },
            child: const Text('Revoke ALL'),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// §11  Demo: Consent / GDPR / COPPA / CCPA
// ═══════════════════════════════════════════════════════════════════════════

class ConsentDemoPage extends StatefulWidget {
  const ConsentDemoPage({super.key});

  @override
  State<ConsentDemoPage> createState() => _ConsentDemoPageState();
}

class _ConsentDemoPageState extends State<ConsentDemoPage> {
  final ValueNotifier<bool> _hasConsent = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _isAge = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _doNotSell = ValueNotifier<bool>(false);

  /// Bumped after setConsent so the "effective personalization" card below
  /// reflects the just-applied AdManager().consent state.
  final ValueNotifier<int> _appliedRev = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _hasConsent.value = AdManager().consent.hasUserConsent;
    _isAge.value = AdManager().consent.isAgeRestrictedUser;
    _doNotSell.value = AdManager().consent.doNotSell;
  }

  @override
  void dispose() {
    _hasConsent.dispose();
    _isAge.dispose();
    _doNotSell.dispose();
    _appliedRev.dispose();
    super.dispose();
  }

  Widget _row(String label, ValueNotifier<bool> n, String help) {
    return ValueListenableBuilder<bool>(
      valueListenable: n,
      builder: (_, on, __) => SwitchListTile(
        value: on,
        onChanged: (v) => n.value = v,
        title: Text(label),
        subtitle: Text(help),
      ),
    );
  }

  void _syncFromSdk() {
    _hasConsent.value = AdManager().consent.hasUserConsent;
    _isAge.value = AdManager().consent.isAgeRestrictedUser;
    _doNotSell.value = AdManager().consent.doNotSell;
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild + resync local toggles whenever SDK destroy/reinit fires.
    return ValueListenableBuilder<int>(
      valueListenable: AdManager().initRevision,
      builder: (context, _, __) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _syncFromSdk();
        });
        return _build(context);
      },
    );
  }

  Widget _build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Consent demo')),
      body: ListView(
        padding: _bottomSafe(context, EdgeInsets.zero),
        children: [
          _row('GDPR consent (hasUserConsent)', _hasConsent,
              'EEA users — set after UMP form ACCEPT.'),
          _row('Age-restricted (COPPA)', _isAge,
              'App targets children < 13 → tagForChildDirectedTreatment=YES.'),
          _row('Do-not-sell (CCPA)', _doNotSell,
              'California users opt-out of personal-data sale.'),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: FilledButton(
              onPressed: () async {
                await AdManager().setConsent(AdConsent(
                  hasUserConsent: _hasConsent.value,
                  isAgeRestrictedUser: _isAge.value,
                  doNotSell: _doNotSell.value,
                ));
                _appliedRev.value++;
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('Consent applied to both providers ✅')));
                }
              },
              child: const Text('Apply consent to providers'),
            ),
          ),
          const SizedBox(height: 12),
          // Effective per-request personalization (T02): AdMob attaches npa=1 to
          // every AdRequest when the applied consent has hasUserConsent=false.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ValueListenableBuilder<int>(
              valueListenable: _appliedRev,
              builder: (context, _, __) {
                final npa = !AdManager().consent.hasUserConsent;
                return Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: npa
                        ? Colors.orange.withValues(alpha: 0.12)
                        : Colors.green.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    npa
                        ? '📵 AdMob ad requests: NON-personalized (npa=1)'
                        : '🎯 AdMob ad requests: personalized',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                );
              },
            ),
          ),
          const Divider(height: 32),
          // ─── ConsentManager (Cupertino dialog) ──────────────────────────
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'ConsentManager — built-in Cupertino dialog (auto-shown post-splash on first launch)',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
          ),
          ValueListenableBuilder<ConsentSettings>(
            valueListenable: ConsentManager.instance.listenable,
            builder: (_, s, __) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Card(
                color: s.hasBeenAsked
                    ? Colors.green.shade50
                    : Colors.amber.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.hasBeenAsked
                            ? '✅ User has been asked'
                            : '⚠️ Not asked yet',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'consent=${s.hasUserConsent}  coppa=${s.isAgeRestrictedUser}  ccpa=${s.doNotSell}',
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 11),
                      ),
                      if (s.askedAt != null)
                        Text(
                            'askedAt=${s.askedAt!.toLocal().toIso8601String().substring(0, 19)}',
                            style: const TextStyle(
                                fontFamily: 'monospace', fontSize: 11)),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.help_outline),
                  label: const Text('Show consent dialog'),
                  onPressed: () async {
                    await ConsentManager.instance.showDialog(
                      context,
                      config: AdManager().config,
                    );
                  },
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reset (re-prompt next launch)'),
                  onPressed: () async {
                    await ConsentManager.instance
                        .reset(config: AdManager().config);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text(
                                'Consent reset — next init will re-prompt')),
                      );
                    }
                  },
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Note: the SDK auto-shows the binary dialog ~1s AFTER markSplashInactive '
              'on first launch (default behaviour, controlled by AdConfig.autoShowConsentDialog). '
              'iOS ATT prompt is still caller responsibility — see README.',
              style: TextStyle(color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// §12  Demo: Safety status + presets
// ═══════════════════════════════════════════════════════════════════════════

class SafetyDemoPage extends StatefulWidget {
  const SafetyDemoPage({super.key});

  @override
  State<SafetyDemoPage> createState() => _SafetyDemoPageState();
}

class _SafetyDemoPageState extends State<SafetyDemoPage> {
  final ValueNotifier<int> _refresh = ValueNotifier<int>(0);

  @override
  void dispose() {
    _refresh.dispose();
    super.dispose();
  }

  AdSafetyParams get _activeParams =>
      AdManager().config?.safety ?? AdSafetyParams.auto;

  Widget _paramsCard(String title, AdSafetyParams p, {Color? color}) {
    return Card(
      color: color,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            const SizedBox(height: 6),
            Text(
              'between=${p.minTimeBetweenFullscreenAds}ms\n'
              'session=${p.maxFullscreenAdsPerSession} / hour=${p.maxFullscreenAdsPerHour} / day=${p.maxFullscreenAdsPerDay}\n'
              'warmup=${p.minSessionDurationBeforeAd}ms / resume=${p.minTimeAppOpenResume}ms\n'
              'clicks/min=${p.maxClicksPerMinute} / ctr=${p.suspiciousCtrThreshold}\n'
              'rapidResume=${p.maxRapidResumesPerMinute} / dryRun=${p.dryRun}',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Wrap with initRevision so destroy/reinit refreshes _activeParams display.
    return ValueListenableBuilder<int>(
      valueListenable: AdManager().initRevision,
      builder: (context, _, __) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Safety demo')),
      body: ValueListenableBuilder<int>(
        valueListenable: _refresh,
        builder: (_, __, ___) => ListView(
          padding: _bottomSafe(context, const EdgeInsets.all(16)),
          children: [
            _paramsCard(
              'Active params (demo: same for debug + release)',
              _activeParams,
              color: Colors.blue.shade50,
            ),
            const SizedBox(height: 12),
            _paramsCard(
                'Preset: AdSafetyParams.production', AdSafetyParams.production),
            const SizedBox(height: 8),
            _paramsCard('Preset: AdSafetyParams.debug', AdSafetyParams.debug),
            const SizedBox(height: 8),
            const Card(
              child: Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'How to customize from your app:\n'
                  '\n'
                  '// 1) Use a built-in preset\n'
                  'safety: AdSafetyParams.debug\n'
                  '\n'
                  '// 2) Auto-pick (default — debug in dev, prod in release)\n'
                  'safety: AdSafetyParams.auto\n'
                  '\n'
                  '// 3) Override only the knobs you care about\n'
                  'safety: AdSafetyParams.production.copyWith(\n'
                  '  maxFullscreenAdsPerDay: 10,\n'
                  '  dryRun: kDebugMode,\n'
                  ')',
                  style: TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              ),
            ),
            const Divider(height: 24),
            const Text('Live status',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(AdSafetyConfig.getStatus(),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
            const SizedBox(height: 12),
            const Text('Latest fullscreen check',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Builder(builder: (_) {
              final r = AdSafetyConfig.canShowFullscreenAd();
              return Text(
                'canShow=${r.canShow}\nreason=${r.reason}',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              );
            }),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: () {
                AdSafetyConfig.resetSession();
                _refresh.value = _refresh.value + 1;
              },
              child: const Text('Reset session counters'),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () => _refresh.value = _refresh.value + 1,
              child: const Text('Refresh'),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// §13  Demo: Log viewer
// ═══════════════════════════════════════════════════════════════════════════

class LogViewerDemoPage extends StatelessWidget {
  const LogViewerDemoPage({super.key});

  Color _colorFor(AdLogLevel l) => switch (l) {
        AdLogLevel.verbose => Colors.grey,
        AdLogLevel.warning => Colors.orange,
        AdLogLevel.error => Colors.red,
        AdLogLevel.none => Colors.black,
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Log viewer'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed: () => LogBuffer.instance.clear(),
            tooltip: 'Clear',
          ),
        ],
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: LogBuffer.instance.revision,
        builder: (_, __, ___) {
          final entries = LogBuffer.instance.snapshot();
          if (entries.isEmpty) {
            return const Center(child: Text('(no logs yet)'));
          }
          return ListView.builder(
            reverse: true,
            padding: _bottomSafe(context, EdgeInsets.zero),
            itemCount: entries.length,
            itemBuilder: (_, i) {
              final e = entries[entries.length - 1 - i];
              final time = e.timestamp.toIso8601String().substring(11, 19);
              return Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(time,
                        style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 10,
                            color: Colors.grey)),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(
                        color: _colorFor(e.level).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(2),
                      ),
                      child: Text(e.level.name.toUpperCase(),
                          style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 9,
                              color: _colorFor(e.level),
                              fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text('[${e.tag}] ${e.message}',
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 11)),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// §14  Demo: Revenue dashboard
// ═══════════════════════════════════════════════════════════════════════════

class RevenueDemoPage extends StatelessWidget {
  const RevenueDemoPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Revenue dashboard')),
      body: Padding(
        padding: _bottomSafe(context, const EdgeInsets.all(16)),
        child: const Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            RevenuePanel(),
            SizedBox(height: 16),
            Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Revenue is reported by AdMob/AppLovin via the OnPaidEvent '
                  'hook on each impression. The dashboard subscribes to '
                  'AdManager().events and accumulates AdRevenueEvent values.\n'
                  '\n'
                  'Pipe the same stream into your Firebase / AppsFlyer LTV '
                  'tracking — see README.',
                  style: TextStyle(color: Colors.grey),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// §15  Demo: Slot state panel
// ═══════════════════════════════════════════════════════════════════════════

class StatePanelDemoPage extends StatelessWidget {
  const StatePanelDemoPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: AdManager().initRevision,
      builder: (context, _, __) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final adapter = AdManager().adapter;
    return Scaffold(
      appBar: AppBar(title: const Text('Slot state panel')),
      body: adapter == null
          ? const Center(child: Text('SDK not initialised yet'))
          : ListView(
              padding: _bottomSafe(context, const EdgeInsets.all(16)),
              children: [
                Text('Provider: ${adapter.tag}',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 18)),
                const SizedBox(height: 12),
                _slotCard('App Open', adapter.appOpenSlot),
                _slotCard('Interstitial', adapter.interstitialSlot),
                _slotCard('Rewarded', adapter.rewardedSlot),
                _slotCard('Banner', adapter.bannerSlot),
                const Divider(height: 32),
                const Text(
                  'Lifecycle test',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                FilledButton.tonal(
                  onPressed: () async {
                    await AdManager().destroy();
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text('SDK destroyed — adapter null')),
                      );
                    }
                  },
                  child: const Text('Destroy SDK'),
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: () async {
                    await AdManager().initialize(
                      config: DemoConfig.instance.build(),
                      onComplete: (_, __) {},
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('SDK re-initialized')),
                      );
                    }
                  },
                  child: const Text('Re-initialize SDK'),
                ),
              ],
            ),
    );
  }

  Widget _slotCard(String label, AdSlot slot) {
    return ValueListenableBuilder<AdSlotState>(
      valueListenable: slot.state,
      builder: (_, state, __) => Card(
        child: ListTile(
          title: Text(label),
          subtitle: Text(
            'state=${state.name}\n'
            'fails=${slot.consecutiveFailures}\n'
            'lastError=${slot.lastErrorAt?.toIso8601String() ?? '—'}\n'
            'lastLoaded=${slot.lastLoadedAt?.toIso8601String() ?? '—'}',
          ),
          trailing: _badge(state),
        ),
      ),
    );
  }

  Widget _badge(AdSlotState s) {
    final color = switch (s) {
      AdSlotState.idle => Colors.grey,
      AdSlotState.loading => Colors.blue,
      AdSlotState.ready => Colors.green,
      AdSlotState.showing => Colors.purple,
      AdSlotState.cooldown => Colors.orange,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(s.name,
          style: TextStyle(color: color, fontWeight: FontWeight.bold)),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// §16  Demo: AdEvent stream live viewer
// ═══════════════════════════════════════════════════════════════════════════

class EventsDemoPage extends StatefulWidget {
  const EventsDemoPage({super.key});
  @override
  State<EventsDemoPage> createState() => _EventsDemoPageState();
}

class _EventsDemoPageState extends State<EventsDemoPage> {
  /// Ring buffer of last N events. Bumped via revision so the list view
  /// only rebuilds once per push (cheap).
  static const int _max = 100;
  final List<_EventRow> _rows = [];
  final ValueNotifier<int> _rev = ValueNotifier<int>(0);
  StreamSubscription<AdEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = AdManager().events.listen((event) {
      if (!mounted) return;
      _rows.insert(0, _EventRow(DateTime.now(), event));
      if (_rows.length > _max) _rows.removeLast();
      _rev.value = _rev.value + 1;
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _sub = null;
    _rev.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AdEvent stream'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete),
            tooltip: 'Clear',
            onPressed: () {
              _rows.clear();
              _rev.value = _rev.value + 1;
            },
          ),
        ],
      ),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'Tap any other demo (banner, inter, rewarded, app-open) and '
              'come back — every load/show/click/reward/revenue event from '
              'the SDK is logged here in real time.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ValueListenableBuilder<int>(
              valueListenable: _rev,
              builder: (_, __, ___) {
                if (_rows.isEmpty) {
                  return const Center(
                    child: Text('(no events yet — trigger an ad somewhere)',
                        style: TextStyle(color: Colors.grey)),
                  );
                }
                return ListView.separated(
                  padding: _bottomSafe(context, EdgeInsets.zero),
                  itemCount: _rows.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final row = _rows[i];
                    return _EventTile(row: row);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _EventRow {
  _EventRow(this.timestamp, this.event);
  final DateTime timestamp;
  final AdEvent event;
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.row});
  final _EventRow row;

  @override
  Widget build(BuildContext context) {
    final e = row.event;
    final time = row.timestamp.toIso8601String().substring(11, 19);
    final (label, color, detail) = _describe(e);
    return ListTile(
      dense: true,
      leading: Container(
        width: 56,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(4),
        ),
        padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
        child: Text(label,
            style: TextStyle(
                color: color,
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace',
                fontSize: 10)),
      ),
      title: Text(
        '${e.providerTag} ${e.type.name} @${e.placement.id}',
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
      ),
      subtitle: Text(
        '$time  $detail',
        style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
      ),
    );
  }

  (String, Color, String) _describe(AdEvent e) {
    if (e is AdLoadEvent) {
      return (
        e.success ? 'LOAD✓' : 'LOAD✗',
        e.success ? Colors.blue : Colors.red,
        e.success ? 'loaded' : 'errCode=${e.errorCode ?? '?'}',
      );
    }
    if (e is AdShowEvent) {
      return (
        e.success ? 'SHOW✓' : 'SHOW✗',
        e.success ? Colors.green : Colors.orange,
        e.success ? 'shown' : 'skipped',
      );
    }
    if (e is AdClickEvent) return ('CLICK', Colors.purple, 'user clicked');
    if (e is AdRewardEvent) {
      return (
        'REWARD',
        Colors.amber.shade700,
        '${e.label ?? '?'} × ${e.amount ?? 0}'
      );
    }
    if (e is AdRevenueEvent) {
      return (
        'REV \$',
        Colors.teal,
        '\$${e.value.toStringAsFixed(6)} ${e.currencyCode}'
            '${e.networkName != null ? ' via ${e.networkName}' : ''}',
      );
    }
    return ('?', Colors.grey, '');
  }
}
