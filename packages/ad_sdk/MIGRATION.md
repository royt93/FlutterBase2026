# Migration Guide

Practical step-by-step guides for upgrading from older versions of `applovin_admob_sdk`.

## Table of contents

- [1.0.15 → 1.0.16](#1015--1016) — documentation-only release
- [1.0.14 → 1.0.15](#1014--1015) — no breaking changes; opt-in new features
- [1.x → 2.x (legacy upgrade path)](#1x--2x) — auto-migrating; old calls still work
- [Common issues](#common-issues)
- [FAQ](#faq)

---

## 1.0.15 → 1.0.16

**Documentation-only release.** No runtime code changes. Upgrading is a one-line version bump:

```diff
 dependencies:
-  applovin_admob_sdk: ^1.0.15
+  applovin_admob_sdk: ^1.0.16
```

```bash
flutter pub get
```

That is the entire upgrade. Public API surface and bundled assets are byte-for-byte identical to 1.0.15.

### What changed

- `README.md` — full English rewrite, restructured into 13 sections with copy-paste quick start
- `MIGRATION.md` — full English rewrite (this file)
- `doc/architecture.md` — full English rewrite, deeper coverage of the 1.0.15 changes
- `CHANGELOG.md` — added 1.0.16 entry

If you previously copy-pasted snippets from the old README in your own internal documentation, you may want to refresh from the new version. Otherwise nothing to do.

---

## 1.0.14 → 1.0.15

**No breaking changes.** All public API in 1.0.14 continues to compile and behave the same way in 1.0.15. The new features are opt-in and the new defaults are designed to be conservative.

### Step 1 — Bump the dependency

In your app's `pubspec.yaml`:

```diff
 dependencies:
-  applovin_admob_sdk: ^1.0.14
+  applovin_admob_sdk: ^1.0.16
```

Then:

```bash
flutter pub get
```

### Step 2 — Audit your AndroidManifest.xml

If your `MainActivity` declaration contains `android:taskAffinity=""`, **remove it**. This is the most important change in this upgrade.

```diff
 <activity
     android:name=".MainActivity"
     android:exported="true"
     android:launchMode="singleTop"
-    android:taskAffinity=""
     android:theme="@style/LaunchTheme"
     ...>
```

**Why this matters**: AppLovin's `AppLovinFullscreenActivity` inherits the application's default task affinity (the package name). With `android:taskAffinity=""` on `MainActivity`, the two activities live in different Android tasks. When the user presses HOME during an ad and reopens the app, then dismisses the ad, Android cannot find a previous activity to return to and drops the user to the launcher. Users perceive this as a crash even though the process is still alive.

This bug was masked in 1.0.14 because few users actually backgrounded mid-ad. We added detailed lifecycle logging in 1.0.15 that surfaced the issue in our QA, and the fix is removing this one attribute.

If you do not have `android:taskAffinity=""`, you have nothing to do for this step.

### Step 3 — Verify nothing regressed

Run your app, navigate to a screen that shows an interstitial, and:

1. Tap "Show ad"
2. Watch the ad fully (do not press HOME)
3. Tap the ad's close (×) button

The app should return to your screen seamlessly. If it does, you are done.

If you want to also verify the new background/foreground robustness:

1. Tap "Show ad"
2. Press HOME button (background the app while ad is showing)
3. Wait 30+ seconds
4. Reopen the app via launcher
5. Tap (×) to dismiss the ad

The app should return to your screen, not the launcher. If it drops you to the launcher, recheck Step 2 above.

### Step 4 (optional) — Adopt new features

The following are opt-in and disabled by default for backwards compatibility, except where noted:

#### Cupertino consent dialog (default ON)

Enabled by default. The SDK auto-shows a clean Cupertino dialog ~1 second after `markSplashInactive`, persists the user's choice, and skips for VIP users. **No code change required.**

To localize:

```dart
AdConfig(
  consentDialogStrings: ConsentDialogStrings.vi,  // Vietnamese pre-canned
  // or supply your own strings struct
)
```

To disable (e.g., if you have your own consent UI):

```dart
AdConfig(
  autoShowConsentDialog: false,
)
```

#### First-install VIP grace (default ON)

Enabled by default. New installs see no ads for 30 seconds in debug builds and 24 hours in release builds. **No code change required.**

To customize:

```dart
AdConfig(
  // Force 12 hours in both modes
  firstInstallVipGrace: const FirstInstallVipGrace(Duration(hours: 12)),
)

// Or disable entirely
AdConfig(
  firstInstallVipGrace: FirstInstallVipGrace.disabled,
)
```

#### Google UMP wrapper (opt-in)

If your app targets EEA users, you must integrate Google's UMP form. The SDK now wraps the API:

```dart
// In your splash, BEFORE AdManager().initialize:
final result = await AdManager().requestUmpConsent(
  testMode: kDebugMode,
  debugGeography: kDebugMode ? DebugGeography.debugGeographyEea : null,
);

if (!result.canRequestAds) {
  // User did not consent. Skip ad init or init in non-personalized mode.
  return;
}

// Continue with AdManager().initialize(...) as normal
```

This requires no extra dependency since `google_mobile_ads` 6.x ships UMP support.

#### Smart App-Open timeout (default ON)

The fixed 10-second timeout has been replaced with a lifecycle-aware polling timeout (5-second tick, 90-second hard cap). **No code change required.** This eliminates false-positive force-dismisses when users click an ad and are sent to a browser for 20+ seconds.

#### Slot-state dismiss watcher (default ON)

The SDK now records the dismiss timestamp from slot-state transitions instead of adapter callbacks. **No code change required.** This fixes a subtle bug where the rewarded ad's onDone callback fired at reward-earned time (not dismiss time), causing the resume-guard window to leak through and an app-open ad to show right after the rewarded.

---

## 1.x → 2.x

The 2.x series is mostly source-compatible with 1.x. Existing call sites compile and behave the same; old methods that no longer fit the architecture are deprecated rather than removed (will be removed in 3.0).

### 1. Update the import

The 1.x package exposed two identical entry points; 2.x keeps only one:

```diff
- import 'package:applovin_admob_sdk/ad_sdk.dart';
+ import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
```

### 2. Logger configuration

```diff
- SafeLogger.setEnabled(true);
+ // Configured automatically via AdConfig.logLevel — no manual call needed.
```

The new logger supports four levels with lazy interpolation (zero CPU cost when the level is suppressed):

```dart
AdConfig(
  logLevel: AdLogLevel.warning,                 // verbose | warning | error | none
  logTagFilter: ['AdManager', 'AdSafety'],      // optional allow-list
  onLog: (level, tag, message) {
    Sentry.captureMessage('[$tag] $message');   // pipe into your observability stack
  },
);
```

### 3. VIP API

The 1.x VIP API used the device's GAID as the identity. The 2.x API uses arbitrary keys with explicit expiry, allowing per-user, per-purchase, or per-promo-code grants.

#### 1.x

```dart
AdManager().addVIPMember(['gaid-1', 'gaid-2']);
final isVip = AdManager().isVIPMember();
```

#### 2.x / 1.0.15

```dart
// Programmatic add — for purchase / restore flows
await AdManager().vip!.addVip(
  key: 'PURCHASED_PREMIUM_${transactionId}',
  duration: const Duration(days: 365),
);

// Cupertino dialog redeem — for user-input promo keys
await AdManager().vip!.redeemVip(
  context,
  key: userInputKey,
  duration: const Duration(days: 30),
  validator: (key) => myServer.verifyVipKey(key),
  strings: AdManager().config?.vipDialogStrings ?? const VipDialogStrings(),
);

// Check
if (AdManager().vip?.isActive ?? false) {
  // user is VIP
}

// Reactive UI
ValueListenableBuilder<bool>(
  valueListenable: AdManager().vip!.activeListenable,
  builder: (_, active, __) => active ? VipBadge() : SizedBox.shrink(),
);
```

**Auto-migration**: any existing 1.x GAID list is automatically converted to `VipEntry` records (year-2099 expiry) on the first 2.x init. You do not need to write migration code. Only entries whose GAID matches the current device's GAID are preserved as active VIP — this matches the 1.x behavior exactly. The legacy methods (`addVIPMember`, `isVIPMember`) remain available but emit `@Deprecated` warnings.

### 4. Consent flags

The 1.x SDK had no first-class consent support. 2.x introduces `AdConsent` which is forwarded to both providers:

```dart
await AdManager().setConsent(AdConsent(
  hasUserConsent: true,        // GDPR
  isAgeRestrictedUser: false,  // COPPA
  doNotSell: false,            // CCPA
));
```

The default before any `setConsent` call is `AdConsent.conservative` (all flags false), which yields non-personalized ads everywhere — a safe default that does not require user action.

### 5. State machine — banner refactored

If you previously read banner state via raw bool getters (`bannerLoaded`, `bannerHasError`, etc.), switch to the listenables:

```diff
- if (AdManager().bannerLoaded) { ... }
+ ValueListenableBuilder<bool>(
+   valueListenable: AdManager().adapter!.banner.isLoaded,
+   builder: (_, loaded, __) => loaded ? BannerView() : Skeleton(),
+ );
```

Or simpler: extend `AdScreen` and use `buildBanner()` which handles all this automatically.

### 6. Project conventions — no `late` / `!` / `setState`

If your host app extends `BaseStatefulState` and follows the same convention, replace `late` and force-null with nullable:

```diff
- late final FooController controller;
- @override void initState() { controller = FooController(); }
- @override Widget build(_) => Text(controller.value);

+ FooController? controller;
+ @override void initState() { controller = FooController(); }
+ @override Widget build(_) {
+   final c = controller;
+   if (c == null) return const SizedBox.shrink();
+   return Text(c.value);
+ }
```

This is a project policy, not an SDK requirement. The SDK itself follows it but does not enforce it on host apps.

---

## Common issues

### "Build failed — `applovin_admob_sdk` is not in the dependency cache"

Pub.dev typically takes up to 10 minutes to index a newly published version. If you upgrade right after a release, wait a few minutes and re-run `flutter pub get`. If the issue persists, force a fresh fetch:

```bash
flutter pub cache clean -f
flutter pub get
```

### "Build failed — `Unexpected token` in `build.gradle.kts`"

Likely the `minSdk` or `targetSdk` is set with Groovy syntax (`minSdk 21`) in a Kotlin DSL file. Use Kotlin syntax (`minSdk = 21`).

### "App crashes when user backgrounds during an ad"

See `README.md` → Pitfalls → 1. Most likely you have `android:taskAffinity=""` on `MainActivity`. Remove it.

### Ads not loading on iOS

Verify `Info.plist` contains `SKAdNetworkItems`, `NSUserTrackingUsageDescription`, `AppLovinSdkKey`, and `GADApplicationIdentifier`. Verify Podfile targets iOS 12 or newer and you ran `pod install`.

### "Inter ad doesn't show — `canShow=false`"

Run with `AdConfig.logLevel = AdLogLevel.verbose` and check the log for `⏭️ showInterstitial blocked by safety: <reason>`. The reason tells you exactly which gate denied the show:

- `Suspended: Xs remaining` — progressive cooldown active because of a recent CTR/click anomaly. Wait it out or call `AdSafetyConfig.resetSession()` in QA.
- `Session too young: wait Xs` — `minSessionDurationBeforeAd` not yet elapsed.
- `Session limit: N ads` — hit `maxFullscreenAdsPerSession`.
- `Hourly cap: N ads` — hit `maxFullscreenAdsPerHour`.
- `Daily limit: N ads` — hit `maxFullscreenAdsPerDay` (persisted across launches).
- `Throttle: wait Xms` — too soon after the previous fullscreen ad.

### "VIP grace not expiring in dev"

Default debug grace is 30 seconds. Wipe app data to start fresh:

```bash
adb shell pm clear com.your.package
flutter run
```

Watch the log for `🎁 first-install VIP grace granted (30s, mode=debug)` and `⏰ VIP entry expired — purging + refreshing` 30 seconds later.

### Banner shows but no banner widget visible

Check that the banner is not being clipped by an oversized `Column` or `SafeArea` somewhere in the tree. The default banner height is 50–90dp depending on the device's adaptive size.

If the banner truly never loaded, you'll see `[BannerAdWidget] _initBanner ⏭️ <reason>` in the log:

- `⏭️ VIP` — VIP user, banner suppressed by design
- `⏭️ cooldown` — recent banner load failure, waiting for backoff
- `⏭️ already cached` — preloaded banner exists, will be reused on next mount

---

## FAQ

### Will my 1.0.14 code keep working in 1.0.15?

Yes. 1.0.15 has zero breaking changes. The new behaviors (auto consent dialog, first-install grace) are opt-in defaults that you can disable if they conflict with your existing UX.

### Should I migrate to 2.0?

The 2.0 release line is currently unreleased (the public stable line is 1.0.15). When 2.0 ships, it will remove all `@Deprecated` symbols listed in `CHANGELOG.md` — primarily the legacy GAID-based VIP API. If you have already migrated to the modern VipManager API in 1.0.15, the 2.0 upgrade will be trivial.

### How do I roll back from 1.0.15?

Pin to the previous version in `pubspec.yaml`:

```yaml
applovin_admob_sdk: 1.0.14
```

Then `flutter pub get`. The SDK does not write to SharedPreferences in a forward-incompatible way, so persisted state (VIP entries, consent settings, daily ad count) will degrade gracefully if you downgrade. The only loss is the consent-settings JSON record, which 1.0.14 does not read — your users will be re-prompted via your existing consent UI on the downgrade.

### Can I run 1.0.15 alongside an older version in a monorepo?

Yes, as long as each app pins its own version in `pubspec.yaml`. The SDK is a single Dart package; no native module conflicts.

### Why is `flutter analyze` failing right after I upgrade to a freshly-published version?

pub.dev takes up to 10 minutes to index a new release. Wait a few minutes and re-run.

---

## Need help?

- Open an issue on [GitHub](https://github.com/royt93/FlutterBase2025/issues) with the `roy93~` log output, your SDK version, and which provider (admob / appLovin)
- See `README.md` for the integration walkthrough
- See `doc/architecture.md` for the internals (state machine, lifecycle, safety gate)
