// ═══════════════════════════════════════════════════════════════════════════
// applovin_admob_sdk — example app, single file by design.
//
// Every demo page lives in this one file on purpose: pub.dev's "Example"
// tab on https://pub.dev/packages/applovin_admob_sdk/example renders only
// the example app's entry-point .dart file, not files it imports/exports —
// so a visitor evaluating the package before installing it only ever sees
// whatever main.dart itself contains. Splitting demos into separate files
// (T117) is a good repo-hygiene move for day-to-day editing but makes the
// package look unfinished on pub.dev, since the tab then shows a ~90-line
// stub of import/export statements instead of any working demo code.
// Kept as one file after that tradeoff was made explicit — length is an
// accepted cost, not an oversight; do not re-split without checking this
// tradeoff still holds.
//
// Sections below, in order: main()/navigator key, config (provider + ad
// unit IDs), shared widgets/state (LogBuffer, EventBuffer, layout helpers,
// DemoTile, HomePage), the splash screen, then one demo page per ad
// surface/feature (Banner, MREC, Native, Interstitial, Rewarded, Rewarded
// Interstitial, App Open, Adaptive surface, VIP, Consent, Compliance,
// Diagnostics, Events, Log viewer, Revenue, Safety, State panel, Test
// device hash).
//
// Provider (AdMob vs AppLovin) is chosen ONCE at app startup via
// `AdConfig.provider` and is **not** swappable at runtime. Default is
// AppLovin; pass --dart-define=AD_PROVIDER_ADMOB=true to build/test the
// AdMob path instead (see kProvider below).
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:async';
import 'dart:convert' show JsonEncoder;
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
// T146 demo only — IabStorage is an internal implementation detail, not part
// of the package's public API (a real consuming app has no access to it
// either). Imported here solely so ConsentDemoPage's "Simulate broken
// privacy store" button can prove the fail-closed fix against the real
// class, not a re-implementation of it.
// ignore: implementation_imports
import 'package:applovin_admob_sdk/src/core/iab_storage.dart';
import 'package:applovin_max/applovin_max.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:shared_preferences/shared_preferences.dart' show SharedPreferencesAsync;

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
  // Round-27 backlog B5 — destroy() closes AdManager().events and opens a
  // FRESH stream on the next initialize() (T31). A subscription taken out
  // once here, at startup, receives `done` on that first destroy() and
  // never follows the new stream — the "Slot state panel" demo's own
  // Destroy/Re-initialize buttons silently killed the Event stream/Revenue
  // dashboard pages for the rest of the run. Rebind on every initRevision
  // change (already the SDK's own signal for "adapter/session identity
  // changed", used elsewhere in this file) instead of subscribing once.
  StreamSubscription<AdEvent>? eventBufferSub;
  void rebindEventBuffer() {
    eventBufferSub?.cancel();
    eventBufferSub = AdManager().events.listen(EventBuffer.instance.onEvent);
  }

  rebindEventBuffer();
  AdManager().initRevision.addListener(rebindEventBuffer);
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

// ─────────────────────────────────────────────────────────────────────────
// config/demo_config.dart
// ─────────────────────────────────────────────────────────────────────────

// T117 — DemoConfig + example-only constants (AppLovin placeholder ad-unit
// IDs, VIP demo keys, safety preset). Split out of main.dart.

// ═══════════════════════════════════════════════════════════════════════════
// §1  Constants + DemoConfig + VIP validator
// ═══════════════════════════════════════════════════════════════════════════

// T41 — no real AppLovin credentials are committed to source. Placeholders
// below make the demo build/run out of the box (native init simply fails to
// load real creative — safe default, not a crash). Anyone who needs to
// exercise real ads locally passes their own IDs via --dart-define, e.g.:
//   flutter run --dart-define=APPLOVIN_SDK_KEY=... \
//     --dart-define=APPLOVIN_BANNER_ID_ANDROID=... \
//     --dart-define=APPLOVIN_BANNER_ID_IOS=... (…and _INTERSTITIAL_/_APPOPEN_/_REWARDED_ for each platform)
// See README.md "Compliance checklist".
const String _kAppLovinSdkKey = String.fromEnvironment('APPLOVIN_SDK_KEY',
    defaultValue: 'YOUR_86_CHAR_SDK_KEY_FROM_APPLOVIN_DASHBOARD');
final String _kAppLovinBannerId = Platform.isIOS
    ? const String.fromEnvironment('APPLOVIN_BANNER_ID_IOS',
        defaultValue: 'YOUR_BANNER_AD_UNIT_ID')
    : const String.fromEnvironment('APPLOVIN_BANNER_ID_ANDROID',
        defaultValue: 'YOUR_BANNER_AD_UNIT_ID');
final String _kAppLovinInterstitialId = Platform.isIOS
    ? const String.fromEnvironment('APPLOVIN_INTERSTITIAL_ID_IOS',
        defaultValue: 'YOUR_INTERSTITIAL_AD_UNIT_ID')
    : const String.fromEnvironment('APPLOVIN_INTERSTITIAL_ID_ANDROID',
        defaultValue: 'YOUR_INTERSTITIAL_AD_UNIT_ID');
final String _kAppLovinAppOpenId = Platform.isIOS
    ? const String.fromEnvironment('APPLOVIN_APPOPEN_ID_IOS',
        defaultValue: 'YOUR_APP_OPEN_AD_UNIT_ID')
    : const String.fromEnvironment('APPLOVIN_APPOPEN_ID_ANDROID',
        defaultValue: 'YOUR_APP_OPEN_AD_UNIT_ID');
final String _kAppLovinRewardedId = Platform.isIOS
    ? const String.fromEnvironment('APPLOVIN_REWARDED_ID_IOS',
        defaultValue: 'YOUR_REWARDED_AD_UNIT_ID')
    : const String.fromEnvironment('APPLOVIN_REWARDED_ID_ANDROID',
        defaultValue: 'YOUR_REWARDED_AD_UNIT_ID');
final String _kAppLovinMrecId = Platform.isIOS
    ? const String.fromEnvironment('APPLOVIN_MREC_ID_IOS',
        defaultValue: 'YOUR_MREC_AD_UNIT_ID')
    : const String.fromEnvironment('APPLOVIN_MREC_ID_ANDROID',
        defaultValue: 'YOUR_MREC_AD_UNIT_ID');
final String _kAppLovinNativeId = Platform.isIOS
    ? const String.fromEnvironment('APPLOVIN_NATIVE_ID_IOS',
        defaultValue: 'YOUR_NATIVE_AD_UNIT_ID')
    : const String.fromEnvironment('APPLOVIN_NATIVE_ID_ANDROID',
        defaultValue: 'YOUR_NATIVE_AD_UNIT_ID');

/// Provider for this app — defaults to `AdProvider.appLovin` since AppLovin is
/// the harder-to-exercise path (AdMob demo IDs are Google's public test
/// units; AppLovin needs real per-account IDs passed via --dart-define, see
/// above). Do not change this default to `AdProvider.admob` in source.
///
/// For integration-test runs that need to exercise the AdMob path, pass
/// `--dart-define=AD_PROVIDER_ADMOB=true` instead of editing this constant.
///
/// F8 — this `--dart-define` compile-time switch is a dev/test convenience
/// specific to this example app. Don't copy it verbatim into a real app: a
/// production app almost always hard-codes one provider (or picks it from a
/// remote config it controls), not an env flag toggled at build time.
const AdProvider kProvider = bool.fromEnvironment('AD_PROVIDER_ADMOB')
    ? AdProvider.admob
    : AdProvider.appLovin;

/// T41 — the loose QA safety preset ([kDemoSafetyParams]) is opt-in only, so
/// a release build of this example never ships with fraud/frequency caps
/// disabled. Pass `--dart-define=QA_AD_STRESS=true` to enable it locally.
const bool kQaAdStress = bool.fromEnvironment('QA_AD_STRESS');

// QA seam for the EEA consent path. Without it, a tester outside the EEA can
// never reach UMP's `required` branch: UMP resolves `notRequired`, no form is
// served, and every EEA-only code path stays unexercised (that blind spot is
// what let two consent bugs ship). `UMP_TEST_ID` is the hashed device id UMP
// prints to the log on first run — required, or debugGeography is ignored.
//   flutter run --dart-define=UMP_EEA_DEBUG=true --dart-define=UMP_TEST_ID=<hash>
const bool kUmpEeaDebug = bool.fromEnvironment('UMP_EEA_DEBUG');
const String kUmpTestId = String.fromEnvironment('UMP_TEST_ID');

/// Placeholder privacy-policy link shown by the consent dialog demo.
/// Real apps should point this at their own published policy.
const String kDemoPrivacyPolicyUrl = 'https://example.com/privacy';

/// VIP demo keys (Q28 — user-supplied).
const Map<String, Duration> kDemoVipKeys = {
  'TEST_VIP_7': Duration(days: 7),
  'TEST_VIP_30': Duration(days: 30),
  'TEST_VIP_90': Duration(days: 90),
};

/// ⚠️ DEMO KEYPAIR — DO NOT SHIP THIS.
///
/// This public key and the signed codes below are published in the SDK's
/// example app, so they are public knowledge: any app that ships this exact
/// public key grants VIP to anyone who pastes one of the demo codes.
///
/// Before releasing an app, generate your own keypair with
/// `dart run tool/vip_keygen.dart`, keep the PRIVATE key off the repo, and
/// mint real codes with `dart run tool/vip_mint.dart`. Only the public key
/// belongs in your binary.
///
/// T18 — offline SIGNED VIP keys. The public key below verifies the keys; the
/// matching private key (never shipped) minted them via tool/vip_mint.dart.
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
        // Round-31 audit fix (MAJOR) — MREC is a banner at a different
        // size (see mrec_ad_widget.dart), not a distinct AdMob ad format,
        // so it must use the BANNER test id, not the Native Advanced one
        // this line and `nativeId` below were both wrongly sharing.
        mrecId: 'ca-app-pub-3940256099942544/6300978111',
        nativeId: 'ca-app-pub-3940256099942544/2247696110',
        // Round-31 audit fix (MAJOR) — Rewarded Interstitial is AdMob-only
        // (see README); without this the dedicated demo page for it
        // (added specifically to close this coverage gap) could never
        // show an ad on the one provider that supports the format at all.
        rewardedInterstitialId: 'ca-app-pub-3940256099942544/5354046379',
        // Optional per-platform overrides (T15) — omit to use the same id
        // on both platforms, as above:
        // androidBannerId: 'ca-app-pub-.../android-banner',
        // iosBannerId: 'ca-app-pub-.../ios-banner',
      ),
      appLovin: AppLovinConfig(
        sdkKey: _kAppLovinSdkKey,
        bannerId: _kAppLovinBannerId,
        interstitialId: _kAppLovinInterstitialId,
        appOpenId: _kAppLovinAppOpenId,
        rewardedId: _kAppLovinRewardedId,
        mrecId: _kAppLovinMrecId,
        nativeId: _kAppLovinNativeId,
      ),
      // Verbose logs include the raw device advertising ID (GAID) — keep
      // this off release builds, matching AdConfig's own safe default.
      logLevel: kDebugMode ? AdLogLevel.verbose : AdLogLevel.warning,
      onLog: LogBuffer.instance.sink,
      vipKeyValidator: demoVipValidator,
      // Cap the total stacked VIP window (cộng dồn) — demo at 90 days. null = uncapped.
      maxVipStackDuration: const Duration(days: 90),
      adNotReadyMessage: 'Ad not ready — please wait.',
      adLoadingMessage: 'Loading…',
      splashMaxDuration: const Duration(seconds: 8),
      umpDebugGeography: kUmpEeaDebug ? DebugGeography.debugGeographyEea : null,
      umpTestIdentifiers: kUmpTestId.isEmpty ? const [] : const [kUmpTestId],
      // T41 — the loose preset (999 caps, 2 s throttle, 0 s warm-up) only
      // applies with --dart-define=QA_AD_STRESS=true, so QA can pound the
      // buttons on demand without every debug/release build shipping with
      // fraud/frequency caps effectively disabled.
      // ⚠️ DO NOT copy kDemoSafetyParams into a production app — use
      // AdSafetyParams.auto (default) or AdSafetyParams.production there.
      safety: kQaAdStress ? kDemoSafetyParams : AdSafetyParams.auto,
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
      // Demo wires a real privacy-policy URL so the dialog's link isn't
      // silently hidden — a bare `debugPrint` handler is enough here since
      // this is a demo harness, not a shipping app (a real app would
      // `launchUrl(Uri.parse(url))`, e.g. via package:url_launcher).
      consentDialogStrings:
          const ConsentDialogStrings(privacyPolicyUrl: kDemoPrivacyPolicyUrl),
      onPrivacyPolicyTap: (url) =>
          debugPrint('[example] privacy policy tapped: $url'),
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

// ─────────────────────────────────────────────────────────────────────────
// shared/log_buffer.dart
// ─────────────────────────────────────────────────────────────────────────

// T117 — in-memory ring buffer of SDK logs, feeding LogViewerDemoPage.
// Split out of main.dart.

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

// ─────────────────────────────────────────────────────────────────────────
// shared/event_buffer.dart
// ─────────────────────────────────────────────────────────────────────────

// T117 — in-memory ring buffer of AdEvent stream entries, feeding
// EventsDemoPage. Split out of main.dart. EventRow lives here (not in
// demos/events_demo_page.dart) since EventBuffer constructs it directly.

class EventBuffer {
  EventBuffer._();

  static final EventBuffer instance = EventBuffer._();

  static const int _maxEntries = 100;
  final List<EventRow> _rows = [];

  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  void onEvent(AdEvent event) {
    _rows.insert(0, EventRow(DateTime.now(), event));
    if (_rows.length > _maxEntries) _rows.removeLast();
    revision.value = revision.value + 1;
  }

  List<EventRow> snapshot() => List.unmodifiable(_rows);

  void clear() {
    _rows.clear();
    revision.value = revision.value + 1;
  }
}

class EventRow {
  EventRow(this.timestamp, this.event);
  final DateTime timestamp;
  final AdEvent event;
}

// ─────────────────────────────────────────────────────────────────────────
// shared/layout_helpers.dart
// ─────────────────────────────────────────────────────────────────────────

// T117 — edge-to-edge layout helper shared by every demo page. Split out of
// main.dart (used to be private to that one file; now needs to be public
// since it's called from many files).

/// Adds the system nav-bar inset to the bottom of [base] so the last item in
/// a scrollable isn't hidden behind the (transparent) Android nav bar in
/// edge-to-edge mode.
EdgeInsets bottomSafe(BuildContext context, EdgeInsets base) {
  final inset = MediaQuery.paddingOf(context).bottom;
  return EdgeInsets.fromLTRB(
      base.left, base.top, base.right, base.bottom + inset);
}

// ─────────────────────────────────────────────────────────────────────────
// shared/demo_tile.dart
// ─────────────────────────────────────────────────────────────────────────

// T117 — HomePage's list-tile widget. Split out of main.dart.

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

// ─────────────────────────────────────────────────────────────────────────
// shared/home_page.dart
// ─────────────────────────────────────────────────────────────────────────

// T117 — top-level list of all demos. Split out of main.dart.

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
        padding: bottomSafe(context, const EdgeInsets.symmetric(vertical: 8)),
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
            icon: Icons.crop_landscape,
            title: 'MREC ad',
            subtitle: 'Fixed 300x250 rectangle with route lifecycle',
            color: Colors.blueGrey,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const MrecDemoPage())),
          ),
          DemoTile(
            icon: Icons.aspect_ratio,
            title: 'Adaptive surface (T124)',
            subtitle: 'One widget picks banner vs MREC by width',
            color: Colors.teal,
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const AdaptiveSurfaceDemoPage())),
          ),
          DemoTile(
            icon: Icons.view_agenda,
            title: 'Native ad',
            subtitle: 'AdMob template vs AppLovin custom layout',
            color: Colors.brown,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const NativeDemoPage())),
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
            icon: Icons.stars,
            title: 'Rewarded interstitial ad',
            subtitle: 'Disclosure screen + show + reward',
            color: Colors.deepOrange,
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const RewardedInterstitialDemoPage())),
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
                  onPrivacyOptionsTap: () => AdManager().showPrivacyOptions(),
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
          DemoTile(
            icon: Icons.fact_check,
            title: 'Compliance report',
            subtitle: 'Export event log + safety + consent snapshot (T23)',
            color: Colors.brown,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const ComplianceDemoPage())),
          ),
          DemoTile(
            icon: Icons.health_and_safety,
            title: 'Diagnostics & self-check',
            subtitle:
                'Waterfall/fill-rate/arbitrator snapshot + debug checklist',
            color: Colors.teal,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const DiagnosticsDemoPage())),
          ),
          DemoTile(
            icon: Icons.fingerprint,
            title: 'AdMob test-device hash',
            subtitle: 'GAID vs the logcat-only AdMob test-device hash',
            color: Colors.pink,
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const TestDeviceHashDemoPage())),
          ),
          DemoTile(
            icon: Icons.cloud_sync,
            title: 'Remote safety provider (T88)',
            subtitle: 'RemoteAdSafetyProvider — live push, no app release',
            color: Colors.indigo,
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const RemoteSafetyDemoPage())),
          ),
          DemoTile(
            icon: Icons.rocket_launch,
            title: 'Splash shortcut (T94)',
            subtitle: 'AdReadinessSplashController — the same flow, wrapped',
            color: Colors.deepPurple,
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const ReadinessControllerDemoPage())),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// bootstrap/splash_screen.dart
// ─────────────────────────────────────────────────────────────────────────

// T117 — SDK init splash screen (ATT/UMP-aware). Split out of main.dart.

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
        // Round-32 audit fix (MAJOR) — `_hardCap` is only cancelled a few
        // lines below (AFTER this buffer wait), so it can still fire and
        // call `_goHome()` (`_navigated = true`, pushReplacement to
        // HomePage) WHILE this buffer is running. `mounted` alone doesn't
        // catch that: the old route's State stays mounted through the
        // transition, so without `_navigated` here the App Open ad still
        // gets shown right after the user is already on HomePage.
        if (!mounted || _navigated) {
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

// ─────────────────────────────────────────────────────────────────────────
// demos/adaptive_surface_demo_page.dart
// ─────────────────────────────────────────────────────────────────────────

// T124 — AdaptiveAdSurface demo. Drag the slider to change the surface's
// own width and watch it flip between banner and MREC at the 600pt
// breakpoint (after the resize debounce settles).

class AdaptiveSurfaceDemoPage extends StatefulWidget {
  const AdaptiveSurfaceDemoPage({super.key});

  @override
  State<AdaptiveSurfaceDemoPage> createState() =>
      _AdaptiveSurfaceDemoPageState();
}

class _AdaptiveSurfaceDemoPageState extends State<AdaptiveSurfaceDemoPage> {
  double _width = 320;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Adaptive surface demo')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Width: ${_width.round()}pt — banner below 600pt, MREC at/above.',
            ),
          ),
          Slider(
            min: 300,
            max: 800,
            value: _width,
            onChanged: (v) => setState(() => _width = v),
          ),
          Center(
            child: SizedBox(
              width: _width,
              child: const AdaptiveAdSurface(
                placement: AdPlacement.home,
                resizeDebounce: Duration(milliseconds: 200),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// demos/app_open_demo_page.dart
// ─────────────────────────────────────────────────────────────────────────

// T117 — app open demo page. Split out of main.dart.

class AppOpenDemoPage extends StatelessWidget {
  const AppOpenDemoPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('App-open demo')),
      body: Padding(
        padding: bottomSafe(context, const EdgeInsets.all(24)),
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
                  // Round-31 audit fix (MAJOR) — loadAppOpenAd() is async
                  // (a real network load); every other async-then-context
                  // use in this file guards with `context.mounted` — this
                  // one didn't, so backing out before the load finishes
                  // threw "Looking up a deactivated widget's ancestor is
                  // unsafe". This is demo/sample code other apps copy, so
                  // the omission would have spread.
                  if (!context.mounted) return;
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

// ─────────────────────────────────────────────────────────────────────────
// demos/banner_demo_page.dart
// ─────────────────────────────────────────────────────────────────────────

// T117 — banner demo page. Split out of main.dart.

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
              padding: bottomSafe(context, EdgeInsets.zero),
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
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    'Second instance below — proves both banners load and '
                    'refresh independently (T65 keyed-by-instance).',
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
                buildBanner(),
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

// ─────────────────────────────────────────────────────────────────────────
// demos/compliance_demo_page.dart
// ─────────────────────────────────────────────────────────────────────────

// T117 — compliance demo page. Split out of main.dart.

class ComplianceDemoPage extends StatefulWidget {
  const ComplianceDemoPage({super.key});

  @override
  State<ComplianceDemoPage> createState() => _ComplianceDemoPageState();
}

class _ComplianceDemoPageState extends State<ComplianceDemoPage> {
  String? _reportJson;
  String _summary = '';

  void _generate() {
    final report = AdManager().exportComplianceReport();
    setState(() {
      _summary = '${report.events.length} event(s) in log';
      _reportJson = report.toJsonString(pretty: true);
    });
  }

  // T144 — the 3 signed exports AdManager already had, bundled into one
  // artifact for a dispute/appeal, instead of a host calling 3 methods and
  // gluing the JSON together itself.
  Future<void> _generateDisputeKit() async {
    final kit = await AdManager().exportDisputeKit();
    if (!mounted) return;
    setState(() {
      _summary = 'dispute kit: compliance + bypass audit trail + incident '
          'bundle, all signed';
      _reportJson = kit.toJsonString(pretty: true);
    });
  }

  void _copy() {
    final json = _reportJson;
    if (json == null) return;
    Clipboard.setData(ClipboardData(text: json));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Report JSON copied to clipboard')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final json = _reportJson;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Compliance report'),
        actions: [
          if (json != null)
            IconButton(
              icon: const Icon(Icons.copy),
              tooltip: 'Copy JSON',
              onPressed: _copy,
            ),
        ],
      ),
      body: Padding(
        padding: bottomSafe(context, const EdgeInsets.all(16)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Combines the persisted ad event log, safety status snapshot, '
              'consent flags and VIP state into one JSON document — hand to '
              'a partner/reviewer as evidence of policy compliance.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _generate,
              icon: const Icon(Icons.description_outlined),
              label: const Text('Generate report'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _generateDisputeKit,
              icon: const Icon(Icons.gavel_outlined),
              label: const Text('Generate dispute kit (T144)'),
            ),
            const SizedBox(height: 12),
            if (json == null)
              const Expanded(
                child: Center(child: Text('(no report generated yet)')),
              )
            else
              Expanded(
                child: Card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(_summary,
                            style:
                                const TextStyle(fontWeight: FontWeight.bold)),
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(12),
                          child: SelectableText(
                            json,
                            style: const TextStyle(
                                fontFamily: 'monospace', fontSize: 11),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// demos/consent_demo_page.dart
// ─────────────────────────────────────────────────────────────────────────

// T117 — consent demo page. Split out of main.dart.

class ConsentDemoPage extends StatefulWidget {
  const ConsentDemoPage({super.key});

  @override
  State<ConsentDemoPage> createState() => _ConsentDemoPageState();
}

class _ConsentDemoPageState extends State<ConsentDemoPage> {
  final ValueNotifier<bool> _hasConsent = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _isAge = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _doNotSell = ValueNotifier<bool>(false);
  final TextEditingController _countryController = TextEditingController();

  /// Bumped after setConsent so the "effective personalization" card below
  /// reflects the just-applied AdManager().consent state.
  final ValueNotifier<int> _appliedRev = ValueNotifier<int>(0);

  // T146 demo state — see [_simulateBrokenPrivacyStore] below.
  String? _t146Result;
  bool _t146Busy = false;

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
    _countryController.dispose();
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

  /// T146 — proves `IabStorage.usPrivacyOptedOut()` fails CLOSED (returns
  /// `true`) when the platform preference store cannot be read, instead of
  /// silently returning `null` (which every real caller treats as "no
  /// signal", i.e. NOT an opt-out).
  ///
  /// Uses `IabStorage.debugOpenOverride` — the SDK's own `IabStorage`-scoped
  /// test seam (same one `us_privacy_fail_closed_test.dart` uses) — rather
  /// than swapping the process-wide `SharedPreferencesAsyncPlatform.instance`
  /// singleton: an independent `codex` re-review caught that the wider swap
  /// would also break any OTHER plugin/package reading shared_preferences
  /// during this window (host-app code, other SDKs), not just this demo's
  /// own read.
  Future<void> _simulateBrokenPrivacyStore() async {
    setState(() {
      _t146Busy = true;
      _t146Result = null;
    });
    // ignore: invalid_use_of_visible_for_testing_member
    IabStorage.debugOpenOverride = () => Future<SharedPreferencesAsync?>.error(
        PlatformException(code: 'CHANNEL_ERROR', message: 'store is gone'));
    // ignore: invalid_use_of_visible_for_testing_member
    IabStorage.debugResetForTest();
    try {
      final result = await IabStorage.usPrivacyOptedOut();
      if (!mounted) return;
      setState(() {
        _t146Result = result == true
            ? '✅ true (fail-closed — treated as opted-out)'
            : '❌ $result (BUG — should be true, see T146)';
      });
    } finally {
      // ignore: invalid_use_of_visible_for_testing_member
      IabStorage.debugOpenOverride = null;
      // ignore: invalid_use_of_visible_for_testing_member
      IabStorage.debugResetForTest();
      if (mounted) setState(() => _t146Busy = false);
    }
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
        padding: bottomSafe(context, EdgeInsets.zero),
        children: [
          _row('GDPR consent (hasUserConsent)', _hasConsent,
              'EEA users — set after UMP form ACCEPT.'),
          _row('Age-restricted (COPPA)', _isAge,
              'App targets children < 13 → tagForChildDirectedTreatment=YES.'),
          _row('Do-not-sell (CCPA)', _doNotSell,
              'California users opt-out of personal-data sale.'),
          const SizedBox(height: 24),
          // T120 — pure preview of what applying the toggles above would send
          // to each provider, with zero platform-channel calls (no
          // AdManager().setConsent() yet). Useful for a QA compliance check
          // to walk every GDPR/COPPA/CCPA combination without a device.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: OutlinedButton(
              onPressed: () {
                final result = simulateConsentOutcome(AdConsent(
                  hasUserConsent: _hasConsent.value,
                  isAgeRestrictedUser: _isAge.value,
                  doNotSell: _doNotSell.value,
                ));
                showDialog<void>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text('simulateConsentOutcome() preview'),
                    content: Text(
                      'AppLovin hasUserConsent: ${result.appLovinHasUserConsent}\n'
                      'AppLovin doNotSell: ${result.appLovinDoNotSell}\n'
                      'AdMob tagForChildDirectedTreatment: '
                      '${result.admobTagForChildDirectedTreatment}\n'
                      'AdMob tagForUnderAgeOfConsent: '
                      '${result.admobTagForUnderAgeOfConsent}',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Close'),
                      ),
                    ],
                  ),
                );
              },
              child: const Text('Preview outcome (no device call)'),
            ),
          ),
          const SizedBox(height: 8),
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
                      Text(
                          'country=${s.country ?? '(not set — host-supplied only, see below)'}',
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 11)),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Consent country analytics (T27) — SDK never infers this itself
          // (UMP only exposes EEA/non-EEA); host app must supply it.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _countryController,
                    decoration: const InputDecoration(
                      labelText: 'Consent country (e.g. DE, US)',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: () async {
                    final country = _countryController.text.trim();
                    await ConsentManager.instance.set(
                      ConsentManager.instance.current
                          .copyWith(country: country.isEmpty ? null : country),
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(country.isEmpty
                              ? 'Consent country cleared'
                              : 'Consent country set to $country')));
                    }
                  },
                  child: const Text('Set'),
                ),
              ],
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
                      onPrivacyPolicyTap:
                          AdManager().config?.onPrivacyPolicyTap,
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
          const Divider(height: 32),
          // ─── T146: privacy-store fail-closed proof ────────────────────
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'CCPA/GPP storage fail-closed (T146)',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'A broken platform preference store must never be read as '
                  '"no opt-out signal" — it must fail CLOSED (treated as '
                  'opted-out) instead. Tap below to simulate the store '
                  'throwing on every read and see the real result.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 8),
                FilledButton.tonalIcon(
                  icon: _t146Busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.warning_amber_outlined),
                  label: const Text('Simulate broken privacy store'),
                  onPressed:
                      _t146Busy ? null : _simulateBrokenPrivacyStore,
                ),
                if (_t146Result != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'usPrivacyOptedOut() → $_t146Result',
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 12),
                    ),
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

// ─────────────────────────────────────────────────────────────────────────
// demos/diagnostics_demo_page.dart
// ─────────────────────────────────────────────────────────────────────────

// T117 — diagnostics demo page. Split out of main.dart.

class DiagnosticsDemoPage extends StatefulWidget {
  const DiagnosticsDemoPage({super.key});

  @override
  State<DiagnosticsDemoPage> createState() => _DiagnosticsDemoPageState();
}

class _DiagnosticsDemoPageState extends State<DiagnosticsDemoPage> {
  static const _encoder = JsonEncoder.withIndent('  ');

  String? _diagnosticsJson;
  SelfCheckResult? _selfCheck;
  bool _runningSelfCheck = false;

  void _runDiagnostics() {
    final diag = AdManager().diagnostics();
    setState(() => _diagnosticsJson = _encoder.convert(diag.toJson()));
  }

  Future<void> _runSelfCheck() async {
    setState(() => _runningSelfCheck = true);
    final result = await AdManager().runIntegrationSelfCheck();
    if (!mounted) return;
    setState(() {
      _selfCheck = result;
      _runningSelfCheck = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final diagJson = _diagnosticsJson;
    final selfCheck = _selfCheck;
    return Scaffold(
      appBar: AppBar(title: const Text('Diagnostics & self-check')),
      body: ListView(
        padding: bottomSafe(context, const EdgeInsets.all(16)),
        children: [
          const Text(
            'AdManager.diagnostics() — one-shot snapshot of mediation '
            'waterfall, fill rate and arbitrator stats, for "why is eCPM low '
            'today" without cross-referencing 3 separate pages.',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _runDiagnostics,
            icon: const Icon(Icons.query_stats),
            label: const Text('Run diagnostics()'),
          ),
          if (diagJson != null) ...[
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(diagJson,
                    style:
                        const TextStyle(fontFamily: 'monospace', fontSize: 11)),
              ),
            ),
          ],
          const Divider(height: 32),
          const Text(
            'AdManager.runIntegrationSelfCheck() — debug-only checklist '
            '(init → consent → per-slot load) so a partner integrating the '
            'SDK doesn\'t have to click through every demo page by hand. '
            'No-op (skipped) outside debug builds.',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _runningSelfCheck ? null : _runSelfCheck,
            icon: _runningSelfCheck
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.checklist),
            label: const Text('Run runIntegrationSelfCheck()'),
          ),
          if (selfCheck != null) ...[
            const SizedBox(height: 8),
            Card(
              color: selfCheck.allPassed
                  ? Colors.green.withValues(alpha: 0.08)
                  : Colors.red.withValues(alpha: 0.08),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                        selfCheck.allPassed ? 'All checks passed' : 'FAILED',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  const Divider(height: 1),
                  for (final item in selfCheck.items)
                    ListTile(
                      dense: true,
                      leading: Icon(
                          switch (item.status) {
                            SelfCheckStatus.pass => Icons.check_circle,
                            SelfCheckStatus.fail => Icons.error,
                            SelfCheckStatus.skipped =>
                              Icons.remove_circle_outline,
                          },
                          color: switch (item.status) {
                            SelfCheckStatus.pass => Colors.green,
                            SelfCheckStatus.fail => Colors.red,
                            SelfCheckStatus.skipped => Colors.grey,
                          }),
                      title: Text(item.name),
                      subtitle: item.detail != null ? Text(item.detail!) : null,
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// demos/events_demo_page.dart
// ─────────────────────────────────────────────────────────────────────────

// T117 — AdEvent stream live viewer. Split out of main.dart. EventRow
// itself lives in shared/event_buffer.dart.

class EventsDemoPage extends StatelessWidget {
  const EventsDemoPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AdEvent stream'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete),
            tooltip: 'Clear',
            onPressed: () => EventBuffer.instance.clear(),
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
              valueListenable: EventBuffer.instance.revision,
              builder: (_, __, ___) {
                final rows = EventBuffer.instance.snapshot();
                if (rows.isEmpty) {
                  return const Center(
                    child: Text('(no events yet — trigger an ad somewhere)',
                        style: TextStyle(color: Colors.grey)),
                  );
                }
                return ListView.separated(
                  padding: bottomSafe(context, EdgeInsets.zero),
                  itemCount: rows.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final row = rows[i];
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

class _EventTile extends StatelessWidget {
  const _EventTile({required this.row});
  final EventRow row;

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
        e is AdAnomalyEvent
            ? e.reason
            : '${e.providerTag} ${e.type.name} @${e.placement.id}',
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
      final waterfall = e.mediationWaterfall;
      return (
        'REV \$',
        Colors.teal,
        '\$${e.value.toStringAsFixed(6)} ${e.currencyCode}'
            '${e.networkName != null ? ' via ${e.networkName}' : ''}'
            '${waterfall != null && waterfall.isNotEmpty ? '\nwaterfall: ${waterfall.join(' > ')}' : ''}',
      );
    }
    if (e is AdAnomalyEvent) {
      return (
        'ANOMALY',
        Colors.redAccent,
        'violation #${e.violationCount} · paused ${e.pauseDurationMs ~/ 60000}min',
      );
    }
    if (e is ArbitratorNudgeEvent) {
      return (
        'NUDGE',
        Colors.indigo,
        'vetoed low-eCPM ad · trailing eCPM=\$${e.estimatedEcpmMicros / 1e6}',
      );
    }
    return ('?', Colors.grey, '');
  }
}

// ─────────────────────────────────────────────────────────────────────────
// demos/interstitial_demo_page.dart
// ─────────────────────────────────────────────────────────────────────────

// T117 — interstitial demo page. Split out of main.dart.

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
        padding: bottomSafe(context, const EdgeInsets.all(24)),
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

// ─────────────────────────────────────────────────────────────────────────
// demos/log_viewer_demo_page.dart
// ─────────────────────────────────────────────────────────────────────────

// T117 — log viewer demo page. Split out of main.dart.

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
            padding: bottomSafe(context, EdgeInsets.zero),
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

// ─────────────────────────────────────────────────────────────────────────
// demos/mrec_demo_page.dart
// ─────────────────────────────────────────────────────────────────────────

// T117 — mrec demo page. Split out of main.dart.

class MrecDemoPage extends AdScreen {
  const MrecDemoPage({super.key});

  @override
  State<MrecDemoPage> createState() => _MrecDemoPageState();
}

class _MrecDemoPageState extends AdScreenState<MrecDemoPage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('MREC demo')),
      body: Column(
        children: [
          buildMrec(),
          Expanded(
            child: ListView(
              padding: bottomSafe(context, EdgeInsets.zero),
              children: [
                ListTile(
                  leading: const Icon(Icons.navigate_next),
                  title:
                      const Text('Push another screen (verifies pause/resume)'),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const _MrecSecondScreen()),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'MREC is a fixed 300x250 rectangle. Push the second '
                    'screen — it pauses on AppLovin / hides on AdMob. Pop '
                    'back to resume.',
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    'Second instance below — proves both MRECs load '
                    'independently (T65 keyed-by-instance).',
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
                buildMrec(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MrecSecondScreen extends AdScreen {
  const _MrecSecondScreen();

  @override
  State<_MrecSecondScreen> createState() => _MrecSecondScreenState();
}

class _MrecSecondScreenState extends AdScreenState<_MrecSecondScreen> {
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Second route')),
        body: SafeArea(
          top: false,
          child: Column(children: [
            const Expanded(
                child: Center(child: Text('MREC pauses on previous'))),
            buildMrec(),
          ]),
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────
// demos/native_demo_page.dart
// ─────────────────────────────────────────────────────────────────────────

// T117 — native demo page. Split out of main.dart.

class NativeDemoPage extends AdScreen {
  const NativeDemoPage({super.key});

  @override
  State<NativeDemoPage> createState() => _NativeDemoPageState();
}

class _NativeDemoPageState extends AdScreenState<NativeDemoPage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Native demo')),
      body: ListView(
        padding: bottomSafe(context, EdgeInsets.zero),
        children: [
          buildNative(),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Native ad v1: fixed layout, no auto-refresh/route-pause. '
              'AdMob renders its own template + "Ad" badge; AppLovin renders '
              'a custom Dart layout with a package-drawn "Ad" badge.',
              style: TextStyle(color: Colors.grey),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Second instance below — proves both natives load '
              'independently (T65 keyed-by-instance).',
              style: TextStyle(color: Colors.grey),
            ),
          ),
          buildNative(),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// demos/revenue_demo_page.dart
// ─────────────────────────────────────────────────────────────────────────

// T117 — revenue demo page. Split out of main.dart.

class RevenueDemoPage extends StatelessWidget {
  const RevenueDemoPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Revenue dashboard')),
      body: Padding(
        padding: bottomSafe(context, const EdgeInsets.all(16)),
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

// ─────────────────────────────────────────────────────────────────────────
// demos/rewarded_demo_page.dart
// ─────────────────────────────────────────────────────────────────────────

// T117 — rewarded demo page. Split out of main.dart.

class RewardedDemoPage extends AdScreen {
  const RewardedDemoPage({super.key});

  @override
  State<RewardedDemoPage> createState() => _RewardedDemoPageState();
}

class _RewardedDemoPageState extends AdScreenState<RewardedDemoPage> {
  final ValueNotifier<int> _coins = ValueNotifier<int>(0);
  final ValueNotifier<bool> _vipAutoGrant = ValueNotifier<bool>(false);
  final ValueNotifier<String> _last = ValueNotifier<String>('—');
  final TextEditingController _ssvCtrl = TextEditingController();

  @override
  void dispose() {
    _coins.dispose();
    _vipAutoGrant.dispose();
    _last.dispose();
    _ssvCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Rewarded demo')),
      body: SingleChildScrollView(
        padding: bottomSafe(context, const EdgeInsets.all(24)),
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
            TextField(
              controller: _ssvCtrl,
              decoration: const InputDecoration(
                labelText: 'SSV user id (optional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () {
                final ssvUserId = _ssvCtrl.text.isEmpty ? null : _ssvCtrl.text;
                showRewardedAd(
                  vipAutoGrant: _vipAutoGrant.value,
                  ssvUserId: ssvUserId,
                  onEarnedReward: (earned) {
                    _last.value = earned
                        ? 'earned 🏆${ssvUserId != null ? ' (pending SSV confirmation)' : ''}'
                        : 'skipped/blocked ❌';
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

// ─────────────────────────────────────────────────────────────────────────
// demos/rewarded_interstitial_demo_page.dart
// ─────────────────────────────────────────────────────────────────────────

// Round-27 audit — showRewardedInterstitialAd() had zero demo coverage
// anywhere in the example app despite being a fully-supported ad surface
// (README's "Rewarded interstitial" section). Unlike rewarded, this format
// shows a built-in disclosure/intro screen before the ad by default
// (showDisclosure: true) — the demo below exercises that default path.
class RewardedInterstitialDemoPage extends AdScreen {
  const RewardedInterstitialDemoPage({super.key});

  @override
  State<RewardedInterstitialDemoPage> createState() =>
      _RewardedInterstitialDemoPageState();
}

class _RewardedInterstitialDemoPageState
    extends AdScreenState<RewardedInterstitialDemoPage> {
  final ValueNotifier<int> _coins = ValueNotifier<int>(0);
  final ValueNotifier<String> _last = ValueNotifier<String>('—');

  @override
  void dispose() {
    _coins.dispose();
    _last.dispose();
    super.dispose();
  }

  void _watch() {
    showRewardedInterstitialAd(
      onDone: (shown, earned) {
        if (!mounted) return;
        _last.value = 'shown=$shown earned=$earned';
        if (earned) _coins.value = _coins.value + 10;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Rewarded interstitial demo')),
      body: SingleChildScrollView(
        padding: bottomSafe(context, const EdgeInsets.all(24)),
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
            const Card(
              child: Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'Shows a disclosure/intro screen first (mandatory unless '
                  'the host passes showDisclosure: false and supplies its '
                  'own), then the ad. Declining the intro reports '
                  '(shown: false, earned: false) at no ad-budget cost — '
                  'same earned-only reward contract as the plain rewarded '
                  'format.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _watch,
              child: const Text('Watch rewarded interstitial for +10 coins'),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// demos/safety_demo_page.dart
// ─────────────────────────────────────────────────────────────────────────

// T117 — safety demo page. Split out of main.dart.

class SafetyDemoPage extends StatefulWidget {
  const SafetyDemoPage({super.key});

  @override
  State<SafetyDemoPage> createState() => _SafetyDemoPageState();
}

class _SafetyDemoPageState extends State<SafetyDemoPage> {
  final ValueNotifier<int> _refresh = ValueNotifier<int>(0);
  final ValueNotifier<bool> _arbitratorEnabled =
      ValueNotifier<bool>(AdManager().arbitrator != null);
  final ValueNotifier<bool> _fillRateMonitorEnabled =
      ValueNotifier<bool>(AdManager().fillRateMonitor != null);

  @override
  void dispose() {
    _refresh.dispose();
    _arbitratorEnabled.dispose();
    _fillRateMonitorEnabled.dispose();
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
          padding: bottomSafe(context, const EdgeInsets.all(16)),
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
            const Text('Policy risk score (T24, dev/partner signal only)',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            ValueListenableBuilder<int>(
              valueListenable: AdManager().policyRiskScore,
              builder: (_, score, __) {
                final color = score < 30
                    ? Colors.green
                    : (score < 70 ? Colors.orange : Colors.red);
                return Row(
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration:
                          BoxDecoration(color: color, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '$score / 100',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold,
                        color: color,
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 12),
            const Text('Smart Monetization Arbitrator (opt-in)',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            ValueListenableBuilder<bool>(
              valueListenable: _arbitratorEnabled,
              builder: (_, enabled, __) {
                final arbitrator = AdManager().arbitrator;
                if (!enabled || arbitrator == null) {
                  return const Text('disabled (default)',
                      style: TextStyle(fontFamily: 'monospace', fontSize: 11));
                }
                return Text(
                  'estimatedEcpm=${arbitrator.estimatedEcpmMicros}µ '
                  'vetoRate=${arbitrator.vetoRate.toStringAsFixed(2)}\n'
                  'perSlotThreshold: interstitial=8000000µ rewarded=3000000µ, '
                  'maxVetoRate=0.5',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                );
              },
            ),
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: () {
                AdManager().enableArbitrator(MonetizationArbitrator(
                  // Demo per-slot thresholds — rewarded ads tend to earn
                  // more than interstitials, so give interstitial a higher
                  // eCPM bar before nudging VIP. maxVetoRate is the
                  // guardrail: if >50% of decisions veto, it stops vetoing
                  // and falls back to showAd rather than starve the user.
                  perSlotThresholdMicros: const {
                    AdSlotType.interstitial: 8000000, // $8.00 eCPM
                    AdSlotType.rewarded: 3000000, // $3.00 eCPM
                  },
                  maxVetoRate: 0.5,
                ));
                _arbitratorEnabled.value = true;
                _refresh.value = _refresh.value + 1;
              },
              child:
                  const Text('Enable Smart Arbitrator (per-slot + guardrail)'),
            ),
            const SizedBox(height: 12),
            const Text('Fill-rate monitor (opt-in)',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            ValueListenableBuilder<bool>(
              valueListenable: _fillRateMonitorEnabled,
              builder: (_, enabled, __) {
                final monitor = AdManager().fillRateMonitor;
                if (!enabled || monitor == null) {
                  return const Text('fill-rate monitor disabled (default)',
                      style: TextStyle(fontFamily: 'monospace', fontSize: 11));
                }
                return Text(
                  'interstitial=${monitor.fillRate(AdSlotType.interstitial).toStringAsFixed(2)} '
                  'rewarded=${monitor.fillRate(AdSlotType.rewarded).toStringAsFixed(2)} '
                  'appOpen=${monitor.fillRate(AdSlotType.appOpen).toStringAsFixed(2)}',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                );
              },
            ),
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: () {
                AdManager().enableFillRateMonitor(FillRateMonitor());
                _fillRateMonitorEnabled.value = true;
              },
              child: const Text('Enable Fill-rate Monitor'),
            ),
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
                AdSafetyConfig.resetSessionCounters();
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

// ─────────────────────────────────────────────────────────────────────────
// demos/state_panel_demo_page.dart
// ─────────────────────────────────────────────────────────────────────────

// T117 — state panel demo page. Split out of main.dart.

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
      body: ListView(
        padding: bottomSafe(context, const EdgeInsets.all(16)),
        children: [
          // T109 — one ValueListenable instead of gluing 5 separate ones.
          const Text('AdSdkStateSnapshot',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          const SizedBox(height: 8),
          ValueListenableBuilder<AdSdkStateSnapshot>(
            valueListenable: AdManager().stateSnapshot,
            builder: (context, snapshot, __) => Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('isInitialised: ${snapshot.isInitialised}'),
                    Text('canRequestAds: ${snapshot.canRequestAds}'),
                    Text('isOffline: ${snapshot.isOffline}'),
                    Text('isVipActive: ${snapshot.isVipActive}'),
                    Text('fullscreenBusy: ${snapshot.fullscreenBusy}'),
                  ],
                ),
              ),
            ),
          ),
          const Divider(height: 32),
          if (adapter != null) ...[
            Text('Provider: ${adapter.tag}',
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            const SizedBox(height: 12),
            _slotCard('App Open', adapter.appOpenSlot),
            _slotCard('Interstitial', adapter.interstitialSlot),
            _slotCard('Rewarded', adapter.rewardedSlot),
            // T65 (phase 2): banner is now keyed per BannerAdWidget instance
            // — no single slot to show here, same as mrec/native already.
          ] else
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(child: Text('SDK not initialised yet')),
            ),
          const Divider(height: 32),
          const Text(
            'Lifecycle test',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          FilledButton.tonal(
            onPressed: adapter == null
                ? null
                : () async {
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
          if (kDebugMode) ...[
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: () => _openAdInspector(context),
              child: const Text(
                kProvider == AdProvider.appLovin
                    ? 'Open AppLovin mediation debugger'
                    : 'Open AdMob ad inspector',
              ),
            ),
          ],
        ],
      ),
    );
  }

  // Both providers ship their own native debug UI — no need to build one.
  void _openAdInspector(BuildContext context) {
    if (kProvider == AdProvider.appLovin) {
      AppLovinMAX.showMediationDebugger();
      return;
    }
    MobileAds.instance.openAdInspector((error) {
      if (error != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ad inspector error: ${error.message}')),
        );
      }
    });
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

// ─────────────────────────────────────────────────────────────────────────
// demos/test_device_hash_demo_page.dart
// ─────────────────────────────────────────────────────────────────────────

// T117 — test device hash demo page. Split out of main.dart.

class TestDeviceHashDemoPage extends StatelessWidget {
  const TestDeviceHashDemoPage({super.key});

  Future<void> _copy(BuildContext context, String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('$label copied to clipboard')));
  }

  @override
  Widget build(BuildContext context) {
    final gaid = AdManager().currentDeviceGaid;
    final hint = AdManager().adMobTestDeviceHashHint();
    return Scaffold(
      appBar: AppBar(title: const Text('AdMob test-device hash')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Current device GAID',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            SelectableText(
                gaid.isEmpty ? '(empty — init not done yet, or LAT on)' : gaid),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              icon: const Icon(Icons.copy),
              label: const Text('Copy GAID (not the AdMob hash!)'),
              onPressed:
                  gaid.isEmpty ? null : () => _copy(context, 'GAID', gaid),
            ),
            const SizedBox(height: 20),
            Text('adMobTestDeviceHashHint()',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            Expanded(child: SingleChildScrollView(child: SelectableText(hint))),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              icon: const Icon(Icons.copy),
              label: const Text('Copy hint text'),
              onPressed: () => _copy(context, 'Hint', hint),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// demos/vip_demo_page.dart
// ─────────────────────────────────────────────────────────────────────────

// T117 — vip demo page. Split out of main.dart.

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
    // vip.activeListenable only fires on true/false transitions, so stacking
    // more time while already active wouldn't otherwise refresh the card below.
    if (mounted) setState(() {});
  }

  /// T18 — redeem an offline SIGNED VIP key (Ed25519, verified against the
  /// embedded public key; no network; per-device one-time-use).
  Future<void> _redeemSigned(String code) async {
    final vip = AdManager().vip;
    if (vip == null) return;
    final r = await vip.redeemSignedKey(code,
        publicKeyBase64: kDemoVipPublicKey, stack: true);
    if (!mounted) return;
    setState(() {});
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
        if (mounted) setState(() {});
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
        padding: bottomSafe(context, const EdgeInsets.all(16)),
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
                        ValueListenableBuilder<bool>(
                          valueListenable: vip.graceNudgeDueListenable,
                          builder: (_, due, __) {
                            if (!due) return const SizedBox.shrink();
                            return Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Row(
                                children: [
                                  const Icon(Icons.warning_amber,
                                      color: Colors.orange, size: 18),
                                  const SizedBox(width: 4),
                                  const Expanded(
                                      child: Text(
                                          '⏳ VIP expiring soon — grace nudge due')),
                                  TextButton(
                                    onPressed: vip.acknowledgeGraceNudge,
                                    child: const Text('Ack'),
                                  ),
                                ],
                              ),
                            );
                          },
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

          // T148 — fast-refill proof: ending VIP reloads App Open,
          // Interstitial, Rewarded AND Rewarded Interstitial right away
          // instead of waiting out the 5-minute retry timer. Watch the
          // floating debug overlay (bottom of every screen, kDebugMode only)
          // — all four should start loading together, not just the first
          // three.
          if (vip != null && vip.isActive)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Fast-refill proof (T148)',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    const Text(
                      'Ends VIP now and reloads all four fullscreen formats '
                      'immediately. Watch the debug overlay at the bottom of '
                      'the screen — Rewarded Interstitial must start loading '
                      'together with the other three, not 5 minutes later.',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: () async {
                        final at = DateTime.now();
                        await vip.revokeAll();
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: Text('VIP ended at '
                                '${at.toIso8601String().substring(11, 19)} — '
                                'check the debug overlay')));
                        setState(() {});
                      },
                      child: const Text('End VIP now'),
                    ),
                  ],
                ),
              ),
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
          const SizedBox(height: 24),

          // Round-39 audit (MINOR): this demo previously never showed how to
          // wire VipRevocationProvider/refreshRevocationList — a partner
          // copying this example verbatim could ship VIP-code revocation
          // completely inert without realising it, since the SDK has no way
          // to warn about a feature it was simply never asked to use. A real
          // host app would call this from a `Timer.periodic` (see
          // VipRevocationProvider's own doc comment) with a provider that
          // fetches `tool/vip_crl_mint.dart`'s output from its own backend —
          // this button just demonstrates the call shape with a stub.
          OutlinedButton.icon(
            onPressed: () async {
              await vip?.refreshRevocationList(
                publicKeyBase64: kDemoVipPublicKey,
                revocationProvider: _DemoCrlProvider(),
              );
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text(
                        'Checked for a revocation list (demo stub — wire '
                        'your own backend via VipRevocationProvider)')));
              }
            },
            icon: const Icon(Icons.block_flipped),
            label: const Text('Refresh revocation list (CRL)'),
          ),
        ],
      ),
    );
  }
}

/// Demo-only stub — a real host implements [fetchSignedCrl] against its own
/// backend (see [VipRevocationProvider]'s own doc comment). Returning `null`
/// is a normal, safe result: `refreshRevocationList` fails open and leaves
/// whatever was already cached untouched.
class _DemoCrlProvider implements VipRevocationProvider {
  @override
  Future<String?> fetchSignedCrl() async {
    debugPrint('[example] fetchSignedCrl: no real CRL backend in this demo');
    return null;
  }
}

// ─────────────────────────────────────────────────────────────────────────
// RemoteAdSafetyProvider demo (T88) — README "Remote-controlled AdSafetyParams"
// ─────────────────────────────────────────────────────────────────────────

/// Demo-only stand-in for a real backend (Firebase Remote Config, a
/// self-hosted config API, ...) — see README's "Remote-controlled
/// AdSafetyParams" section. A real host reads its own remote-config SDK
/// inside [fetchSafetyParamOverrides]; this demo reads [overrides] instead,
/// which the demo page's own sliders act as the "remote" source of truth.
class DemoRemoteAdSafetyProvider implements RemoteAdSafetyProvider {
  final ValueNotifier<Map<String, dynamic>?> overrides =
      ValueNotifier<Map<String, dynamic>?>(null);

  @override
  Future<Map<String, dynamic>?> fetchSafetyParamOverrides() async {
    debugPrint('[example] fetchSafetyParamOverrides: ${overrides.value}');
    return overrides.value;
  }
}

class RemoteSafetyDemoPage extends StatefulWidget {
  const RemoteSafetyDemoPage({super.key});

  // Round-40 audit round 2 (independent re-review, R2-02) — the double-tap
  // regression tests could only assert on converged end-state ("wired" /
  // "one demo page"), which two racing operations could equally reach.
  // These count actual invocations past the `_busy` guard so a test can
  // assert exactly one real destroy()/initialize() ran, not just that the
  // UI looks fine afterward. Test-only — never read outside integration
  // tests.
  @visibleForTesting
  static int debugApplyCallCount = 0;
  @visibleForTesting
  static int debugPushCallCount = 0;
  @visibleForTesting
  static int debugRestoreCallCount = 0;

  // Round-40 audit round 4 (follow-up to R3-01) — a real
  // `AdManager().initialize()` failure is network-dependent and not
  // reliably forceable from a test, so `onComplete(false, ...)`'s branch
  // (see R3-01) had no deterministic regression coverage. When set, this
  // skips the real destroy()/initialize() call entirely and uses the given
  // value as `success` directly — the real call itself is already proven
  // on-device by the other round40 integration tests; this isolates just
  // the success/failure branch handling so it can run as a fast, reliable
  // plain widget test. Test-only; reset to `null` in `tearDown`.
  @visibleForTesting
  static bool? debugForceApplyResult;
  @visibleForTesting
  static bool? debugForceRestoreResult;

  @override
  State<RemoteSafetyDemoPage> createState() => _RemoteSafetyDemoPageState();
}

class _RemoteSafetyDemoPageState extends State<RemoteSafetyDemoPage> {
  final _provider = DemoRemoteAdSafetyProvider();
  double _maxPerDay = 20;
  bool _dryRun = false;
  bool _wired = false;
  // T147 — remote per-format kill switch (T137). Lets this page prove
  // canShowRewardedAd()/canShowRewardedInterstitialAd() each gate on their
  // OWN format only, not the wrong sibling's.
  bool _rewardedDisabled = false;
  bool _rewardedInterstitialDisabled = false;
  // Round-40 audit (independent review, IMPORTANT) — without this, a fast
  // double-tap on "Apply provider" (or "Push update") started a second
  // destroy()/initialize() (or refresh) before the first one's await
  // resolved, since only `_wired` gated the button and it only flips
  // after everything finishes. Guards every button below.
  bool _busy = false;
  String _status = 'Not wired yet — tap "Apply provider" below first.';

  Future<void> _applyProvider() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = 'Destroying + re-initializing with provider...';
    });
    RemoteSafetyDemoPage.debugApplyCallCount++;
    // Round-40 audit round 3 (independent re-review, R3-01) — `onComplete`
    // was ignored, so a legitimate `onComplete(false, ...)` (SDK init
    // failing without throwing) still fell through to the success branch
    // below, claiming "Provider wired" while the SDK was actually left
    // uninitialised post-destroy().
    var success = false;
    try {
      final forced = RemoteSafetyDemoPage.debugForceApplyResult;
      if (forced != null) {
        success = forced;
      } else {
        await AdManager().destroy();
        await AdManager().initialize(
          config: DemoConfig.instance.build(),
          remoteSafetyProvider: _provider,
          onComplete: (ok, _) => success = ok,
        );
      }
      if (!mounted) return;
      if (!success) {
        setState(() =>
            _status = 'Failed to apply provider — the SDK did not initialize.');
        return;
      }
      setState(() {
        _wired = true;
        _status = 'Provider wired. Adjust below, then "Push update".';
      });
    } catch (e) {
      if (mounted) setState(() => _status = 'Failed to apply provider: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pushUpdate() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = 'Fetching...';
    });
    RemoteSafetyDemoPage.debugPushCallCount++;
    _provider.overrides.value = {
      'maxFullscreenAdsPerDay': _maxPerDay.round(),
      'dryRun': _dryRun,
      'disabledFormats': [
        if (_rewardedDisabled) 'rewarded',
        if (_rewardedInterstitialDisabled) 'rewardedInterstitial',
      ],
    };
    try {
      await AdManager().refreshRemoteSafetyParams();
      if (!mounted) return;
      setState(() => _status = 'Applied — see "Live status" below.');
    } catch (e) {
      if (mounted) setState(() => _status = 'Failed to push update: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // Round-40 audit (independent review, MINOR) — "Apply provider" mutates
  // the whole app's live AdSafetyConfig, not just this page; it used to
  // stay mutated with no way back short of restarting the app, which could
  // make every other demo screen visited afterward confusing (dry-run ads,
  // a lowered daily cap). Detaches the provider and puts the SDK back on
  // DemoConfig's own defaults.
  Future<void> _restoreDefaults() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = 'Restoring demo defaults...';
    });
    RemoteSafetyDemoPage.debugRestoreCallCount++;
    // R3-01 (see _applyProvider) — same capture-and-branch fix.
    var success = false;
    try {
      final forced = RemoteSafetyDemoPage.debugForceRestoreResult;
      if (forced != null) {
        success = forced;
      } else {
        await AdManager().destroy();
        await AdManager().initialize(
          config: DemoConfig.instance.build(),
          onComplete: (ok, _) => success = ok,
        );
      }
      if (!mounted) return;
      if (!success) {
        setState(() => _status =
            'Failed to restore defaults — the SDK did not initialize.');
        return;
      }
      setState(() {
        _wired = false;
        _maxPerDay = 20;
        _dryRun = false;
        _rewardedDisabled = false;
        _rewardedInterstitialDisabled = false;
        _status = 'Restored — provider detached, SDK back on demo defaults.';
      });
    } catch (e) {
      if (mounted) setState(() => _status = 'Failed to restore defaults: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Remote safety provider demo')),
      body: ListView(
        padding: bottomSafe(context, const EdgeInsets.all(16)),
        children: [
          const Card(
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Simulates a backend (Firebase Remote Config, your own API, '
                '...) pushing new AdSafetyParams without an app store '
                'release. The controls below stand in for "what the backend '
                'returns" — a real host reads them from its own remote-config '
                'SDK instead. See README "Remote-controlled AdSafetyParams".',
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Card(
            color: Color(0xFFFFF3E0),
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                '⚠️ "Apply provider" mutates the whole app\'s live '
                'AdSafetyParams, not just this page — other demo screens '
                'will reflect it too, until you tap "Restore demo defaults" '
                'below.',
              ),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: (_busy || _wired) ? null : _applyProvider,
            child: Text(_wired
                ? 'Provider already wired'
                : _busy
                    ? 'Applying...'
                    : 'Apply provider (destroy + re-initialize)'),
          ),
          const SizedBox(height: 16),
          Text(
              'Simulated remote maxFullscreenAdsPerDay: ${_maxPerDay.round()}'),
          Slider(
            value: _maxPerDay,
            min: 1,
            max: 50,
            divisions: 49,
            label: '${_maxPerDay.round()}',
            onChanged: (_wired && !_busy)
                ? (v) => setState(() => _maxPerDay = v)
                : null,
          ),
          SwitchListTile(
            title: const Text('Simulated remote dryRun'),
            value: _dryRun,
            onChanged: (_wired && !_busy)
                ? (v) => setState(() => _dryRun = v)
                : null,
          ),
          const Text('Per-format kill switch (T147)',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          SwitchListTile(
            title: const Text('Disable rewarded'),
            value: _rewardedDisabled,
            onChanged: (_wired && !_busy)
                ? (v) => setState(() => _rewardedDisabled = v)
                : null,
          ),
          SwitchListTile(
            title: const Text('Disable rewardedInterstitial'),
            value: _rewardedInterstitialDisabled,
            onChanged: (_wired && !_busy)
                ? (v) => setState(() => _rewardedInterstitialDisabled = v)
                : null,
          ),
          const SizedBox(height: 8),
          FilledButton.tonal(
            onPressed: (_wired && !_busy) ? _pushUpdate : null,
            child: const Text('Push update (refreshRemoteSafetyParams)'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: (_wired && !_busy) ? _restoreDefaults : null,
            child: const Text('Restore demo defaults (destroy + re-initialize)'),
          ),
          const Divider(height: 32),
          Text(_status),
          const SizedBox(height: 12),
          const Text('Live status',
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(AdSafetyConfig.getStatus(),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
          const SizedBox(height: 8),
          if (_wired)
            Text(
              'canShowRewardedAd()=${AdManager().canShowRewardedAd()}  '
              'canShowRewardedInterstitialAd()='
              '${AdManager().canShowRewardedInterstitialAd()}',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// AdReadinessSplashController demo (T94) — README's splash-wrapper shortcut
// ─────────────────────────────────────────────────────────────────────────

class ReadinessControllerDemoPage extends StatefulWidget {
  const ReadinessControllerDemoPage({super.key});

  // Round-40 audit round 2 (independent re-review, R2-02) — test-only
  // counter so a double-tap test can assert exactly one real replay ran
  // past the `_busy` guard, not just that the end state looks converged.
  @visibleForTesting
  static int debugReplayCallCount = 0;

  @override
  State<ReadinessControllerDemoPage> createState() =>
      _ReadinessControllerDemoPageState();
}

class _ReadinessControllerDemoPageState
    extends State<ReadinessControllerDemoPage> {
  // Round-40 audit (independent review, IMPORTANT) — without this, a fast
  // double-tap could push two `_ReadinessControllerSplash` routes on top of
  // a single `destroy()`, racing two controllers against one SDK instance
  // (the second short-circuits via `countInitSplashScreen > 1`, but which
  // one "wins" the pop back becomes timing-dependent). Held true for the
  // whole time the splash route is on screen, not just during destroy() —
  // `Navigator.push`'s Future only resolves once it's popped.
  bool _busy = false;

  Future<void> _replay(BuildContext context) async {
    if (_busy) return;
    setState(() => _busy = true);
    ReadinessControllerDemoPage.debugReplayCallCount++;
    try {
      await AdManager().destroy();
      if (!context.mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => const _ReadinessControllerSplash(),
      ));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Replay failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AdReadinessSplashController demo')),
      body: ListView(
        padding: bottomSafe(context, const EdgeInsets.all(16)),
        children: [
          const Card(
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'This example\'s real splash screen (SplashScreen) wires '
                'everything by hand, to demo the full manual flow the '
                'README documents. AdReadinessSplashController (T94) wraps '
                'that exact same sequence — subscribe-before-init, hard-cap '
                'timer, splash-active bookkeeping, buffered App Open ad — '
                'behind one start()/onReady call, for hosts that do not need '
                'the manual flow\'s extra steps.\n\n'
                'Tapping below destroys the SDK (the same "Destroy SDK" '
                'action used elsewhere in this app) and re-initializes it '
                'through the controller instead, so it runs for real.',
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : () => _replay(context),
            child: Text(_busy
                ? 'Replaying...'
                : 'Destroy SDK + replay via controller'),
          ),
        ],
      ),
    );
  }
}

class _ReadinessControllerSplash extends StatefulWidget {
  const _ReadinessControllerSplash();

  @override
  State<_ReadinessControllerSplash> createState() =>
      _ReadinessControllerSplashState();
}

class _ReadinessControllerSplashState
    extends State<_ReadinessControllerSplash> {
  late final _controller =
      AdReadinessSplashController(config: DemoConfig.instance.build());

  @override
  void initState() {
    super.initState();
    _controller.start(context, onReady: () {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const Scaffold(
        backgroundColor: Colors.deepPurple,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: Colors.white),
              SizedBox(height: 16),
              Text('AdReadinessSplashController running...',
                  style: TextStyle(color: Colors.white)),
            ],
          ),
        ),
      );
}
