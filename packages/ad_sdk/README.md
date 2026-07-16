# applovin_admob_sdk

[![pub.dev](https://img.shields.io/pub/v/applovin_admob_sdk?label=pub.dev)](https://pub.dev/packages/applovin_admob_sdk)
[![Flutter](https://img.shields.io/badge/Flutter-%3E%3D3.27.0-blue)](https://flutter.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-green)](LICENSE)

**A production-grade dual-provider ad SDK for Flutter — AdMob and AppLovin MAX behind a single, opinionated API.**

Drop in, configure 5 keys, ship. The SDK ships sensible defaults for compliance, anti-fraud, retention, and crash recovery — most apps need zero glue code beyond the splash bootstrap.

---

## Table of contents

1. [Why this SDK](#why-this-sdk)
2. [Known limitations — read before adopting](#known-limitations--read-before-adopting)
3. [What's new in 1.0.23](#whats-new-in-1023)
4. [Quick start (copy-paste in 6 steps)](#quick-start)
5. [Configuration reference](#configuration-reference)
6. [VIP system](#vip-system)
7. [Server-Side Verification (SSV) for rewarded ads](#server-side-verification-ssv-for-rewarded-ads)
8. [Consent & compliance (GDPR / COPPA / CCPA)](#consent--compliance)
9. [Debugging](#debugging)
10. [Pitfalls — read before filing a bug](#pitfalls)
11. [Public API surface](#public-api)
12. [FAQ](#faq)
13. [Migration from older versions](#migration)
14. [Support](#support)
15. [License](#license)

---

## Why this SDK

| You want | The SDK gives you |
|---|---|
| Switch between AdMob and AppLovin without rewriting code | One `AdConfig.provider` flag |
| First-session ad-free experience for new installs (boost D1 retention) | `firstInstallVipGrace` — auto-grants VIP for 24 hours on first install |
| GDPR-compliant consent UI without integrating a third-party CMP | Built-in Cupertino consent dialog, auto-shown post-splash |
| Google UMP form for EEA users | `AdManager().requestUmpConsent()` — wraps `google_mobile_ads`'s built-in `ConsentInformation` API |
| Anti-fraud protection so AdMob doesn't suspend your account | Multi-layer safety gate: per-session/hour/day caps, throttle, CTR threshold, click-spam detection, progressive cooldown |
| Banner that pauses on navigation and resumes on return | `buildBanner()` — hooks into the navigator and adapter lifecycle automatically |
| Revenue tracking for LTV analytics | `Stream<AdEvent>` emits `AdRevenueEvent` per impression |
| Sane behavior when Android kills the process under memory pressure | Smart App-Open timeout (lifecycle-aware), process-restart marker, detached state warning |

---

## Known limitations — read before adopting

This SDK has extensive automated coverage (500+ unit/widget tests, plus a
cross-platform integration_test matrix on Android + iOS × both providers),
and several real bugs have been found and fixed through that process. That
is not the same claim as "battle-tested in production by third parties" —
be clear-eyed about the gap before depending on it for revenue:

- **Ad-policy risk is not this SDK's to control.** It's a thin wrapper over
  AppLovin MAX and Google Mobile Ads. Fill rate, fraud detection accuracy,
  and account-level policy enforcement (suspensions, strikes) are decided by
  those platforms, not by this package. The built-in safety layer (daily/
  hourly caps, throttle, CTR-based fraud heuristics) reduces obviously bad
  behavior but has not been validated against a real policy review.
- **The real ad show/dismiss lifecycle is only partially automatable.**
  Real AppLovin MAX test-ad creatives expose no accessible dismiss element,
  so 3 of the ~15 integration_test scenarios (app-open/interstitial/rewarded
  dismiss) can only be verified manually, not via CI. Everything else in the
  lifecycle (load, show, click, reward callbacks, VIP suppression, safety
  gating) is automated and re-run on every change.
- **Known limitation:** `app_open_ad_test.dart` / `interstitial_ad_test.dart`
  / `rewarded_ad_test.dart` call `showXAd()` twice back-to-back without
  waiting for the ad to finish loading first. Whether they exercise the real
  show+dismiss path or fall into the safe "ad not ready, skip" fallback is a
  coin-flip race against ad-network response time on the day they're run —
  confirmed by log tracing across multiple runs where the fallback fired
  every time. **A green PASS on these 3 tests does not by itself prove real
  ad-display behavior was exercised for that run** — check the run's log for
  `loadX ✅` landing before vs. after the `showXAd` attempts to know which
  path actually executed. Fixing this properly means making the tests await
  ad-ready (with a timeout) before tapping show, which has not been done.
- **Limited real-world production history.** As of this writing the only
  first-party app running the hosted pub.dev release is this repo's own
  host app. If you're evaluating this for a partner or a new app, check that
  app's live AdMob/AppLovin dashboards (fill rate, policy flags, crash
  reports, revenue trend) over a multi-week window before treating this as
  proven at scale — that's stronger evidence than any test suite here.
- **Single maintainer, no SLA.** There's no dedicated support team behind
  this package; plan integration/rollback risk accordingly.

**Recommended adoption path for a new consumer (including internal
partners):** start with a small-traffic, time-boxed pilot on one app,
watching the same dashboards above for a few weeks, rather than a
wholesale integration on day one.

## What's new in 1.0.23

> **1.0.20** demoed the recommended `requestAtt() → requestUmpConsent() →
> initialize()` ordering in the example splash (no library change). **1.0.21**,
> **1.0.22** and **1.0.23** are the additions below. (Note: 1.0.21/1.0.22 are in
> the changelog but were never published to pub.dev — the public line jumped
> 1.0.20 → 1.0.23.)

Backwards-compatible with 1.0.1x. Recent additions:

- **App Open never stacks on a modal (1.0.23)** — `AdScreenRouteLogger` now
  counts `PopupRoute`s (dialogs, bottom sheets, Cupertino popups) and exposes
  `isDialogOnTop`; `showAppOpenAdOnResume` consults it plus
  `AdLoadingDialog.isShowing` and **skips the App Open ad while any dialog is
  presented** (e.g. the consent dialog or a VIP redeem confirmation). The
  `_retryRefillAds` periodic scan also returns early for VIP members.
- **VIP time stacking (1.0.22)** — `VipManager.addVip` / `redeemVip` gained an
  opt-in `stack` flag (default `false`). With `stack: true` the grant
  **accumulates onto the latest expiry across ALL active entries** (global
  stacking), so VIP time from every source adds to one growing window. Optional
  `AdConfig.maxVipStackDuration` clamps the total stacked window. See VIP system.
- **Rewarded-while-VIP (1.0.22)** — `AdManager().showRewardedAd` gained a
  `bypassVipGuard` flag (default `false`): a VIP member can voluntarily watch a
  **real** rewarded ad (e.g. to extend their own window). The slot isn't
  preloaded while VIP, so the SDK loads it on demand (tunable
  `onDemandLoadTimeout`, default 15 s) behind a blocking `AdLoadingDialog`.
- **Dependency refresh (1.0.21)** — `google_mobile_ads` → `^7.0.0`,
  `flutter_secure_storage` → `^10.0.0`, `applovin_max` → `^4.6.4`; dropped the
  deprecated `encryptedSharedPreferences` AndroidOptions flag. No public-API
  change; added tests.
- **iOS App Tracking Transparency (1.0.19)** — `AdManager().requestAtt()` /
  `requestAttIfNeeded()` show the ATT prompt when needed and return a structured
  `AttResult { status, idfa, allowsTracking }` (`AttStatus` enum). No-op on
  Android; never throws. Call it in the splash before UMP. See Consent → Option 0.
- **iOS App-Open watchdog fix (1.0.19)** — the lifecycle-aware show timeout no
  longer force-dismisses on iOS. On iOS the ad shows while the app stays
  `resumed`, so the Android-only "foreground = hung" heuristic was force-closing
  every iOS App Open at ~10 s; iOS now relies on the native hidden/displayFailed
  callbacks plus the 90 s hard cap.
- **First-install anti-bypass guard (1.0.17)** — the first-install VIP grace is
  protected against uninstall/reinstall bypass (iOS Keychain flag; Android Auto
  Backup of `SharedPreferences`).

Earlier, the 1.0.15 release added:

- **Cupertino consent dialog** — opt-in via `AdConfig.autoShowConsentDialog: true` (the default). Auto-shows on the home screen ~1 second after the splash flow completes, never during splash. Skipped automatically for VIP users. Persists the user's choice; surfaces the choice via `ConsentManager.instance` for re-show from a Privacy settings page.
- **Google UMP wrapper** — `AdManager().requestUmpConsent(...)` calls into `google_mobile_ads`'s built-in UMP API (no extra dependency needed since `google_mobile_ads` 6.x). Returns a structured `UmpConsentResult { canRequestAds, status, formShown, error }`.
- **First-install VIP grace** — `AdConfig.firstInstallVipGrace: FirstInstallVipGrace.auto` (default). Auto-grants a one-time VIP entry on the very first SDK init for this install. Default: 30 seconds in debug builds, 24 hours in release. Tracked via `SharedPreferences` so the grant fires exactly once per install.
- **Smart App-Open timeout** — replaces a fixed 10-second timeout that produced false-positive force-dismisses when users clicked an ad and were sent to a browser for 20+ seconds. The timeout polls the app lifecycle every 5 seconds (re-arms while paused), with a 90-second hard cap. On **Android** it force-dismisses when the app is foreground for two consecutive ticks without `onAdHiddenCallback` (= hung overlay). On **iOS** the ad shows while the app stays `resumed`, so foreground is ignored and only the native callbacks + 90 s hard cap apply (fixed in 1.0.19).
- **Slot-state dismiss watcher** — replaces the brittle adapter-callback timestamp writes that used to fire at the wrong moment for rewarded ads (rewarded `onDone` fires when the reward is earned, not when the user actually dismisses). The watcher hooks every fullscreen slot's `state.value` and records the dismiss instant on `showing → !showing`. Source of truth for the resume guard.
- **VIP auto-expire timer** — `VipManager` now schedules a `Timer` for the soonest `expiresAt`. When it fires, the manager purges the expired entry, refreshes the active flag, and `AdManager` (listening to `vip.activeListenable`) preloads all four ad slots so the next user-triggered show finds an ad ready.
- **Granular diagnostic logging** — every gate (`adapter null`, `VIP`, `no network`, `slot showing`, safety reason, recent dismiss) emits an explicit `⏭️ skipped — <reason>` log instead of returning silently. Process-restart marker `🚀 AdManager singleton CREATED` fires once per process so two markers in the same logcat session indicate Android killed and restarted the app. Lifecycle observer logs full state (`prev → current`, slot states, VIP, splash flag, backgrounded duration).

See `CHANGELOG.md` for the full list, including all bug fixes.

---

## Quick start

> **Audience: developers integrating ads into a fresh Flutter app.** No prior AdMob or AppLovin experience required. Each step is copy-paste.

### Prerequisites

- Flutter 3.27.0 or newer
- Android `minSdkVersion` 24 or newer (AppLovin MAX 13.x + AdMob requirement)
- iOS deployment target 13.0 or newer (required by AppLovin MAX 13.x and `app_tracking_transparency`)
- An [AdMob account](https://admob.google.com) (for AdMob ad units), an [AppLovin account](https://dash.applovin.com) (for AppLovin), or both. The SDK ships Google's public test ad unit IDs so you can verify integration before creating real units.

### Step 1 — Add the dependency

Edit your app's `pubspec.yaml`:

```yaml
dependencies:
  applovin_admob_sdk: ^1.0.23

  # Optional — only if you want to use AppLovin as an AdMob mediation network.
  # Skip this line if you are using AppLovin directly via AdProvider.appLovin
  # or AdMob without mediation.
  gma_mediation_applovin:
```

Then run:

```bash
flutter pub get
```

### Step 2 — Android configuration

Open `android/app/src/main/AndroidManifest.xml` and add the three permissions inside `<manifest>`:

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>
<uses-permission android:name="com.google.android.gms.permission.AD_ID"/>
```

Inside `<application>`, add the two `<meta-data>` tags below. Replace each value with your real key from the respective dashboard. The placeholders below use Google's public test App ID (always valid) and a placeholder for the AppLovin SDK key:

```xml
<application
    android:label="My App"
    android:icon="@mipmap/ic_launcher">

    <!-- Required by google_mobile_ads even if you only use AppLovin.
         Get yours from https://admob.google.com → Settings → App ID. -->
    <meta-data
        android:name="com.google.android.gms.ads.APPLICATION_ID"
        android:value="ca-app-pub-3940256099942544~3347511713"/>

    <!-- NOTE: `applovin_max` 4.x (used by this SDK) does NOT read the SDK key
         from a manifest meta-data. The 86-character key is passed at runtime via
         `AppLovinConfig.sdkKey` → `AdManager().initialize(...)`. You do NOT need
         an `applovin.sdk.key` meta-data here; adding one is harmless but ignored.
         Get the key from https://dash.applovin.com/o/account → Account → Keys. -->

    <activity
        android:name=".MainActivity"
        android:exported="true"
        android:launchMode="singleTop"
        ...>
        <!-- ⚠️ Do NOT add android:taskAffinity="" here. See "Pitfalls" below. -->
    </activity>
</application>
```

Update `android/app/build.gradle.kts` (or `build.gradle`) to require Android 5.0 or newer:

```kotlin
android {
    defaultConfig {
        minSdk = 24
        // ...
    }
}
```

### Step 3 — iOS configuration

Open `ios/Runner/Info.plist` and add the keys below at the root `<dict>`. Replace `YOUR_…` placeholders:

```xml
<!-- AdMob App ID — must match the Android one for the same app -->
<key>GADApplicationIdentifier</key>
<string>ca-app-pub-3940256099942544~1458002511</string>

<!-- AppLovin SDK Key — must match the Android one -->
<key>AppLovinSdkKey</key>
<string>YOUR_86_CHARACTER_APPLOVIN_SDK_KEY_HERE</string>

<!-- Required since iOS 14.5: shown in the system ATT prompt -->
<key>NSUserTrackingUsageDescription</key>
<string>This identifier is used to deliver personalised ads.</string>

<!-- Required by AdMob & AppLovin MAX mediation on iOS 14.5+. AdMob's own
     canonical list (https://developers.google.com/admob/ios/ios14#skadnetwork)
     is only 50 entries — it doesn't cover AppLovin MAX's mediation partners.
     Use AppLovin's official superset instead (152 entries, includes all 50
     AdMob IDs): https://skadnetwork-ids.applovin.com/v1/skadnetworkids.json -->
<key>SKAdNetworkItems</key>
<array>
    <!-- 152 entries — paste from the AppLovin link above -->
</array>
```

Update `ios/Podfile` to require iOS 13 or newer:

```ruby
platform :ios, '13.0'
```

Then install pods:

```bash
cd ios && pod install && cd ..
```

### Step 4 — Bootstrap the SDK in `main.dart`

Replace your `lib/main.dart` with this:

```dart
import 'package:flutter/material.dart';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

import 'splash_screen.dart';

/// Global navigator key — required so the SDK can show consent dialogs and
/// loading buffers from a context-less callback path (e.g., from the lifecycle
/// observer when an ad dismisses).
final navigatorKey = GlobalKey<NavigatorState>();

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // ⚠️ This MUST be called before runApp(). The SDK's auto-show consent
  // dialog and app-open-on-resume buffer rely on this navigator.
  AdManager().setNavigatorKey(navigatorKey);

  runApp(MaterialApp(
    title: 'My App',
    navigatorKey: navigatorKey,
    // ⚠️ Both observers are required:
    //   - adRouteObserver: pauses banner refresh on navigation,
    //                      resumes when the route comes back to top
    //   - AdScreenRouteLogger: emits route push/pop logs (debug only)
    navigatorObservers: [adRouteObserver, AdScreenRouteLogger()],
    home: const SplashScreen(),
  ));
}
```

### Step 5 — Initialize the SDK in `splash_screen.dart`

Create `lib/splash_screen.dart`. Replace the five `TODO` ad-unit IDs with values from your AppLovin dashboard. The AdMob IDs are Google's public test units and can be left as-is for verification:

```dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

import 'home_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  Timer? _hardCap;
  bool _navigated = false;

  @override
  void initState() {
    super.initState();

    AdManager().markSplashActive();
    AdManager().incrementSplashCount();

    // If the user reopens the app while the splash is still on the stack
    // (rare race), short-circuit straight to home.
    if (AdManager().countInitSplashScreen > 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _goHome());
      return;
    }

    // Hard cap: if the SDK init or the splash app-open ad takes longer than
    // the budget (network issues, etc.), force-navigate so the user is not
    // stuck on the splash screen. Keep this in sync with
    // `AdConfig.splashMaxDuration` (default 8 s).
    _hardCap = Timer(const Duration(seconds: 8), _goHome);

    // ⚠️ Subscribe BEFORE calling initialize(). SimpleEventBus only
    // delivers fire events to listeners that registered before the fire.
    SimpleEventBus().listen((BoolEvent e) {
      if (e.value) {
        _showSplashAppOpen();
      } else {
        _goHome();
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      AdManager().initialize(
        config: AdConfig(
          // Pick one. Switch by changing this single line.
          provider: AdProvider.appLovin,

          // TODO: replace with your real keys from dash.applovin.com
          appLovin: const AppLovinConfig(
            sdkKey:        'YOUR_86_CHARACTER_APPLOVIN_SDK_KEY_HERE',
            bannerId:      'YOUR_BANNER_AD_UNIT_ID',
            interstitialId:'YOUR_INTERSTITIAL_AD_UNIT_ID',
            appOpenId:     'YOUR_APP_OPEN_AD_UNIT_ID',
            rewardedId:    'YOUR_REWARDED_AD_UNIT_ID',
          ),

          // AdMob test units — public, always valid. Replace with your real
          // ad unit IDs (from admob.google.com) before publishing the app.
          admob: const AdMobConfig(
            bannerId:       'ca-app-pub-3940256099942544/6300978111',
            interstitialId: 'ca-app-pub-3940256099942544/1033173712',
            appOpenId:      'ca-app-pub-3940256099942544/9257395921',
            rewardedId:     'ca-app-pub-3940256099942544/5224354917',
          ),

          // Optional: localise the auto-show consent dialog.
          // ConsentDialogStrings.vi for Vietnamese, or pass your own.
          // consentDialogStrings: ConsentDialogStrings.vi,

          // Optional: validate redeemed VIP keys against your server.
          // vipKeyValidator: (key) => myServer.verifyVipKey(key),
        ),
        onComplete: (success, gaid) {
          // Optional: log to your analytics here.
          debugPrint('SDK init complete: success=$success gaid=$gaid');
        },
      );
    });
```

#### Per-platform ad-unit ids (T15)

`bannerId`/`interstitialId`/`appOpenId`/`rewardedId` are used on **both**
platforms by default — pass one id and it applies everywhere (fully backward
compatible). If Android and iOS have different ad units, add the optional
`android*Id`/`ios*Id` overrides; the SDK picks the right one via
`Platform.isAndroid`/`Platform.isIOS` when the getter is read:

```dart
admob: const AdMobConfig(
  bannerId: 'ca-app-pub-.../fallback-banner', // used if no override matches
  interstitialId: 'ca-app-pub-.../fallback-interstitial',
  appOpenId: 'ca-app-pub-.../fallback-app-open',
  rewardedId: 'ca-app-pub-.../fallback-rewarded',
  androidBannerId: 'ca-app-pub-.../android-banner',
  iosBannerId: 'ca-app-pub-.../ios-banner',
),
```

Same fields exist on `AppLovinConfig`. An override left `null` or `''` falls
back to the single id above — no breaking changes for existing configs.
  }

  void _showSplashAppOpen() {
    AdManager().loadAppOpenAd(onAdLoaded: (loaded) {
      if (_navigated || !mounted) return;
      if (!loaded) {
        _goHome();
        return;
      }
      AdLoadingDialog.showAdBuffer(context, onComplete: () {
        if (!mounted) {
          _goHome();
          return;
        }
        // Cancel the hard cap BEFORE showAppOpenAd — the ad now owns the
        // splash screen, so we should not race-fire markSplashInactive.
        _hardCap?.cancel();
        _hardCap = null;
        AdManager().showAppOpenAd(
          // bypassSafety: true is the ONE place we override safety —
          // splash app-open is a privileged placement.
          bypassSafety: true,
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
    AdManager().markSplashInactive();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
    );
  }

  @override
  void dispose() {
    _hardCap?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const Scaffold(
        backgroundColor: Colors.deepPurple,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.ads_click, size: 80, color: Colors.white),
              SizedBox(height: 24),
              CircularProgressIndicator(color: Colors.white),
            ],
          ),
        ),
      );
}
```

### Step 6 — Show ads on any screen

Create `lib/home_screen.dart`. Any screen that should display ads extends `AdScreen` and uses `AdScreenState` instead of `StatefulWidget` and `State`. This gives you `buildBanner()`, `showInterstitialAd(...)`, and `showRewardedAd(...)` automatically:

```dart
import 'package:flutter/material.dart';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

class HomeScreen extends AdScreen {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends AdScreenState<HomeScreen> {
  int _coins = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('My App')),
        body: Column(
          children: [
            // Anchored adaptive banner. Auto-loads, auto-pauses on
            // navigation, auto-resumes on return, auto-skips if VIP.
            buildBanner(),

            const SizedBox(height: 24),
            Text('Coins: $_coins', style: const TextStyle(fontSize: 24)),
            const SizedBox(height: 24),

            // Interstitial — full-screen ad after a user action
            FilledButton(
              onPressed: () => showInterstitialAd(
                onDone: (shown) {
                  // Called whether or not the ad actually appeared.
                  // shown=true → ad was displayed and dismissed
                  // shown=false → blocked by safety, VIP, no network, etc.
                  debugPrint('Interstitial result: $shown');
                },
              ),
              child: const Text('Show interstitial'),
            ),

            const SizedBox(height: 12),

            // Rewarded — user opts in to watch in exchange for a reward
            FilledButton(
              onPressed: () => showRewardedAd(
                onEarnedReward: (earned) {
                  if (earned) {
                    setState(() => _coins += 10);
                  }
                },
              ),
              child: const Text('Watch ad for +10 coins'),
            ),
          ],
        ),
      );
}
```

That's the entire integration. Run:

```bash
flutter run
```

You should see the splash screen, then a splash app-open ad (if available), then the home screen. After ~1 second on the home screen, the consent dialog appears (skipped on subsequent launches once the user has answered). The default behaviour you get out-of-the-box:

- ✅ **First-install VIP grace 24h** — the user does not see ads during their first 24 hours after install. Tunable via `AdConfig.firstInstallVipGrace`.
- ✅ **Cupertino consent dialog** auto-shown ~1 second after splash on the home screen (skipped if VIP). Tunable via `AdConfig.autoShowConsentDialog`, `consentDialogStrings`, `consentDialogPostSplashDelay`.
- ✅ **Splash app-open ad** with an 8-second hard cap so the user is never stuck.
- ✅ **Banner pause/resume** automatically when the user navigates between screens.
- ✅ **App Open ad auto-skips while a dialog/modal is on top** (1.0.23) — it never stacks over the consent dialog, a VIP redeem confirmation, or any bottom sheet.
- ✅ **Anti-fraud** multi-layer safety gate protects your AdMob/AppLovin account.

---

## Configuration reference

### `AdConfig`

```dart
AdConfig({
  // ─── Provider selection ─────────────────────────────────────────
  required AdProvider provider,
  AppLovinConfig? appLovin,
  AdMobConfig? admob,

  // ─── First-install VIP grace ────────────────────────────────────
  FirstInstallVipGrace firstInstallVipGrace = FirstInstallVipGrace.auto,
  String firstInstallVipKey = '__FIRST_INSTALL__',

  // ─── Consent flow ───────────────────────────────────────────────
  bool autoShowConsentDialog = true,
  ConsentDialogStrings consentDialogStrings = const ConsentDialogStrings(),
  bool consentBarrierDismissible = false,
  Duration consentDialogPostSplashDelay = const Duration(seconds: 1),

  // ─── Logging ────────────────────────────────────────────────────
  AdLogLevel logLevel = AdLogLevel.verbose,
  List<String>? logTagFilter,
  AdLogSink? onLog,

  // ─── Safety / fraud protection ──────────────────────────────────
  AdSafetyParams safety = AdSafetyParams.auto,

  // ─── VIP ────────────────────────────────────────────────────────
  Future<bool> Function(String key)? vipKeyValidator,
  VipDialogStrings vipDialogStrings = const VipDialogStrings(),
  // Legacy 1.x GAID allow-list — auto-migrated to VipManager entries
  // (year-2099 expiry) on first init for the matching device only.
  List<String> vipDeviceGaids = const [],

  // ─── Splash flow ────────────────────────────────────────────────
  Duration splashMaxDuration = const Duration(seconds: 8),

  // ─── User-facing strings ────────────────────────────────────────
  String adNotReadyMessage = 'Ad not ready — please wait and try again.',
  String adLoadingMessage = 'Loading…',

  // ─── Loading buffer ─────────────────────────────────────────────
  int loadingBufferMs = 1000,
})
```

### `FirstInstallVipGrace`

Build-mode-aware presets — picks the right duration based on `kDebugMode`:

```dart
FirstInstallVipGrace.auto       // 30s in debug, 24h in release (DEFAULT)
FirstInstallVipGrace.disabled   // never grant
FirstInstallVipGrace.day        // force 24h in both modes
FirstInstallVipGrace.debugShort // force 30s in both modes
const FirstInstallVipGrace(Duration(hours: 12))  // custom
```

The grant fires exactly once per install. Calling `AdManager.destroy()` followed by `AdManager.initialize()` in the same process does **not** re-grant.

### `AdSafetyParams` presets

```dart
AdSafetyParams.auto         // production in release, debug in debug (DEFAULT)
AdSafetyParams.production   // strict caps for real users
AdSafetyParams.debug        // loose caps for QA testing
AdSafetyParams.production.copyWith(
  maxFullscreenAdsPerDay: 10,
  dryRun: kDebugMode,
)                           // override individual knobs
```

### `AdLogLevel`

```dart
AdLogLevel.verbose   // everything (DEFAULT)
AdLogLevel.warning   // warnings + errors only
AdLogLevel.error     // errors only
AdLogLevel.none      // silent
```

---

## VIP system

### Signed VIP keys (offline, forge-proof) — T18

VIP redeem codes are **Ed25519-signed** and verified **offline** against a public
key embedded in the app. The matching **private key never ships**, so a
decompiler cannot forge new valid keys. There is **no server and no shared
secret** — a leaked *legitimate* key can still be reused on other devices (true
global one-time-use needs a backend), but per-device reuse is blocked.

**1. Generate a key pair once (keep the private key secret):**

```bash
cd packages/ad_sdk
dart run tool/vip_keygen.dart
# PUBLIC  (embed in app): <base64url>
# PRIVATE (keep secret!): <base64url>   ← store in a secret manager, never commit
```

**2. Mint keys offline with the private key:**

```bash
dart run tool/vip_mint.dart --priv <b64priv> --days 30 --kid promo30_001
# → AVP1.<payload>.<signature>
```

**3. Embed the public key + redeem in-app:**

```dart
final result = await AdManager().vip!.redeemSignedKey(
  userInput,
  publicKeyBase64: kVipPublicKeyBase64, // your public key
  stack: true,                          // add onto the current VIP window
);
switch (result.status) {
  case VipRedeemStatus.success:     /* granted result.entry */ break;
  case VipRedeemStatus.alreadyUsed: /* this key already used on this device */ break;
  case VipRedeemStatus.invalid:     /* bad/forged/expired key */ break;
}
```

Key format: `AVP1.<b64url(payload)>.<b64url(sig)>`, `payload = "<seconds>|<keyId>"`.
The VIP duration is read from the key; `keyId` drives per-device one-time-use.
Use `verifySignedVipKey(code, publicKeyBase64: ...)` directly if you only need to
inspect a key without redeeming.

### Conflict policy: latest-expiry-wins vs. global stacking

The `stack` flag decides how a grant combines with existing VIP time:

| `stack` | Behaviour | Use for |
|---------|-----------|---------|
| `false` *(default)* | **Latest-expiry-wins** — when an entry with the same key exists, the new `now + duration` replaces it only if it expires later; otherwise the existing (longer) entry is kept. | Purchases/restore where you set an absolute window. |
| `true` | **Global stacking (cộng dồn toàn cục)** — `duration` is added on top of the **latest expiry across ALL active entries** (any source). Every grant extends one growing VIP window; the granted key's entry becomes the new latest (created if new, updated if it existed) and `grantedAt` resets to now. | "Redeem code", "watch ad → +N days" — all accumulate. |

```dart
// Global stacking: grants from ANY key add to one timeline.
await vip.addVip(key: 'WATCH',  duration: const Duration(days: 6),  stack: true); // 6d
await vip.addVip(key: 'PROMO30', duration: const Duration(days: 30), stack: true); // 36d total
await vip.addVip(key: 'PROMO30', duration: const Duration(days: 30), stack: true); // 66d total
```

**Optional cap.** Set `AdConfig.maxVipStackDuration` to bound the *total* stacked
window — a stacked grant is then clamped to `now + maxVipStackDuration` (excess
dropped; the entry still extends up to the cap). `null` (default) = uncapped.
Only the stacking path is clamped; a plain absolute `addVip` is never touched.

### Programmatic add (purchase / restore flow)

Use this when the user purchases a VIP unlock through your IAP flow:

```dart
await AdManager().vip!.addVip(
  key: 'PURCHASED_PREMIUM_${transactionId}',
  duration: const Duration(days: 365),
);
```

### Cupertino dialog redeem (user inputs a key)

Use this if you ship promo/redeem keys for VIP. The SDK shows a verifying → success/failed Cupertino dialog flow:

```dart
final didRedeem = await AdManager().vip!.redeemVip(
  context,
  key: userInputKey,
  duration: const Duration(days: 30),
  validator: (key) async {
    // Validate against your server. Return true if valid.
    final response = await myServer.verifyVip(key);
    return response.isValid;
  },
  strings: AdManager().config?.vipDialogStrings ?? const VipDialogStrings(),
  stack: true, // accumulate onto the current window instead of replacing
);
```

### Watch a rewarded ad to EXTEND VIP (even while already VIP)

By default the SDK suppresses every ad for a VIP member, so a rewarded ad will
not play (`showRewardedAd` calls back with `vipAutoGrant`). To let a VIP
*voluntarily* watch a **real** rewarded ad to top up their window, pass
`bypassVipGuard: true`. The slot isn't preloaded while VIP, so the SDK
load-on-demands it before showing:

```dart
AdManager().showRewardedAd(
  bypassVipGuard: true,            // play a real ad even for a VIP
  onEarnedReward: (earned) {
    if (!earned) return;           // only granted on a completed ad — never auto-granted
    AdManager().vip?.addVip(
      key: 'REWARDED_VIP',         // fixed key + stack → one accumulating entry
      duration: const Duration(days: 3),
      stack: true,
    );
  },
);
```

During the on-demand load the SDK shows a blocking loading dialog and waits up
to `onDemandLoadTimeout` (default 15 s, tunable per call). `showRewardedAd` is
re-entrancy-safe — a second tap while a load/show is in flight is rejected with
`onEarnedReward(false)`.

> Policy note: this is compliant because a real ad is always shown. Do **not**
> instead grant VIP without an ad — that loses revenue and risks rewarded-ad
> policy violations. Spam is bounded by the SDK's fullscreen safety caps.

### Check VIP state

```dart
// Synchronous check
if (AdManager().vip?.isActive ?? false) {
  // User is VIP — render premium UI
}

// Reactive — rebuilds when VIP state changes
ValueListenableBuilder<bool>(
  valueListenable: AdManager().vip!.activeListenable,
  builder: (_, active, __) => active
      ? const VipBadge()
      : const SizedBox.shrink(),
)

// Stream — for analytics / side effects
AdManager().vip!.activeStream.listen((active) {
  analytics.logEvent('vip_state_changed', {'active': active});
});
```

### Revoke

```dart
// Specific key (e.g., user requested refund)
await AdManager().vip!.revokeVip('PURCHASED_PREMIUM_${transactionId}');

// All entries (e.g., logout)
await AdManager().vip!.revokeAll();
```

### Disable first-install grace

If your app does not want the 24-hour grace (some genres prefer to monetize immediately):

```dart
AdConfig(
  firstInstallVipGrace: FirstInstallVipGrace.disabled,
  // ...
)
```

### Anti-bypass guard

The grace is protected against the trivial bypass of "uninstall + reinstall to claim a fresh 24-hour window." The guard runs automatically inside `AdManager.initialize` — host apps need no code changes for the iOS side. **Android requires host-app Auto Backup configuration** (see below).

| Platform | Mechanism                                                                                              | Bypass-blocked scenarios                                              | Limitations                                                                                              |
|----------|--------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------|
| iOS      | Boolean flag in Keychain (`kSecAttrAccessibleAfterFirstUnlock`, no sync)                               | Uninstall + reinstall on same device                                  | "Erase All Content and Settings" wipes Keychain; encrypted backup → new device carries the flag          |
| Android  | Host's `SharedPreferences` flag (`isFirstInstallGraceApplied`) restored from Google Cloud Auto Backup  | Play Store reinstall on same Google account, after the ~24 h backup window | Reinstall within ~24 h of install (before Auto Backup runs); user disables cloud backup; cross-account reinstall |

#### Android — required host-app configuration

The SDK does not bundle a Play Install Referrer plugin: per Google's docs, Install Referrer timestamps reset on reinstall, so the API cannot distinguish a fresh install from a reinstall on its own. The realistic Android anti-bypass is **Google Auto Backup restoring the grace flag from `SharedPreferences`** on Play Store reinstall.

To enable it, in `android/app/src/main/AndroidManifest.xml`:

```xml
<application
    android:allowBackup="true"
    android:fullBackupContent="@xml/full_backup_content"
    android:dataExtractionRules="@xml/data_extraction_rules">
```

Create `android/app/src/main/res/xml/data_extraction_rules.xml` (Android 12+):

```xml
<?xml version="1.0" encoding="utf-8"?>
<data-extraction-rules>
  <cloud-backup>
    <include domain="sharedpref" path="FlutterSharedPreferences.xml"/>
    <exclude domain="sharedpref" path="FlutterSecureStorage.xml"/>
  </cloud-backup>
  <device-transfer>
    <include domain="sharedpref" path="FlutterSharedPreferences.xml"/>
    <exclude domain="sharedpref" path="FlutterSecureStorage.xml"/>
  </device-transfer>
</data-extraction-rules>
```

And `full_backup_content.xml` (Android 6–11):

```xml
<?xml version="1.0" encoding="utf-8"?>
<full-backup-content>
  <include domain="sharedpref" path="FlutterSharedPreferences.xml"/>
  <exclude domain="sharedpref" path="FlutterSecureStorage.xml"/>
</full-backup-content>
```

`FlutterSecureStorage.xml` is excluded because its EncryptedSharedPreferences ciphertext is unrecoverable without the device-bound Keystore key (which is not part of any backup).

Without this configuration, Android anti-bypass is effectively disabled — uninstall + reinstall always re-grants the grace window. That is a valid choice if you want to allow the bypass; just be aware of the trade-off.

#### Debug builds always bypass the guard

So you can iterate on `flutter run` without being locked out of the grace UX. Anti-bypass validation must happen on signed release builds (TestFlight / Play Store internal track).

#### Fail-open

The guard never denies grace on storage errors — it fails open so a transient Keychain hiccup never punishes a legitimate first-time user.

---

## Server-Side Verification (SSV) for rewarded ads

**This SDK does not run a server and does not verify anything itself.** Real
SSV verification happens entirely outside this SDK:

1. You configure an SSV callback URL for your rewarded ad unit in the
   **AppLovin dashboard** or the **AdMob dashboard**.
2. When a user earns a reward, AppLovin's/AdMob's servers make an HTTP
   request (a "postback") directly to **your own backend** at that URL —
   this SDK is not involved in that request at all.
3. Your backend verifies the postback's signature and identifying data
   (whatever you passed in step 1 below) before granting the reward
   server-side, which is what makes SSV resistant to client-side tampering
   that a purely `onEarnedReward` client callback is not.

What this SDK actually does — pure plumbing, nothing more:

- `AdManager().showRewardedAd(...)` takes two optional parameters,
  `ssvCustomData` and `ssvUserId`, so you can attach an identifier (e.g. your
  own user ID, or `"userId:orderId"`) to the specific ad show. Omit both for
  today's fully client-side behavior — nothing changes.
- That data is forwarded verbatim to the native SDK's real SSV field:
  AppLovin's `AppLovinMAX.showRewardedAd(adUnitId, customData: ...)` (AppLovin
  has one combined `custom_data` string field — pass `ssvUserId` if you don't
  need a separate custom payload), or AdMob's
  `RewardedAd.setServerSideOptions(ServerSideVerificationOptions(userId: ..., customData: ...))`.
- The reward result exposes `pendingServerConfirmation` (on `RewardResult`
  and on the `AdRewardEvent` from `AdManager().events`) — `true` only when you
  supplied `ssvCustomData`/`ssvUserId` for that show call, `false` otherwise.
  It's an informational flag meaning "your own backend's postback is the
  authoritative signal for this grant, not just this client-side callback" —
  the SDK does not poll for or otherwise track your backend's verification
  outcome.

```dart
AdManager().showRewardedAd(
  ssvUserId: currentUser.id,           // → forwarded to AppLovin/AdMob's SSV field
  onEarnedReward: (earned) {
    if (!earned) return;
    // Optimistic client-side UI update only. If you've configured an SSV
    // callback URL in the AppLovin/AdMob dashboard, YOUR backend receives
    // the authoritative postback independently of this callback.
  },
);
```

## Consent & compliance

The SDK supports three patterns. Pick whichever matches your release strategy.

### Option 1 — Built-in Cupertino dialog (simplest, default)

The SDK auto-shows a clean Cupertino dialog ~1 second after `markSplashInactive`, so it lands on the home screen rather than competing with the splash app-open ad. Persists the user's choice to SharedPreferences. Skipped automatically for VIP users.

No code required — this is the default. To re-show from a Privacy settings screen:

```dart
await ConsentManager.instance.showDialog(context);
```

To localize:

```dart
AdConfig(
  consentDialogStrings: ConsentDialogStrings.vi,  // Vietnamese pre-canned
  // or supply your own:
  consentDialogStrings: const ConsentDialogStrings(
    title: 'Privacy Preferences',
    message: 'This app shows ads to keep it free. ...',
    allowButton: 'Allow personalized ads',
    rejectButton: 'No thanks',
    privacyPolicyLabel: 'Privacy Policy',
    privacyPolicyUrl: 'https://yourapp.com/privacy',
  ),
)
```

To disable auto-show entirely (e.g., if you have your own consent UI):

```dart
AdConfig(
  autoShowConsentDialog: false,
)
```

### Option 0 — iOS App Tracking Transparency (call FIRST on iOS)

ATT is built into the SDK — do **not** call `app_tracking_transparency`
directly. Call `requestAtt()` from your **splash screen** (after the first
frame), **before** `requestUmpConsent` and `initialize`, so the IDFA
availability is settled before the first ad request:

```dart
final att = await AdManager().requestAtt();
// att.status   → AttStatus.{notSupported|notDetermined|restricted|denied|authorized}
// att.idfa     → String? (only when authorized and non-zero)
// att.allowsTracking → bool (true when authorized, or non-iOS where ATT doesn't apply)
```

- **No-op on Android** — returns `AttStatus.notSupported` immediately.
- On iOS it shows the system prompt only when the status is `notDetermined`;
  an already-decided status is returned without re-prompting.
- Never throws — a missing plugin / Info.plist key degrades to `denied`.
- **Do NOT call from `main()` before `runApp`** — Apple rejects ATT prompts
  shown over a blank screen.
- Requires `NSUserTrackingUsageDescription` in `Info.plist` (see Setup).
- ATT is **independent of the GDPR consent flag** — the native AppLovin/AdMob
  SDKs read the ATT status directly when deciding IDFA usage, so `requestAtt()`
  does not call `setConsent`.

### Option 2 — Google UMP form (required for EEA users on AdMob)

Wrap Google's UMP API. Call this in your splash **after** `requestAtt()` and
before `AdManager().initialize`:

```dart
final result = await AdManager().requestUmpConsent(
  testMode: kDebugMode,
  debugGeography: DebugGeography.debugGeographyEea,
  testIdentifiers: kDebugMode ? const ['<your-device-hash>'] : const [],
);

if (!result.canRequestAds) {
  // User denied consent. You can either:
  //   - Skip ad initialization entirely
  //   - Initialize with non-personalized ads only
  return;
}

// Continue with AdManager().initialize(...) as normal
```

#### Per-app-id setup (do this for EVERY app, not just once)

The UMP consent message is configured and **published per AdMob app ID** in
the AdMob console — it is **not** a one-time SDK-level setup. Every new app
(or clone of this app under a different AdMob account/app ID) needs its own
consent message published before shipping to EEA users, otherwise
`requestConsentInfoUpdate` fails with `no form(s) configured` and consent
gathering silently no-ops. Full step-by-step console instructions:
`doc/UMP_SETUP.md` (in the host app repo).

#### Privacy Options entry point (MUST — required by Google UMP policy)

Google requires every app that gathers UMP consent to expose a **durable,
always-visible** way for the user to change their choice later (e.g. a
"Privacy Settings" row in your Settings screen). Wire a permanent button that
calls `AdManager().showPrivacyOptions()`:

```dart
// Settings screen — always render this row; it's a safe no-op for users
// who were never shown a consent form (non-EEA / notRequired).
ListTile(
  title: const Text('Privacy Settings'),
  onTap: () async {
    final result = await AdManager().showPrivacyOptions();
    // result.formShown == true only when Google's UMP actually required
    // and displayed the native privacy-options form. Consent changes are
    // re-applied to the active ad provider (npa/RDP) automatically.
  },
);

// Optional: hide/disable the row instead of always showing it.
final required = await AdManager().isPrivacyOptionsRequired();
```

`showPrivacyOptions()` is safe to call unconditionally — it no-ops (does
**not** show any native UI) whenever Google's `ConsentInformation` reports the
privacy-options form isn't required for the current user. Call it any time
after `AdManager().initialize()`, from user interaction only — never as part
of app-startup gating.

### Option 3 — Manual flag set (you have your own UI)

If you already integrate a third-party CMP and just want the SDK to forward the flags to the providers:

```dart
await AdManager().setConsent(AdConsent(
  hasUserConsent: true,        // GDPR consent
  isAgeRestrictedUser: false,  // COPPA: app targets children < 13
  doNotSell: false,            // CCPA: California user opts out of data sale
));
```

### Compliance checklist

- [ ] `app-ads.txt` placed at the root of your app's domain
- [ ] Privacy Policy URL declared in App Store / Play Store listing
- [ ] iOS App Tracking Transparency prompt shown via `AdManager().requestAtt()` in the splash, **before** `requestUmpConsent` / `AdManager().initialize` (see Option 0)
- [ ] If app targets children, `isAgeRestrictedUser: true` (COPPA). AdMob honours this per-request via `tagForChildDirectedTreatment`. AppLovin MAX 4.x has no runtime child-directed API, so (T40, 2026-07-13) `AppLovinAdapter` refuses to initialize at all when `true` is known **at init time** (persisted from a prior session) — every AppLovin ad surface then stays unavailable for the session (exposed via `AppLovinAdapter.disabledForChildUser`). **Known gap**: on a brand-new install with no persisted consent yet, an app that is *always* child-directed (no consent dialog at all) will still see AppLovin initialize once, since there's nothing yet to gate on — don't rely on this SDK for an always-child-directed app without adding your own explicit "child app" config ahead of `initialize()`.
- [ ] If targeting EEA users, integrate UMP via Option 2 above
- [ ] UMP consent message **published** (not just saved as draft) for *this app's* specific AdMob app ID — required again for every new app ID, see "Per-app-id setup" above
- [x] **`example/` is not a production template** (T41, 2026-07-13): `example/lib/main.dart`'s AppLovin SDK key + ad-unit IDs are `YOUR_*` placeholders read via `String.fromEnvironment` — pass `--dart-define=APPLOVIN_SDK_KEY=...` (+ per-platform `_BANNER_ID_IOS`/`_BANNER_ID_ANDROID`/etc.) to exercise real ads locally; nothing real is committed to source. `example/lib/main.dart`'s safety preset (`kDemoSafetyParams`, 999 caps/CTR off) only applies with `--dart-define=QA_AD_STRESS=true` — default is `AdSafetyParams.auto`. Review both before copying this example into a real app.

---

## Debugging

### Built-in debug overlay

Wrap your `MaterialApp` builder to mount a floating debug panel that appears only in debug builds:

```dart
runApp(MaterialApp(
  // ...
  builder: (context, child) {
    if (child == null) return const SizedBox.shrink();
    return Stack(children: [
      child,
      const DebugAdOverlay(),
    ]);
  },
));
```

A `🐛 Ad` pill appears in the bottom-left corner. Tap to expand into a panel showing realtime SDK state: slot states (idle/loading/ready/showing/cooldown), VIP status, init flag, splash flag, safety status. Auto-hidden in release builds.

### Verbose logs

Every SDK log is prefixed with `roy93~ [Tag]` for easy `grep`. Examples:

```
roy93~ [AdManager] 🚀 AdManager singleton CREATED — new Flutter process / cold start at 2026-04-26T13:06:09.808
roy93~ [AdManager] initialize start, provider=appLovin
roy93~ [AppLovinAdapter] inter [AppLovin] ✅ displayed | network=AppLovin creativeId=1540789 latency=792ms
roy93~ [VipManager] ⏰ VIP entry expired — purging + refreshing
roy93~ [AdManager] 🛡️ interstitial dismissed — app-open suppression armed
roy93~ [AdManager] ⏭️ app-open on resume skipped — interstitial/rewarded currently showing
```

### Pipe logs into Crashlytics / Sentry

```dart
AdConfig(
  onLog: (level, tag, message) {
    if (level == AdLogLevel.error) {
      FirebaseCrashlytics.instance.log('[$tag] $message');
    }
    if (level == AdLogLevel.warning) {
      Sentry.captureMessage('[$tag] $message');
    }
  },
  // ...
)
```

### Process-restart marker

If you see two `🚀 AdManager singleton CREATED` markers in the same logcat session, Android killed and restarted your app between them — typically because of memory pressure while the user had a long ad open. The user perceives this as "the app crashed". Use this signal to size your in-memory cache budget appropriately.

---

## Pitfalls

### 1. Do NOT set `android:taskAffinity=""`

Flutter's `flutter create` template adds `android:taskAffinity=""` to `MainActivity` by default in some Flutter versions. **Remove it** when integrating this SDK with AppLovin:

```diff
  <activity
      android:name=".MainActivity"
      android:exported="true"
      android:launchMode="singleTop"
-     android:taskAffinity=""
      ...>
```

**Why**: AppLovin's full-screen ad activity (`AppLovinFullscreenActivity`) inherits the application's default task affinity, which is the package name. With `android:taskAffinity=""` on `MainActivity`, the two activities end up in different Android tasks. After the user presses HOME and reopens the app, the activity stack management breaks; when the user dismisses the ad, no activity is available to return to and Android drops the user to the launcher. The user perceives this as a crash.

### 2. iOS requires `SKAdNetworkItems`

Without `SKAdNetworkItems` in `Info.plist`, AdMob and AppLovin will not serve ads on iOS 14.5+. [AdMob's own canonical list](https://developers.google.com/admob/ios/ios14#skadnetwork) is only 50 entries and doesn't cover AppLovin MAX's mediation partners — use [AppLovin's official superset list](https://skadnetwork-ids.applovin.com/v1/skadnetworkids.json) instead (152 entries, a strict superset that includes all 50 AdMob IDs).

### 3. AppLovin has no public test ad units

Unlike AdMob, AppLovin requires a real account and real ad unit IDs. To avoid being charged for development impressions, register your test device in `dash.applovin.com → MAX → Test Mode`. The SDK auto-registers the current device's GAID in debug builds via `AppLovinMAX.setTestDeviceAdvertisingIds(...)` so this is mostly handled for you.

### 4. `setNavigatorKey` must be called before `runApp`

If you forget, the auto-show consent dialog has no `BuildContext` to use and silently skips. The dialog will eventually surface on a future launch, but better to wire it correctly the first time.

### 5. Initialize the SDK in `SplashScreen`, not `main`

The SDK fires a `BoolEvent` over `SimpleEventBus` when initialization completes. Listeners must be registered **before** the fire — `SimpleEventBus` does not buffer past events for late subscribers. The conventional pattern is:

1. `splash.initState`: register the listener
2. `splash.initState`: schedule `AdManager().initialize` via a post-frame callback
3. The init completes, `BoolEvent` fires, listener runs

If you initialize in `main` directly, the listener registration in your splash will miss the fire and the splash will hang on the hard cap.

### 6. Slot state after dismiss

The SDK's `_lastFullscreenDismissAt` is recorded by a slot-state watcher on the `showing → !showing` transition, not by adapter callbacks. This is the source of truth for the resume-guard window. If you wrap or override slot state mutation, ensure the transition still fires (`slot.markDismissed()` or equivalent).

---

## Public API

### `AdManager` singleton

```dart
AdManager()                                // factory; returns the singleton
AdManager().setNavigatorKey(key)           // call before runApp (REQUIRED)
AdManager().initialize(config, onComplete) // call once in splash
AdManager().destroy()                      // teardown for hot-reinit / test cleanup

AdManager().markSplashActive()
AdManager().markSplashInactive()
AdManager().incrementSplashCount()

AdManager().setConsent(adConsent)          // GDPR / COPPA / CCPA flags
AdManager().requestAtt()                   // iOS ATT prompt (no-op Android) → AttResult
AdManager().requestUmpConsent(...)         // Google UMP wrapper

AdManager().showAppOpenAd(onAdDismiss)
AdManager().showInterstitial(onDoneFlow)
AdManager().showRewardedAd(onEarnedReward, {vipAutoGrant, bypassVipGuard, onDemandLoadTimeout, ssvCustomData, ssvUserId})
AdManager().loadAppOpenAd(onAdLoaded)
AdManager().canShowInterstitial()

AdManager().isInitialised            // bool
AdManager().vip                      // VipManager? (null before init)
AdManager().consentManager           // ConsentManager?
AdManager().adapter                  // AdProviderAdapter?
AdManager().consent                  // current AdConsent flags
AdManager().events                   // Stream<AdEvent>
AdManager().initRevision             // ValueNotifier<int> — bumps on init
AdManager().processStartedAtMs       // wall-clock of singleton creation
```

### `AdScreen`

A base class for screens that display ads. Mirror replacement for `StatefulWidget`/`State`:

```dart
class HomeScreen extends AdScreen {
  const HomeScreen({super.key});
  @override State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends AdScreenState<HomeScreen> {
  Widget buildBanner();                                  // anchored adaptive banner
  void showInterstitialAd({required onDone, ...});       // pre-check + buffer + show
  Future<void> showRewardedAd({                          // pre-check + buffer + show
    required onEarnedReward,
    vipAutoGrant,
    placement,
    disclosureTitle,          // set → confirm dialog before the ad plays
    disclosureSubtitle,
    disclosureButtonLabel,     // default 'Watch ad'
    disclosureCancelLabel,     // default 'Cancel' — localize for non-English hosts
  });
}
```

`disclosureTitle` is opt-in: omit it and the call is unchanged (straight to the ad after
the ready/throttle pre-check). Pass it to show a small confirm dialog naming the reward
first — declining calls `onEarnedReward(false)` and never reaches the ad.

### `VipManager`

```dart
final vip = AdManager().vip!;

vip.addVip(key, duration, {stack})   // Future<VipEntry> — stack:true accumulates
vip.redeemVip(context, ..., {stack}) // Future<bool> — full Cupertino flow
vip.revokeVip(key)                   // Future<void>
vip.revokeAll()                      // Future<void>

vip.isActive                         // bool
vip.activeListenable                 // ValueListenable<bool>
vip.activeStream                     // Stream<bool>
vip.expiresAt                        // DateTime? — latest active entry
vip.entries                          // List<VipEntry> — read-only snapshot
```

### `ConsentManager`

```dart
final mgr = ConsentManager.instance;

mgr.current                          // ConsentSettings
mgr.listenable                       // ValueListenable<ConsentSettings>
mgr.hasBeenAsked                     // bool
mgr.adConsent                        // AdConsent — runtime flag projection

mgr.showDialog(context)              // re-show binary dialog
mgr.set(settings)                    // programmatic update + persist
mgr.applyToProviders()               // re-apply current to providers
mgr.reset()                          // wipe state — next init re-prompts
```

### `Stream<AdEvent>`

Pipe into Firebase / AppsFlyer / etc. for LTV tracking:

```dart
AdManager().events.listen((event) {
  if (event is AdRevenueEvent) {
    analytics.logAdRevenue(
      currency: event.currencyCode,
      value: event.value,
      network: event.networkName,
    );
  }
  if (event is AdRewardEvent) {
    analytics.logEvent('ad_reward', {'amount': event.amount});
  }
});
```

Event types: `AdLoadEvent`, `AdShowEvent`, `AdClickEvent`, `AdRewardEvent`, `AdRevenueEvent`.

---

## FAQ

### Do I need both AdMob and AppLovin accounts?

No. The provider you specify in `AdConfig.provider` determines which one is active at runtime. The other config struct (`appLovin` or `admob`) is unused but the constructor still requires the matching one to be non-null. Pass placeholder values for the unused one.

### Can I switch providers at runtime?

Not safely. Both SDKs are designed to initialize once per process. To swap, call `AdManager().destroy()`, change the config, and call `AdManager().initialize()` again — but be aware the user will see splash transitions and ad reload latency. Most apps pick one provider per build configuration.

### How do I test the first-install grace?

In debug builds, the grace defaults to 30 seconds. Wipe the app data and re-launch:

```bash
adb shell pm clear com.your.package
flutter run
```

The SDK logs `🎁 first-install VIP grace granted (30s, mode=debug)` on a fresh install. After 30 seconds the timer fires, `🔓 VIP inactive — kicking secondary preload` logs, and ads start serving.

Debug builds bypass the anti-bypass guard, so each `flutter run` cycle grants a fresh grace.

### How do I test the anti-bypass guard?

Anti-bypass only runs on **release builds**. Build a signed release and install it the way real users would:

- **iOS** — TestFlight or a signed Ad Hoc build. Install, wait for grace to expire (30 s in debug, 24 h in release — temporarily set `firstInstallVipGrace: FirstInstallVipGrace.debugShort` in your test build to keep the cycle short), uninstall, then reinstall. Look for `🛡️ Keychain flag present — prior install detected on this device` in the splash log on the second install.
- **Android** — Play Store internal testing track (Auto Backup must be configured — see "Android — required host-app configuration" above). Wait long enough for Auto Backup to run (typically ~24 h after first launch, or trigger manually via `adb shell bmgr backupnow <package>`). Then uninstall and reinstall. The grace block should be skipped because the restored prefs flag short-circuits before the guard runs.

Sideload via `adb install` of a release APK will simply re-grant the grace window each time — this is expected behaviour now that the SDK no longer ships an Install Referrer-based conservative skip.

### My ad is not showing — how do I debug?

1. Check the log for `⏭️ skipped — <reason>`. The SDK emits an explicit reason for every gate (adapter null, VIP, no network, slot showing, safety throttle, recent dismiss). The reason will tell you exactly what to fix.
2. Check the `DebugAdOverlay` for the slot state. `idle` means no load attempted; `loading` means in-flight; `ready` means good to show; `cooldown` means a recent failure backed off; `showing` means already on screen.
3. Verify your real ad unit IDs are not paused or pending review in the AdMob/AppLovin dashboard.
4. AppLovin specifically: check that test mode is enabled for your device (`dash.applovin.com → MAX → Test Mode`).

### Why does the app appear to crash when the user backgrounds during an ad?

If you see two `🚀 AdManager singleton CREATED` markers in your logcat session, Android killed and restarted your process while the user was viewing an ad with the app backgrounded. This is OS behavior — the SDK cannot prevent it directly, but you can mitigate by:

- Reducing the number of ads cached simultaneously (e.g., disable banner preload during interstitial show)
- Implementing state restoration so the user lands back on the same screen after the cold restart
- Showing fewer or shorter ads on memory-constrained device classes

If you see only one `🚀 CREATED` marker but the app still appears to crash, check that `android:taskAffinity=""` is **not** set on your `MainActivity` (see Pitfalls above).

### What happens if the user revokes VIP halfway through a session?

The SDK listens to `VipManager.activeListenable`. On `true → false` transition, it kicks all four ad slots into preload so the next user-triggered show finds an ad ready. The user's first ad after losing VIP may take 1-2 seconds to load (test ads load fast; real ads vary).

### I see "Throttle: wait 0s" — is that a bug?

That was a bug in 1.0.14 — sub-second waits truncated to zero. Fixed in 1.0.15: now displays "wait 645ms" or "wait 1.5s" depending on magnitude.

---

## Migration

See `MIGRATION.md` for a step-by-step guide.

- **1.0.14 → 1.0.15** — no breaking change. Update the version, run `flutter pub get`, optionally remove `android:taskAffinity=""` from `MainActivity`.
- **1.0.1x → 1.0.19** — no breaking change. New optional `AdManager().requestAtt()` for iOS ATT (call in splash before UMP); add `NSUserTrackingUsageDescription` to `Info.plist` if targeting iOS. iOS App-Open watchdog fix is automatic.
- **1.0.19 → 1.0.20** — no breaking change, no API change (example-only update).
- **1.0.20 → 1.0.21 → 1.0.22 → 1.0.23** — all backwards-compatible. Just bump the version and run `flutter pub get`. 1.0.21 refreshes dependencies; 1.0.22 adds the opt-in `stack` flag (VIP stacking), `bypassVipGuard` on `showRewardedAd`, and `AdConfig.maxVipStackDuration`; 1.0.23's App-Open-skip-on-dialog behaviour is automatic. (1.0.21/1.0.22 were not published to pub.dev — the public line jumped 1.0.20 → 1.0.23.)
- **1.x → 2.x** — backwards-compatible (deprecations, not removals). Old call sites compile and behave the same.

---

## Support

- **Bug reports**: open an issue on [GitHub](https://github.com/royt93/FlutterBase2025/issues) with `roy93~` log output, SDK version, and provider (admob/appLovin)
- **Demo app**: `packages/ad_sdk/example/lib/main.dart` — 11 self-contained demo pages, one per feature
- **Architecture deep-dive**: `doc/architecture.md` — state machine, splash flow, safety gate, memory management

---

## License

MIT — see `LICENSE` file.
