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
3. [What's new in 2.0.0](#whats-new-in-200)
4. [Quick start (copy-paste in 6 steps)](#quick-start)
5. [Configuration reference](#configuration-reference)
6. [VIP system](#vip-system)
7. [Server-Side Verification (SSV) for rewarded ads](#server-side-verification-ssv-for-rewarded-ads)
8. [Monetization Arbitrator (opt-in)](#monetization-arbitrator-opt-in)
9. [Fill-rate monitor (opt-in)](#fill-rate-monitor-opt-in)
10. [Native Ad (v1)](#native-ad-v1)
11. [Consent & compliance (GDPR / COPPA / CCPA)](#consent--compliance)
12. [Debugging](#debugging)
13. [Pitfalls — read before filing a bug](#pitfalls)
14. [Public API surface](#public-api)
15. [FAQ](#faq)
16. [Migration from older versions](#migration)
17. [Support](#support)
18. [License](#license)

---

## Why this SDK

| You want | The SDK gives you |
|---|---|
| Switch between AdMob and AppLovin without rewriting code | One `AdConfig.provider` flag |
| First-session ad-free experience for new installs (boost D1 retention) | `firstInstallVipGrace` — auto-grants VIP for 24 hours on first install |
| GDPR-compliant consent for EEA/UK/Switzerland users | Google UMP, wired by default (`autoRequestUmpConsent: true`) — `AdManager().requestUmpConsent()` wraps `google_mobile_ads`'s built-in `ConsentInformation` API, a certified CMP |
| Anti-fraud protection so AdMob doesn't suspend your account | Multi-layer safety gate: per-session/hour/day caps, throttle, CTR threshold, click-spam detection, progressive cooldown |
| Banner that pauses on navigation and resumes on return | `buildBanner()` — hooks into the navigator and adapter lifecycle automatically |
| Fixed 300×250 MREC ad with the same route-aware lifecycle | `buildMrec()` — same navigator/adapter hooks as `buildBanner()`, fixed size instead of adaptive |
| Native ad that blends into your own UI | `buildNative()` — v1 fixed layout (see [Native Ad (v1)](#native-ad-v1)) |
| Revenue tracking for LTV analytics | `Stream<AdEvent>` emits `AdRevenueEvent` per impression |
| Sane behavior when Android kills the process under memory pressure | Smart App-Open timeout (lifecycle-aware), process-restart marker, detached state warning |

---

## Known limitations — read before adopting

This SDK has extensive automated coverage (500+ unit/widget tests, plus a
cross-platform integration_test matrix on Android + iOS × both providers),
and several real bugs have been found and fixed through that process. That
is not the same claim as "battle-tested in production by third parties" —
be clear-eyed about the gap before depending on it for revenue:

- **VIP anti-bypass is durable on iOS, weak on Android.** The one-time-use
  ledger for redeemed keys and the first-install trial guard are backed by the
  iOS Keychain, which survives an uninstall by design. Android has no
  equivalent that works without a backend: both fall back to
  `SharedPreferences`, so **clearing the app's data resets the 1-day trial and
  lets an already-redeemed key be used again on that device**. Android Auto
  Backup (`dataExtractionRules`) covers a Play Store reinstall, not "Clear
  data", and only when backup is enabled and the same Google account is used.
  Decide with that in mind before handing out keys at scale — and prefer AVP2
  keys with a short `--valid-days`, since a key that has expired cannot be
  reused no matter how the device is wiped. **This is a real, unfixed
  limitation of the "no backend" design (round-37 audit), not a bug with a
  pending fix** — do not sell high-value/long-duration VIP tiers on this
  mechanism alone; pair it with Google Play Billing (or another
  server-verified purchase flow) for anything where an Android user
  repeatedly wiping app data to keep VIP for free is a real revenue risk you
  care about.
- **A leaked key is a leaked key — mitigated, not eliminated, by the
  revocation list (T95).** Signature verification is offline and sound — only
  the public key ships, so nobody can forge NEW keys by decompiling the app.
  AVP2 (default since 2.0.0) already narrows the blast radius by embedding an
  expiry and an app binding in the signed payload. On top of that,
  `VipManager.refreshRevocationList` lets you push a small signed list of
  revoked `kid`s (see [Revoking a leaked key](#revoking-a-leaked-key)) — but a
  key that's shared and redeemed *before* you notice and revoke it is still
  usable by whoever redeemed it first; the list only stops *further*
  redemptions of that `kid`, it does not claw back a grant already made.
- **AppLovin MAX has no ad-freshness concept — App Open (and other formats)
  can show a long-cached creative on that provider.** The `isAdFresh`
  4h/1h staleness check that AdMob's four fullscreen slots re-verify at
  *show* time (not just at load time) has no equivalent on AppLovin: the
  native MAX SDK exposes no load timestamp to check against. This is a
  platform gap, not a bug in this package — if `AdConfig.provider` is
  `AdProvider.appLovin`, a `ready` slot can be shown regardless of how long
  it has sat cached.
- **Ad-policy risk is not this SDK's to control.** It's a thin wrapper over
  AppLovin MAX and Google Mobile Ads. Fill rate, fraud detection accuracy,
  and account-level policy enforcement (suspensions, strikes) are decided by
  those platforms, not by this package. The built-in safety layer (daily/
  hourly caps, throttle, CTR-based fraud heuristics) reduces obviously bad
  behavior but has not been validated against a real policy review.
- **Ad placement is entirely on you (round-29 audit).** `buildBanner()`/
  `buildMrec()`/`showInterstitialAd()` hand back a widget or trigger a
  show — where you put it in your layout is 100% your call, and this SDK
  has no way to enforce Google's
  [ad placement policy](https://support.google.com/admob/answer/6128877):
  don't place a banner/interstitial adjacent to navigation buttons, close
  buttons, or other tappable controls, and don't show one on a screen the
  user is continuously interacting with (accidental clicks are treated as
  invalid traffic and can risk your AdMob account).
- **`BannerAdWidget`/`MrecAdWidget` auto-pause when scrolled off-screen or
  obscured (round-39 audit fix)**, via a `visibility_detector`-backed check —
  no wiring needed for that case. **`IndexedStack` bottom-nav tabs still need
  manual wiring**, and always will: switching the `index` of an
  `IndexedStack` triggers neither a `Route` push/pop nor a `TickerMode`
  change, and — this is the part that isn't just a missing signal —
  `IndexedStack` never even calls `paint()` on its non-current child, which
  is exactly what the automatic visibility check depends on to notice
  anything changed. A banner on an inactive `IndexedStack` tab that isn't
  wired up keeps loading/serving ads the user cannot see, which risks
  Google's
  ["don't refresh ads while hidden/off-screen"](https://support.google.com/admob/answer/6128877)
  rule. **Fix:** wrap each tab's content in `Visibility(maintainState: true)`
  instead of relying on `IndexedStack` alone (its `TickerMode` correctly
  follows visibility, and the automatic check above applies) — or, if you
  must keep a bare `IndexedStack`, pass `active: selectedIndex == myIndex`
  to `BannerAdWidget`/`MrecAdWidget` explicitly.
- **The real ad show/dismiss lifecycle is only partially automatable.**
  Real AppLovin MAX test-ad creatives expose no accessible dismiss element,
  so 3 of the ~15 integration_test scenarios (app-open/interstitial/rewarded
  dismiss) can only be verified manually, not via CI. Everything else in the
  lifecycle (load, show, click, reward callbacks, VIP suppression, safety
  gating) is automated and re-run on every change.
- **AppLovin consent writes cannot be confirmed as successful (round-33
  audit).** `AppLovinMAX.setHasUserConsent`/`setDoNotSell` (from the
  `applovin_max` package) are fire-and-forget `void` methods over a platform
  channel — they don't return a `Future`, so `applyConsentToProviders()`
  cannot `await` them or catch a failed platform-channel write the way it
  does for AdMob's `updateRequestConfiguration` (which is properly awaited,
  and only recorded as applied on success). In the rare case that write
  silently fails — a cold/backgrounded channel, a transient native
  exception — AppLovin can keep serving personalised ads to a user who just
  withdrew consent, and this SDK has no way to detect it; this is a
  dependency-level limitation, not something fixable purely on the Dart
  side. If your app operates in the EEA/UK/California with `AdProvider
  .appLovin` traffic, be aware of this before treating the AppLovin branch
  of `applyConsentToProviders()` as a hard guarantee. Full analysis:
  `doc/audit/audit_round33_consolidated.md`.
- **AdMob rewarded test ads can get permanently stuck on Android, unrelated
  to this SDK.** Manually verified 2026-08-08: an `AdMobAdapter`-shown
  rewarded ad occasionally shows a frozen countdown label and a static
  play-icon instead of a playing video — the video silently failed to start,
  so the close button (drawn entirely by the native Google Mobile Ads SDK)
  never renders, and neither the hardware back button nor any tap dismisses
  it. This reproduced with `google_mobile_ads 7.0.0` and matches known
  upstream reports
  ([googleads-mobile-flutter#633](https://github.com/googleads/googleads-mobile-flutter/issues/633),
  [#840](https://github.com/googleads/googleads-mobile-flutter/issues/840)):
  the app-side code only calls `show()` and waits for the native
  `onAdDismissedFullScreenContent` callback, which the native SDK never
  fires if the underlying video never actually played. Confirmed this is not
  reachable from Dart — there is no app-level close affordance to add. If you
  hit this, it should self-clear on the next ad load/session; there is no
  known reliable in-session recovery besides killing and relaunching the app.
  Android interstitial ads were not affected (dismissed cleanly via back
  button in the same test pass).
- ~~**Known limitation:** `app_open_ad_test.dart` / `interstitial_ad_test.dart`
  / `rewarded_ad_test.dart` call `showXAd()` twice back-to-back without
  waiting for the ad to finish loading first.~~ **Fixed (2026-07-19).** All
  three now poll the slot (`_waitForAppOpenLoaded` / `_waitForInterstitialLoaded`
  / `_waitForRewardedLoaded`) until `isReady` before tapping show, and fail
  loudly instead of silently passing on the safe "ad not ready, skip"
  fallback. Verified with a real run on a physical Android device against
  live AdMob test ad units — log-confirmed real show+dismiss (including an
  `earned=true` reward) for both cycles where the safety-throttle didn't
  suppress the second fullscreen show.
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

## What's new in 2.0.0

**Breaking.** Comes out of a full audit against seven production
requirements (`doc/audit/audit_claude.md`), cross-checked by
three independent agents, with every finding verified against source.

- **`autoRequestUmpConsent` now defaults to `true`** (was `false`). The old
  default meant a host that changed nothing could silently block ad
  requests in release builds — the built-in consent dialog never cleared
  the block because it applies consent directly to providers instead of
  routing through `google_mobile_ads`'s `setConsent()`. Net effect: zero
  ads requested, silently, since the diagnostic `assert` is stripped in
  release. Hosts that already call `requestUmpConsent()` themselves are
  auto-detected and the automatic call skips, so UMP still runs exactly
  once.
- **`maxVipStackDuration` now defaults to 90 days** instead of `null`
  (uncapped). Pass `null` explicitly for the old behaviour.
- **Signed VIP keys default to the new `AVP2` format**, which embeds expiry
  and app binding inside the signed payload. Existing `AVP1` keys still
  verify; `tool/vip_mint.dart` mints AVP2 unless `--v1` is passed.
- New dependency: `package_info_plus` (reads the bundle id for AVP2
  app-binding checks).

**Fixed:**

- **Interstitial and rewarded ads could stack on each other.**
  `showAppOpenAdOnResume` guarded against showing over a dialog, but
  `showInterstitial` and `showRewarded` each checked only their own slot —
  two full-screen ads could be requested back-to-back and briefly overlap.
  All three paths now share one state mutex.

See `CHANGELOG.md` `[2.0.0]` for the full list.

### What's new in 1.1.1 (historical)

- **1.1.1** — dependency freshness: `confetti` `^0.7.0` → `^0.8.0`,
  `connection_notifier` `^2.0.1` → `^4.1.0`. No public API changes.
- **1.1.0** — first **public** pub.dev release, plus: Native Ad format v1
  (`buildNative()`), MREC (`buildMrec()`), Smart Monetization Arbitrator +
  fill-rate monitor, mediation waterfall reporting, consent-country
  analytics, and a config-validation preflight check. See the dedicated
  sections below and `CHANGELOG.md` `[1.1.0]` for the full list.

### What's new in 1.0.23 (historical)

> **1.0.20** demoed the recommended `requestAtt() → requestUmpConsent() →
> initialize()` ordering in the example splash (no library change). **1.0.21**,
> **1.0.22** and **1.0.23** are the additions below. (Note: 1.0.21/1.0.22 are in
> the changelog but were never published to pub.dev — the public line jumped
> 1.0.20 → 1.0.23.)

Backwards-compatible with 1.0.1x. Recent additions:

- **App Open never draws over a banner or MREC (2.4.0)** — Google's App Open
  guidance says not to present an App Open ad on top of another ad, and names
  banner content explicitly. The resume path used to do exactly that: it
  restores banner visibility on resume, then shows the App Open over it. The
  SDK now blanks every inline surface for the duration of the App Open and
  restores the ones it blanked when the ad dismisses (a surface already hidden
  for another reason — backgrounded app, paused route — stays hidden). Nothing
  to call: this is automatic for both bundled adapters. A custom adapter that
  does not implement the internal `InlineAdVisibility` capability simply keeps
  the old behaviour.
- **App Open never stacks on a modal (1.0.23)** — `AdScreenRouteLogger` now
  counts `PopupRoute`s (dialogs, bottom sheets, Cupertino popups) and exposes
  `isDialogOnTop`; `showAppOpenAdOnResume` consults it plus
  `AdLoadingDialog.isShowing` and **skips the App Open ad while any dialog is
  presented** (e.g. a VIP redeem confirmation). The
  `_retryRefillAds` periodic scan also returns early for VIP members.
  - **Nested-Navigator gap (round-28 audit, 2.9.7):** `AdScreenRouteLogger`
    only sees routes pushed on the `Navigator` it's registered on. If your app
    has nested Navigators — bottom-nav tabs, a `go_router` `ShellRoute` branch
    — a bottom sheet opened with plain `showModalBottomSheet` (which defaults
    to `useRootNavigator: false`, unlike `showDialog`'s `true`) pushes onto the
    *nested* Navigator and goes untracked, so a resumed App Open ad can show on
    top of it. Fix: use the SDK's `showAdSafeModalBottomSheet` (same
    parameters, always `useRootNavigator: true`) instead of the raw Flutter
    API for any bottom sheet in a multi-Navigator app.
  - **Overlay-based popups are invisible to this guard too (round-32 audit)
    — opt-in fix added in T168:** `isDialogOnTop` only counts `PopupRoute`s
    pushed through a `Navigator`. A popup built by inserting an
    `OverlayEntry` directly (common in third-party loading/toast/coach-mark
    packages, and `SnackBar`, which goes through `ScaffoldMessenger` rather
    than a route) is not a `Route` at all and the SDK cannot poll every
    overlay in the tree automatically (the framework does not expose that
    safely). Call `markCustomOverlayOnScreen(true)` right before inserting
    your own overlay and `markCustomOverlayOnScreen(false)` right after
    removing it — the SDK cannot detect this on its own, but once declared
    it's folded into the exact same fullscreen mutex `isDialogOnTop` already
    feeds, blocking App Open on resume and every other fullscreen ad show.
    If you never call it, nothing changes from before — this is opt-in.
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

- **Cupertino consent dialog** (added 1.0.15, **removed in a later breaking
  release** — round 44 audit finding 1: it was not a Google-certified CMP
  and produced no valid TCF consent string, so a "yes" it collected was not
  a valid legal basis for personalized ads in the EEA/UK/Switzerland. Use
  Google UMP below instead, or another certified CMP.)
- **Google UMP wrapper** — `AdManager().requestUmpConsent(...)` calls into `google_mobile_ads`'s built-in UMP API (no extra dependency needed since `google_mobile_ads` 6.x, and still true at the `^7.0.0` this package pins today). Returns a structured `UmpConsentResult { canRequestAds, status, formShown, error }`.
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
  applovin_admob_sdk: ^X.Y.Z  # use the latest version from pub.dev

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

/// Global navigator key — required so the SDK can show loading buffers and
/// VIP UI from a context-less callback path (e.g., from the lifecycle
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

> ⚠️ **Nested Navigators (bottom-nav tabs, `go_router` `ShellRoute`):** add a
> fresh `AdScreenRouteLogger()` to every nested `Navigator`'s own
> `navigatorObservers` too — its dialog counter is a static/shared counter, so
> any instance anywhere feeds the same `isDialogOnTop`. And use
> `showAdSafeModalBottomSheet` (exported by this package) instead of the raw
> `showModalBottomSheet` for any bottom sheet, since the raw API defaults to
> `useRootNavigator: false` and would otherwise push onto an unobserved
> Navigator, letting a resumed App Open ad show on top of it.

### Step 5 — Initialize the SDK in `splash_screen.dart`

> **Shortcut:** `AdReadinessSplashController` (below) wraps everything in
> this section — the hard-cap timer, `markSplashActive`/`incrementSplashCount`
> bookkeeping, the buffered App Open ad — behind one `start()`/`onReady()`
> call, while still letting you render your own splash UI. Read this section
> once to understand what it's doing, then consider using the controller
> instead of copying the class below by hand.
>
> **Shortcut (T106):** `bootstrap(AdBootstrapOptions(config: ...))` wraps the
> `requestAtt() → requestUmpConsent() → initialize()` sequence below into one
> awaited call returning `AdBootstrapResult { att, ump, initSuccess, gaid }`.
> It composes with the splash controller above (or your own UI) — bootstrap
> only covers consent-then-init, not splash timing/App Open display.
>
> **`initTimeout` (round-32 audit fix, default 20s):** bounds how long
> `bootstrap()` waits specifically on `initialize()` before giving up and
> returning `initSuccess: false`. Without it, a wedged native init (never
> calls back) could leave a bare `await bootstrap(...)` frozen for the full
> ~130s worst-case retry pileup (`initialize()`'s own `[5s, 15s, 30s]`
> backoff across 4 attempts). This does not cancel the real init — it keeps
> running and still updates `AdManager`'s state — only this call stops
> waiting on it. Pass `AdBootstrapOptions(config: ..., initTimeout: null)`
> to restore the old unbounded wait.

```dart
final result = await bootstrap(AdBootstrapOptions(config: myAdConfig));
if (result.initSuccess) {
  // proceed — e.g. AdManager().showAppOpenAd(bypassSafety: true) or hand off
  // to AdReadinessSplashController for the hard-cap/App-Open dance.
}
```

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
  // Held in a field so dispose() can hand the SAME callback back to
  // SimpleEventBus().remove() — see initState()/dispose() below.
  void Function(BoolEvent)? _initListener;

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

    // Subscribe before calling initialize() (SimpleEventBus does replay its
    // last-fired event to a late subscriber, but this ordering is simplest
    // to reason about). Keep the callback in a field — the bus is a permanent
    // singleton and only ever forgets a listener you `remove()` yourself, so
    // an inline closure here leaks this State object (see dispose() below).
    _initListener = (BoolEvent e) {
      if (e.value) {
        _showSplashAppOpen();
      } else {
        _goHome();
      }
    };
    SimpleEventBus().listen(_initListener!);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // REQUIRED for iOS (ATT) and for the EEA/UK, Brazil, and every other
      // consent-regulated market (UMP). This is not optional polish: shipping
      // without it is an AdMob/AppLovin policy AND a GDPR problem. Order
      // matters — see "Compliance checklist" below and `example/lib/main.dart`.
      await AdManager().requestAtt();          // iOS only, no-op on Android
      await AdManager().initialize(
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

          // Optional: validate redeemed VIP keys against your server.
          // vipKeyValidator: (key) => myServer.verifyVipKey(key),
        ),
        onComplete: (success, gaid) {
          // Optional: log to your analytics here.
          debugPrint('SDK init complete: success=$success gaid=$gaid');
        },
      );
    });
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
    // SimpleEventBus is a process-lifetime singleton: a listener it is never
    // told to drop keeps this State (and its whole widget subtree) alive.
    final cb = _initListener;
    if (cb != null) SimpleEventBus().remove(cb);
    _initListener = null;
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

#### `AdReadinessSplashController` (T94) — the shortcut mentioned above

Everything the `_SplashScreenState` class above does by hand — subscribing
before `initialize()`, the hard-cap timer, `markSplashActive`/
`incrementSplashCount`/`markSplashInactive`, the re-entrant-splash guard, the
buffered App Open ad with `bypassSafety: true` — wrapped behind one
`start()`/`onReady` call. Your splash screen still renders 100% its own UI:

```dart
class _SplashScreenState extends State<SplashScreen> {
  final _controller = AdReadinessSplashController(config: myAdConfig);

  @override
  void initState() {
    super.initState();
    _controller.start(context, onReady: _goHome);
  }

  @override
  void dispose() {
    _controller.dispose(); // also clears the SDK's splash-active state
    super.dispose();
  }

  void _goHome() => Navigator.of(context)
      .pushReplacement(MaterialPageRoute(builder: (_) => const HomeScreen()));

  @override
  Widget build(BuildContext context) => const Scaffold(
        backgroundColor: Colors.deepPurple,
        body: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
}
```

Pass `showAppOpenOnReady: false` to skip the splash App Open ad and call
`onReady` as soon as init completes. This is a convenience wrapper, not a
replacement for the manual flow above — if your splash needs steps this
doesn't cover (custom ATT/consent timing before `initialize()`, ...), write
it by hand following the `_SplashScreenState` example instead.

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
            //
            // On a bare IndexedStack tab (all tabs stay mounted, only one
            // painted), pass active: selectedIndex == myIndex explicitly —
            // buildBanner()/buildMrec()/buildNative() all forward it to the
            // underlying widget the same as constructing it directly would.
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

You should see the splash screen, then a splash app-open ad (if available), then the home screen. If the device is in an EEA/UK/Switzerland test geography, Google UMP's own consent form appears during splash (see `requestUmpConsent`/UMP setup below) — skipped on subsequent launches once the user has answered. The default behaviour you get out-of-the-box:

- ✅ **First-install VIP grace 24h** — the user does not see ads during their first 24 hours after install. Tunable via `AdConfig.firstInstallVipGrace`.
- ✅ **Google UMP consent** wired by default (`autoRequestUmpConsent: true`) — a certified CMP, not a built-in dialog this SDK draws itself.
- ✅ **Splash app-open ad** with an 8-second hard cap so the user is never stuck.
- ✅ **Banner pause/resume** automatically when the user navigates between screens.
- ✅ **App Open ad auto-skips while a dialog/modal is on top** (1.0.23) — it never stacks over the UMP form, a VIP redeem confirmation, or any bottom sheet.
- ✅ **Anti-fraud** multi-layer safety gate protects your AdMob/AppLovin account.

### Imperative inline ad control (T201)

`BannerAdWidget`/`MrecAdWidget`/`NativeAdWidget` normally manage their own
lifecycle entirely on their own (route-aware pause/resume, scroll-visibility,
consent gating). For the rarer case where a host needs to imperatively
`refresh()`/`pause()`/`resume()` ONE specific slot — e.g. a "reload ad" button
next to a feed item, or pausing just the ad in a video player's overlay while
it plays — attach an `InlineAdController` instead of juggling your own
`active: bool` state variable and forcing a rebuild every time it changes:

```dart
final _bannerController = InlineAdController();

@override
void dispose() {
  _bannerController.dispose(); // idempotent — safe even if never attached
  super.dispose();
}

@override
Widget build(BuildContext context) => Column(
      children: [
        BannerAdWidget(controller: _bannerController),
        ElevatedButton(
          onPressed: _bannerController.refresh,
          child: const Text('Reload ad'),
        ),
        ElevatedButton(
          onPressed: _bannerController.pause,
          child: const Text('Pause'),
        ),
      ],
    );
```

- `refresh()` re-requests an ad for that one slot — through the exact same
  consent/VIP/connectivity/cooldown gate an automatic reload already goes
  through. A refresh requested during cooldown is silently skipped, never
  forced past the gate.
- `pause()`/`resume()` reuse the same path route-away/scroll-away already use
  for Banner/MREC; for Native (no auto-refresh ticker to merely suspend) they
  dispose and reload the instance.
- `controller.status` (`InlineAdControllerStatus.detached` / `.active` /
  `.paused`) reflects whether a widget is currently attached and paused —
  listen to it directly (`InlineAdController` is a `ChangeNotifier`) or wrap
  it in a `ListenableBuilder`.
- Pass either `active` or `controller`, never both on the same widget — the
  constructor asserts against it.
- A command issued before any widget has attached (or between a dispose and
  a later re-mount) is remembered, not lost — it applies once the next
  widget attaches.
- One controller drives at most one mounted widget at a time; attaching it
  to a second widget while still attached to another is a usage error
  (asserts in debug).

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
  bool autoRequestUmpConsent = true,
  bool umpTagForUnderAgeOfConsent = false,
  DebugGeography? umpDebugGeography,
  List<String> umpTestIdentifiers = const [],

  // AppLovin's own CMP flow is off by default because the SDK runs Google
  // UMP for both providers — set false only if you want MAX Terms Flow.
  bool disableAppLovinCmpFlow = true,

  // ─── App Open trigger ───────────────────────────────────────────
  AppOpenTrigger appOpenTrigger = AppOpenTrigger.both,

  // Wraps ad callbacks so a throw inside a host callback can't take the
  // app down. Leave on unless you are debugging a swallowed error.
  bool enableCrashGuard = true,

  // ─── Logging ────────────────────────────────────────────────────
  // Debug builds default to .verbose, RELEASE builds to .warning
  // (ad_config.dart: `kDebugMode ? AdLogLevel.verbose : AdLogLevel.warning`).
  AdLogLevel logLevel = AdLogLevel.verbose,
  List<String>? logTagFilter,
  AdLogSink? onLog,

  // ─── Safety / fraud protection ──────────────────────────────────
  AdSafetyParams safety = AdSafetyParams.auto,

  // ─── VIP ────────────────────────────────────────────────────────
  Future<bool> Function(String key)? vipKeyValidator,
  VipDialogStrings vipDialogStrings = const VipDialogStrings(),
  // Ceiling on the total window `addVip(stack: true)` can build up to.
  Duration maxVipStackDuration = const Duration(days: 90),
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

`umpDebugGeography` / `umpTestIdentifiers` are forwarded to Google UMP when `autoRequestUmpConsent: true` — set them the same way you would the equivalent params on `AdManager.requestUmpConsent()` (e.g. `umpDebugGeography: DebugGeography.debugGeographyEea` to simulate an EEA device from anywhere, `umpTestIdentifiers: ['<hashed-device-id>']` so Google serves the debug form for your test device).

`appOpenTrigger` (see `AppOpenTrigger` below) controls which App Open surfaces the SDK is allowed to trigger — default `both` preserves existing behavior.

### Release-build safety checks (config validation)

`initialize()` runs a set of pure, static "footgun" checks against your `AdConfig` whenever the app is built in **release mode** (skipped entirely in debug) and logs an `🚨`-prefixed warning for each one it finds:

- `AdSafetyParams.dryRun == true` — the entire safety layer (throttle/caps/CTR fraud) is bypassed.
- AdMob ad-unit IDs still pointing at Google's public test IDs (`ca-app-pub-3940256099942544/…`).
- `firstInstallVipGrace` disabled — new installs get no ad-free trial window.
- `umpDebugGeography` still set — forces every real user into the EEA/test UMP consent flow.
- `AppLovinConfig.sdkKey` empty while `provider: AdProvider.appLovin` — the native AppLovin MAX SDK fails to initialise.
- Empty/malformed ad-unit IDs for the active provider.

These checks are skipped entirely in debug builds (`kDebugMode == true`) — they only run once your build is compiled as profile/release — and each warning is logged via `SafeLogger.e` (so it shows up in whatever crash/log pipeline you've wired production builds into) plus an `assert()` as a redundant catch for anyone running a profile build with `--enable-asserts`. They never block `initialize()`, but each one is exactly the kind of copy-paste-from-a-test-config mistake that silently tanks revenue or earns a policy strike — watch your release logs for the `🚨` prefix after shipping.

### `AppOpenTrigger`

```dart
AppOpenTrigger.both        // splash App Open + resume App Open both fire (DEFAULT)
AppOpenTrigger.resumeOnly  // only the background→foreground resume App Open fires
AppOpenTrigger.splashOnly  // only the splash App Open fires
```

`resumeOnly` blocks the splash's `showAppOpenAd(bypassSafety: true)` call; `splashOnly` blocks `showAppOpenAdOnResume()`. `both` is a no-op on both gates.

`splashOnly` also stops `loadAppOpenAd()` from preloading once the splash has finished (tracked via `markSplashActive()`/`markSplashInactive()`) — since `showAppOpenAdOnResume()` always skips in this mode, any load after splash ends would never be shown, so it's skipped to avoid wasting quota/network. `resumeOnly` and `both` are unaffected — the same slot serves resume regardless of when it was preloaded.

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

### Per-placement daily caps

The caps above (daily/hourly/session) are global per ad type. To additionally
limit a specific `AdPlacement` — e.g. showing at most one interstitial from
your splash flow per day, on top of the global cap — set
`maxPerPlacementAdsPerDay`:

```dart
// Note: no `const` here — AdPlacement's custom `==` means a map keyed by it
// can't be a compile-time constant.
AdSafetyParams.production.copyWith(
  maxPerPlacementAdsPerDay: {AdPlacement.splash: 1},
)
```

This is checked in **addition** to the global cap, never instead of it — a
placement with no entry has no extra limit beyond the global one, and this
whole feature is opt-in (`null` by default, fully backward-compatible).

### Centralized placement behavior overrides (`PlacementRegistry`)

`AdConfig.placements` lets you configure per-`AdPlacement.id` behavior
overrides in one place, instead of scattering `if (placement == ...)`
branches across your app:

```dart
AdConfig(
  // ...
  placements: const PlacementRegistry({
    'level_complete': PlacementSpec(
      format: AdSlotType.interstitial,
      frequencyCapOverride: 3, // stricter than this placement's default cap
      minIntervalOverrideMs: 120000, // 2 min — looser than the app-wide throttle
    ),
  }),
)
```

`PlacementRegistry` deliberately does NOT store ad unit IDs — those stay on
`AdMobConfig`/`AppLovinConfig` as the single source of truth, avoiding a
second place that could drift out of sync. It only overrides optional
per-placement behavior knobs for that one placement:

- `frequencyCapOverride` — wins over `maxPerPlacementAdsPerDay`/
  `maxPerPlacementAdsPerDayById` above.
- `minIntervalOverrideMs` — wins over `AdSafetyParams.minTimeBetweenFullscreenAds`
  (the app-wide "minimum time between two fullscreen ads" throttle) for
  THIS placement's show calls. A smaller value loosens the throttle for
  this placement relative to the rest of the app; a larger value tightens
  it. Applies to every fullscreen format's real show call
  (`showInterstitial`/`showRewardedAd`/`showRewardedInterstitialAd`/
  `showAppOpenAd`) and to the matching `canShowInterstitial`/
  `canShowRewardedAd`/`canShowRewardedInterstitialAd` pre-check helpers
  when you pass the same `placement` to them.

`null` (the default, for either field) disables that override entirely —
every show call behaves exactly as it did before this feature existed.

### Remote-controlled `AdSafetyParams` (`RemoteAdSafetyProvider`)

Adjust caps/frequency from a backend (Firebase Remote Config, a self-hosted
config API, ...) without an app store release. Implement the interface with
whatever remote-config mechanism you already use — the SDK takes no
dependency on any specific one:

```dart
class MyRemoteSafetyProvider implements RemoteAdSafetyProvider {
  @override
  Future<Map<String, dynamic>?> fetchSafetyParamOverrides() async {
    final remote = FirebaseRemoteConfig.instance;
    await remote.fetchAndActivate();
    final json = remote.getString('ad_safety_params');
    return json.isEmpty ? null : jsonDecode(json) as Map<String, dynamic>;
  }
}

await AdManager().initialize(
  config: myConfig,
  onComplete: (success, gaid) { /* ... */ },
  remoteSafetyProvider: MyRemoteSafetyProvider(),
);
```

The provider gets a 5s window; a slow, throwing, or `null`-returning
provider falls back to `config.safety` unchanged — a remote-config outage
must never block SDK init. Each returned key is independently validated
(non-negative durations/counts, `suspiciousCtrThreshold` inside `[0, 1]`) —
an unknown key or a value that fails validation is silently skipped, not
fatal, keeping the local value for just that field.

### `AdLogLevel`

```dart
AdLogLevel.verbose   // everything (DEFAULT in DEBUG builds only)
AdLogLevel.warning   // warnings + errors only (DEFAULT in RELEASE builds)
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

> **Known limitation — redeem attempt requires connectivity.** The Ed25519
> signature check itself needs no network, but `redeemSignedKey` rejects the
> attempt outright while the device is offline (deliberate anti-abuse gate
> added in 2.0.1, see CHANGELOG). A user holding a valid code in airplane mode
> or with a weak signal cannot redeem until they reconnect — "offline" above
> describes the verification, not the redemption flow end to end.

> **Known limitation — Android reinstall / clear-data replay.** Per-device one-time-use is
> enforced by two layers: `AdPreferences` (`SharedPreferences`, wiped on
> uninstall) plus a durable secondary ledger (`RedeemedKeyLedger`) that on
> **iOS** survives uninstall via Keychain. On **Android there is no durable
> ledger** — `RedeemedKeyLedger.isRedeemed`/`markRedeemed` are no-ops there, by
> the same rationale as `FirstInstallGuard` (no local-only primitive survives
> uninstall without an install-referrer plugin, for a narrow benefit). So a
> leaked signed key **can be replayed an unlimited number of times on Android**
> via uninstall + reinstall — or, faster and without reinstalling anything, via
> Settings → Apps → Storage → **Clear data**, which wipes `SharedPreferences`
> and the Keystore-held material with it. The 1-day first-install trial
> (`firstInstallVipGrace`) can be re-granted the same way, once per clear.
> Each replay only grants the key's own encoded `duration`, not permanent VIP,
> but it is not capped in count. Treat signed keys like a coupon code that a
> screenshot can eventually leak, not like an unforgeable one-time ticket, on
> Android — and mint them with a short `--valid-days`, which is the one
> mitigation that a data wipe cannot undo. This is an accepted product
> tradeoff (no backend = no reliable cross-reinstall Android signal), not a
> bug: every store an app can write to on Android is inside the data a user is
> entitled to clear.

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

### Pre-built redeem screen (`VipRedeemScreen`)

Round-37 audit MAJOR (doc drift) — the raw `redeemSignedKey`/`redeemVip` calls
above are the low-level API. Don't hand-roll a redeem UI around them: the SDK
ships a complete, ready-to-use screen (status, redeem field, watch-ad-to-extend,
revoke, Do Not Sell toggle) that the example app itself uses as-is — "the
experience is identical everywhere" is the whole point of sharing it:

```dart
Navigator.push(
  context,
  MaterialPageRoute(
    builder: (_) => VipRedeemScreen(
      publicKeyBase64: kVipPublicKeyBase64, // your public key
      onPrivacyPolicyTap: () => launchYourPrivacyPolicyUrl(),
      onPrivacyOptionsTap: () => AdManager().showPrivacyOptions(),
    ),
  ),
);
```

Only `publicKeyBase64` is required. Everything else is optional: `strings:` for
localization (`VipRedeemStrings`), `onDoNotSellChanged`/`doNotSellValue` to wire
up the CCPA toggle, `rewardWatchAdDuration` for the watch-ad-to-extend grant
length. See `example/lib/main.dart`'s `VipDemoPage` for the full reference
usage, including the demo (never-ship) keypair.

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

### Moving a VIP grant to a new device

There is no dedicated "transfer" API, and deliberately so — the two features
already in this SDK cover the real need without a new signing scheme:

- **A signed key (`redeemSignedKey`) is scoped per device, not globally
  single-use.** The one-time-use ledger (`RedeemedKeyLedger` on iOS,
  `AdPreferences` on Android) only stops the *same device* redeeming the
  *same* key twice. If a user still has the original key string and it
  hasn't expired, entering it on a **new** device redeems it there too — no
  code change needed on your side. (A signed key's expiry is wall-clock,
  anchored to `expiresAt` in the payload — moving devices doesn't reset or
  extend it.)
- **The SDK never stores the raw key string after redemption** — only the
  parsed `keyId`/duration survive in `VipManager` state. If you want a "view
  my code again" screen so a user can copy it to a new device, that's on
  your app: keep a copy of the string the user typed (e.g. in your own local
  storage) when they first redeemed it. There is nothing here for the SDK to
  expose, by design — it shouldn't be holding onto a plaintext credential
  longer than the moment it verifies it.
- **User genuinely lost the key** (never saved it): revoke it in the CRL
  (`VipRevocationProvider`, see "Revoking a leaked key (CRL)" below) through
  your own support channel, then mint a fresh one with `tool/vip_mint.dart`
  and have the user redeem that on the new device. This already works
  today — it's a support-process question, not a missing feature.

A device-bound *transfer token* signed on-device was considered and
rejected: an on-device private key is generated fresh per install with no
shared root of trust between two installs, so a device could mint and
verify its own arbitrarily-long-lived token — that would weaken, not
preserve, the anti-abuse guarantee the signed-key scheme exists for.

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

### A/B testing AdMob vs AppLovin MAX (`pickProviderCohort`)

Provider is fixed for the whole session once `initialize()` runs — pick a
cohort BEFORE building `AdConfig`:

```dart
final provider = AdManager().pickProviderCohort(); // deterministic 50/50

await AdManager().initialize(
  config: AdConfig(
    provider: provider,
    admob: myAdMobConfig,       // both declared — only the picked one loads
    appLovin: myAppLovinConfig,
  ),
  onComplete: (success, gaid) { /* ... */ },
);
```

Comparing eCPM/fill-rate between the two cohorts needs no new plumbing —
every event on `AdManager().events` already carries `providerTag`
(`'[AdMob]'`/`'[AppLovin]'`), so your own analytics pipeline can group
`AdLoadEvent.success`/`AdRevenueEvent.valueMicros` by that field across your
install base. Built on `experimentBucket` below — same GAID/install-id
fallback guarantee.

### Session-alternate exploration for `WaterfallTuner`/`SelfHealingObserver` (`pickSessionProvider`)

`pickProviderCohort` above assigns a provider ONCE, at install — every
session of that install runs the same provider forever. `WaterfallTuner`
and `SelfHealingObserver` (below) can only ever compare the two providers
on a single device if SOME sessions genuinely run the alternate one —
`pickSessionProvider` is that mechanism:

```dart
final installProvider = AdManager().pickProviderCohort(); // stable per install
final sessionProvider = await AdManager().pickSessionProvider(
  installCohortProvider: installProvider,
  explorationRate: 0.05, // 5% of eligible sessions explore — keep this LOW
);

await AdManager().initialize(
  config: AdConfig(provider: sessionProvider, admob: ..., appLovin: ...),
  onComplete: (success, gaid) { /* ... */ },
);
```

**Read this before enabling:** an explored session is a REAL session on
the alternate provider — real ad requests, real fills, real revenue for
THAT session's users, not a shadow request. That is the actual cost of an
on-device A/B comparison: some sessions may perform worse than the
install's normal provider, on purpose, so the SDK can learn whether the
alternate would have done better overall. `explorationRate` defaults to 0
(never explores) — anything above 0 is an explicit tradeoff you are
opting into, and it should stay low (the 5% above is a starting point, not
a recommendation for every app). Exploration is also rate-limited to at
most once per day per device regardless of `explorationRate`, and never
counts against a VIP session (VIP suppresses every ad surface, so there
would be nothing to observe anyway).

### Cross-provider revenue integrity (`RevenueIntegrityLedger`)

**Exact match when available, time-window heuristic otherwise.** Both
`AdShowEvent` and `AdRevenueEvent` carry an optional `requestId` — a
per-load correlation ID both adapters stamp once and carry through for
that same ad instance. Whenever a revenue event's `requestId` matches a
pending show's, that show is resolved EXACTLY — no guessing. `requestId`
is `null` for banner/mrec/native (no matching `AdShowEvent` exists for
those to correlate against) and for any adapter version that predates
this, so the ORIGINAL heuristic below is unchanged and still runs
whenever `requestId` is missing on either side: `RevenueIntegrityLedger`
expects a same-`(providerTag, type, placement)` `AdRevenueEvent` within
`matchWindow` after every successful show; one with none is flagged via
`AdManager().incidentRecorder` as a **possible** gap — most often just a
revenue callback arriving later than `matchWindow`, not proof of fraud
or a lost impression.

```dart
final ledger = RevenueIntegrityLedger(matchWindow: const Duration(seconds: 60));
// ... later, read incidents the same way any other IncidentRecorder
// entry is read — see the "Debugging a decision" / dispute-kit sections
// above for the export path.
```

No new reporting mechanism: flags land in the same `IncidentRecorder`
`AdManager().exportDisputeKit()`/`exportSignedIncidentBundle()` already
export. Completely on-device — only consumes events the SDK already
emits, no third-party API calls.

**Known limitation — purely event-driven, no internal timer.**
`matchWindow` is only actually checked the next time ANY ad event
arrives (any type/provider/placement) — not on a schedule. A show with
no matching revenue callback, followed by total ad inactivity, sits
un-flagged in memory until the next event of any kind arrives (or until
the ledger is disposed, which silently drops it). In a normally-active
app this delay is negligible; it only matters for a session that goes
completely quiet right after the show in question.

### Zero-shadow dual-provider failover (`ProviderFailoverAdvisor`)

The SDK still serves exactly one provider per session by design (see
above) — a live concurrent dual-adapter runtime is a much bigger
architectural change this package does not make. `ProviderFailoverAdvisor`
covers a narrower, much cheaper win: recommend switching to the OTHER
provider for your app's NEXT `initialize()` call once the CURRENT one has
failed to load `consecutiveFailureThreshold` times in a row (any format,
no successful load in between — a genuinely intermittent failure pattern
never trips this). Unlike `WaterfallTuner.recommendation()`, this needs no
accumulated data for the provider it recommends switching TO — "zero
shadow requests".

```dart
final advisor = ProviderFailoverAdvisor(consecutiveFailureThreshold: 5);
AdManager().enableProviderFailoverAdvisor(advisor);

// ... later, building next session's config:
final provider = AdManager().applyProviderFailover(
  installProvider, // from pickProviderCohort()/pickSessionProvider()
  advisor: advisor,
);
await AdManager().initialize(
  config: AdConfig(provider: provider, admob: ..., appLovin: ...),
  onComplete: (success, gaid) { /* ... */ },
);
```

Persists by default (`persist: true`) — the whole point is surviving the
app restart between "this session failed repeatedly" and "the host reads
that before starting the next one". Never switches anything itself; it
only recommends, same as `WaterfallTuner`/`SelfHealingObserver`.

### A/B testing local knobs (`experimentBucket`)

Deterministic bucket assignment for A/B testing `AdSafetyParams`/arbitrator
thresholds without a remote-config backend (lighter than
`RemoteAdSafetyProvider` above — purely local, no network):

```dart
final bucket = AdManager().experimentBucket('daily_cap_experiment', buckets: 2);
final safety = bucket == 0
    ? AdSafetyParams.production
    : AdSafetyParams.production.copyWith(maxFullscreenAdsPerDay: 8);

await AdManager().initialize(config: myConfig.copyWith(safety: safety), ...);
```

Same result every call for the same `(key, buckets)` on this install —
prefers the real GAID when available, falls back to a lazily-generated
pseudonymous id persisted locally when GAID is empty/all-zeros (Limit Ad
Tracking / no ATT permission), so opted-out users still get distributed
across buckets instead of all colliding into bucket 0.

### Rewarded Interstitial (AdMob only)

Google's "Rewarded Interstitial" format — shown at a natural transition point
(between levels, after a task completes, ...) rather than behind an explicit
"watch ad" tap, while still granting a reward. Set
`AdMobConfig(rewardedInterstitialId: '...')` and use the matching
load/show/canShow trio:

> **Policy: this format requires an intro screen.** Google mandates that a
> rewarded interstitial is announced before it plays — the user must be told an
> ad is coming and what the reward is, and be given a way to decline. Serving it
> without one puts **your** AdMob account at risk, not the SDK's.
>
> `AdScreenState.showRewardedInterstitialAd()` renders that screen for you and
> is the recommended entry point. `AdManager().showRewardedInterstitialAd()` is
> the raw call and does **not** announce anything — if you use it directly, the
> intro screen is yours to build.

```dart
AdManager().loadRewardedInterstitialAd();

// From an AdScreenState — announces the ad, then plays it.
showRewardedInterstitialAd(
  // English fallbacks; pass your own localised strings.
  disclosureTitle: 'Xem quảng cáo để nhận thưởng',
  disclosureSubtitle: 'Một quảng cáo ngắn sẽ phát. Nhận thưởng sau khi xem xong.',
  disclosureButtonLabel: 'Xem',
  disclosureCancelLabel: 'Bỏ qua',
  onDone: (shown, earned) {
    if (earned) grantCoins(10);
  },
);

// Already rendering your own intro screen? Take the obligation on explicitly:
showRewardedInterstitialAd(
  showDisclosure: false,
  onDone: (shown, earned) { /* ... */ },
);

if (AdManager().canShowRewardedInterstitialAd()) { /* e.g. enable a CTA */ }
```

`shown` is `true` whenever the ad was **displayed**, whether or not the user
stayed to the reward point — it consumed a billed impression either way and
costs the same ad budget. Declining the intro screen reports `(false, false)`
and costs nothing.

**AppLovin MAX has no equivalent ad unit type** — on that provider this is a
documented no-op: `loadRewardedInterstitialAd()` never has anything to load,
and `showRewardedInterstitialAd()` always calls back `(false, false)`. Unlike
`showRewardedAd`, there's no VIP-bypass-to-extend-VIP flow and no SSV
params for this ad type — see `AdProviderAdapter.showRewardedInterstitial`'s
doc comment for why.

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

`AdScreenState.showRewardedAd()` (the documented `AdScreen` helper — see
[Step 6 — Show ads on any screen](#step-6--show-ads-on-any-screen)) forwards
`bypassVipGuard` and `onDemandLoadTimeout` the same way, so this flow works
identically whether you call `AdManager().showRewardedAd()` directly or
through that helper.

### Waiting for VIP to be ready

`AdManager().vip` is `null` until SDK init completes. If a screen can render
before that (e.g. it doesn't gate on the splash's init-completion event),
listen to `vipReady` instead of polling `vip != null` yourself:

```dart
ValueListenableBuilder<bool>(
  valueListenable: AdManager().vipReady,
  builder: (_, ready, __) {
    if (!ready) return const SizedBox.shrink();
    return ValueListenableBuilder<bool>(
      valueListenable: AdManager().vip!.activeListenable,
      builder: (_, active, __) =>
          active ? const VipBadge() : const SizedBox.shrink(),
    );
  },
)
```

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

### Revoking a leaked key (CRL) — T95

`redeemSignedKey`'s Ed25519 signature check is fully offline (see the
"deliberate anti-abuse gate" note above — the method still refuses to redeem
while the device itself is offline), which is great for forge-proofing, but it
means a leaked key normally stays redeemable forever (or until its AVP2
`--valid-days` expiry). `VipManager.refreshRevocationList` closes that gap
with a small,
**also offline-signed** revocation list (CRL) — no server, no new key
material, same private key that mints VIP keys mints the CRL too.

1. **Mint the CRL offline** whenever you learn a `kid` leaked (same private
   key as `tool/vip_mint.dart`, never commit it):
   ```bash
   dart run tool/vip_crl_mint.dart --priv <b64privkey> --kids leaked-kid-1,leaked-kid-2
   # → CRL1.<payload>.<signature>
   ```
2. **Host the raw output** anywhere you like (a static JSON/text endpoint,
   Firebase Remote Config, ...) — implement `VipRevocationProvider` to fetch
   it:
   ```dart
   class MyCrlProvider implements VipRevocationProvider {
     @override
     Future<String?> fetchSignedCrl() async {
       final resp = await http.get(Uri.parse('https://example.com/vip_crl.txt'));
       return resp.statusCode == 200 ? resp.body.trim() : null;
     }
   }
   ```
3. **Refresh periodically** (once/day is plenty — this is a slow-moving
   blocklist, not a live check):
   ```dart
   Timer.periodic(const Duration(hours: 24), (_) {
     AdManager().vip?.refreshRevocationList(
       publicKeyBase64: myVipPublicKey, // same key(s) passed to redeemSignedKey
       revocationProvider: MyCrlProvider(),
     );
   });
   ```

Verified CRLs are cached to disk (re-verified against the public key on every
read, never trusted un-signed) so a revoked `kid` stays blocked across app
restarts without a fresh fetch. **Fails open on every error** — no provider,
fetch throws, fetch returns `null`, bad signature, or a replayed/older CRL
(anti-rollback: an older signed CRL can never undo a newer revocation already
applied) — a network hiccup must never block a legitimate redemption. This
only stops *future* redemptions of a revoked `kid`; a device that already
redeemed it before the CRL update keeps its granted VIP window (see the
[Known limitations](#known-limitations--read-before-adopting) note above).

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

## Monetization Arbitrator (opt-in)

**Default OFF, production-safe.** Unlike the debug-only `RevenuePanel`
overlay (gated on `kDebugMode`), the arbitrator has no debug/release
distinction at all — it stays off purely because `enableArbitrator` was never
called, and once called it runs identically in a release build. There is no
separate "enable in production" step. An opt-in "Smart Monetization
Arbitrator" that, at each
fullscreen ad-show attempt (after every existing gate — including the safety
layer — already passes), gets one more veto: show the ad, or nudge the host
app to upsell VIP instead. It is a simple configurable eCPM-threshold rule,
**not machine learning**: it compares a trailing eCPM estimate (built from the
`AdRevenueEvent`s the SDK already emits) against an optional VIP-conversion-
likelihood signal your app supplies — the SDK has no visibility into your
purchase funnel, so it can't compute that signal itself.

```dart
AdManager().enableArbitrator(MonetizationArbitrator()); // ~$5 eCPM default threshold

// Optional: tell the arbitrator how likely this user is to buy VIP (0.0–1.0).
// Without this, it falls back to a plain "trailing eCPM below threshold" check.
AdManager().arbitrator!.registerVipLikelihoodEstimator(() => myFunnelScore());
```

Interstitial and rewarded can use different eCPM thresholds via
`perSlotThresholdMicros` — a rewarded ad is worth more to most users than an
interstitial, so it's reasonable to require a higher trailing eCPM before
showing one:

```dart
AdManager().enableArbitrator(MonetizationArbitrator(
  ecpmThresholdMicros: 3000000, // fallback for any slot not listed below
  perSlotThresholdMicros: {
    AdSlotType.rewarded: 5000000, // rewarded needs a higher bar to show
  },
));
```

A `maxVetoRate` guardrail (default `0.5`) protects against a threshold set too
high (or a genuine eCPM crash) starving users of ads indefinitely: once the
veto rate over the trailing `decisionWindowSize` decisions (default `20`)
exceeds `maxVetoRate`, the arbitrator forces `showAd` regardless of the
eCPM/likelihood heuristic, and recovers automatically once the veto rate drops
back down. A single warning logs the first time this trips per streak.

`showInterstitial`/`showRewardedAd`/`showRewardedInterstitialAd` (T89's
AdMob-only slot) only consult `arbitrator` when it's non-null — byte-for-byte
no-op until `enableArbitrator` is called. When the arbitrator vetoes a show,
the SDK emits an `ArbitratorNudgeEvent` (`type`, `placement`,
`estimatedEcpmMicros`) on `AdManager().events` instead of showing the ad, so
the host app can react with its own VIP upsell UI — the SDK never draws this
UI itself, purely a signal (T99). The veto is skipped for the VIP
watch-ad-to-extend-VIP bypass path (`bypassVipGuard: true`) — that flow is
the user already spending their own time to earn more VIP, so vetoing it
would defeat its purpose.

There is no `disableArbitrator` for host apps — it exists only as a
`@visibleForTesting` seam, since a session normally either wants the
arbitrator on for its whole lifetime or not at all.

### Debugging a decision (`decideWithContext`)

`decide()` (used internally by the SDK) only ever returns the
`ArbitratorDecision` enum — `showAd` or `nudgeVip`, with no explanation. If
you want to log or debug WHY a slot keeps getting vetoed (which threshold it
was compared against, what the trailing eCPM actually was, whether the
`maxVetoRate` guardrail forced the outcome), call `decideWithContext`
instead — it runs the exact same logic as `decide()` (same result, same
internal bookkeeping) and additionally returns an `ArbitratorDecisionDetail`:

```dart
final detail = AdManager().arbitrator!.decideWithContext(AdSlotType.interstitial);
myLogger.log(
  'arbitrator: ${detail.decision} — ${detail.reason} '
  '(trailing eCPM ${detail.trailingEcpmMicros}µ vs threshold ${detail.thresholdMicros}µ, '
  'guardrail: ${detail.guardrailTripped})',
);
```

Call either `decide()` or `decideWithContext()` per real decision point, not
both for the same one — each call advances the arbitrator's internal
decision history (used by the `maxVetoRate` guardrail above), the same way
`decide()` alone always has.

## Fill-rate monitor (opt-in)

**Default OFF, production-safe** — same as the arbitrator above: no
`kDebugMode` gating, it's off only until `enableFillRateMonitor` is called,
and then it runs the same way in debug and release. A `FillRateMonitor`
watches the trailing load success rate
per `AdSlotType` for whichever provider is currently active, and alerts when
it drops abnormally low — useful for catching a mediation/network outage or a
misconfigured ad unit without waiting on a dashboard. It does **not** load a
second provider in parallel to compare against ("shadow eCPM"): that would add
real ad requests (extra policy risk, wasted quota) just to produce a number.
Instead it only observes the `AdLoadEvent`s the SDK already emits.

```dart
final monitor = FillRateMonitor(); // 30% threshold, 20-event rolling window
AdManager().enableFillRateMonitor(monitor);

monitor.alerts.listen((alert) {
  // alert.type, alert.fillRate, alert.threshold
});

// Read the current rate for a slot at any time:
monitor.fillRate(AdSlotType.interstitial);
```

An alert fires once the first time a slot's trailing fill rate drops below
`lowFillRateThreshold` within a full rolling window, then stays silent while
the drop persists — it fires again only after the rate recovers above
threshold and later drops a second time, so it never spams one continuous
outage.

There is no `disableFillRateMonitor` for host apps — same reasoning as the
arbitrator above, it's a `@visibleForTesting` seam only.

### 7-day fill-rate/eCPM baseline regression detector (T97)

`FillRateMonitor` above only ever looks at the current session (a trailing
rolling window). `FillRateBaselineMonitor` answers a different question:
**"is THIS session unusually bad compared to what this exact device normally
sees?"** — entirely on-device, no backend, no shadow ad requests, consistent
with the SDK's offline-first design elsewhere (VIP Ed25519 signing, the
client-side safety layer).

```dart
await AdManager().enableFillRateBaselineMonitor(
  regressionThreshold: 0.2, // session metric 20%+ worse than baseline → alert
  minSamples: 5,            // need at least 5 samples on BOTH sides to compare
);

AdManager().fillRateBaselineMonitor?.alerts.listen((alert) {
  // alert.type, alert.sessionFillRate, alert.baselineFillRate,
  // alert.sessionAvgRevenueMicros, alert.baselineAvgRevenueMicros,
  // alert.fillRateRegressed, alert.revenueRegressed
});

// One-shot snapshot (what the debug overlay renders):
AdManager().fillRateBaselineMonitor?.activeAlerts;
```

It persists a rolling 7-calendar-day history per `AdSlotType` (attempts,
successes, and average revenue-per-ad from `AdRevenueEvent.valueMicros`)
locally via `AdPreferences`, and compares it against THIS session's tally so
far — excluding today's own in-progress day from the baseline, so a session
never gets (dis)compared against itself. Needs `minSamples` on both sides
before it trusts a comparison, and — like `FillRateMonitor` — fires once per
slot on a new regression, then stays quiet while it persists. Already wired
into `AdManager.diagnostics()` (`fillRateRegressionBySlot`) and the built-in
`DebugAdOverlay`, so enabling it is the only integration step needed to see
it in the panel.

## Other advanced opt-in modules (brief)

The two above (arbitrator, fill-rate monitor) aren't the only opt-in
modules this SDK ships — these are lower-profile, advanced, or niche
enough that they don't need a full section, but are real public API a host
app can reach for:

- **`AdSafetyConfig`** — the anti-fraud engine itself (throttle,
  session/hourly/daily caps, CTR monitoring, progressive cooldown). Query
  live state any time via `AdSafetyConfig.getStatus()` (string) or
  `.getStatusSnapshot()` (structured `AdSafetySnapshot`) — see
  `RemoteSafetyDemoPage` in the example app for a working usage.
- **`AdRetryPolicy`** — per-slot retry/backoff tuning that distinguishes
  no-fill from network/invalid-request/timeout failures, since a
  misconfigured ad unit will never self-resolve by retrying while a
  network blip often should retry sooner than the default backoff window.
- **`BypassAuditTrail`** — always-on audit log proving every
  `bypassSafety`/`bypassVipGuard` call only ever fired at this SDK's own
  documented call sites (splash App Open, VIP watch-to-extend), not
  somewhere patched in to farm impressions.
- **`IncidentRecorder`** — a short rolling window of recent top-level
  state transitions, for diagnosing "why didn't this ad show" races that a
  single point-in-time diagnostics snapshot can't explain by itself.
- **`MonetizationDigitalTwin`** — deterministic, read-only replay over
  `AdEventLog` history for analytics; never issues an ad request or
  touches `AdSafetyConfig`'s live state.
- **`JourneyPrefetcher`** — opt-in, engagement-signal-driven prefetching
  via `AdManager().enableJourneyPrefetcher(...)`; nothing is tracked or
  preloaded unless the host app calls `notifySignal`, or opts into
  `autoRouteSignalType` (below) so a route push does it automatically.
  T183 — its rolling time-to-show averages persist across app restarts by
  default (`persist: true`), so it doesn't re-learn timing from zero every
  cold start; this only ever stores durations between a signal string and
  an ad type locally on-device, never the signal's own content. Pass
  `persist: false` to opt out entirely, or `await prefetcher.ready` if a
  caller needs last session's data guaranteed loaded before its first
  `notifySignal`/`averageTimeToShow` call (neither waits for it on its
  own — same as every other on-device signal in this SDK).

  ```dart
  final prefetcher = JourneyPrefetcher(
    autoRouteSignalType: AdSlotType.interstitial, // opt-in, T139
  );
  AdManager().enableJourneyPrefetcher(prefetcher);
  // ...
  MaterialApp(
    navigatorObservers: [
      adRouteObserver,
      AdScreenRouteLogger(),
      prefetcher.routeObserver!, // only non-null when autoRouteSignalType is set
    ],
  );
  ```

  This fires `notifySignal(routeName, autoRouteSignalType)` for every
  NAMED route push, using `ModalRoute.settings.name` as the signal — a
  convenience for apps whose route names are already meaningful as
  journey signals (e.g. `'level_complete'`). An unnamed route is silently
  skipped. Only ONE format is auto-signaled per `JourneyPrefetcher`
  instance — a route push alone doesn't say which ad format it precedes,
  so a journey involving more than one fullscreen format should keep
  calling `notifySignal` by hand for the others. Manual calls and
  auto-mode are not mutually exclusive and are never deduplicated against
  each other — firing the same signal twice (once auto, once manual) is
  accepted as two independent signals by design.
- **`WaterfallTuner`** — per-provider eCPM score tracking meant for
  *cross-install* mediation experiments (e.g. deciding a new install's
  `AdConfig.provider` from server-side analytics) — not a within-install
  auto-switcher.
- **`TopToast`** — the small built-in toast this SDK uses internally for
  "ad not ready" messaging (`TopToast.show(context, icon: ..., message:
  ...)`), reusable directly by a host app that wants the same look.

`SelfHealingObserver` is intentionally omitted above — its own doc comment
notes it stays dormant on any single real install by design; treat it as
experimental/advanced rather than something to wire up by default.

## Diagnostics & integration self-check

`AdManager.diagnostics()` is a one-shot, read-only snapshot that combines the
3 monetization signals above — mediation waterfall, fill rate, arbitrator
stats — into a single `AdDiagnostics` object, so a partner can answer "why is
eCPM low today" without cross-referencing 3 separate pages/subsystems:

```dart
final diag = AdManager().diagnostics();
diag.lastWaterfallBySlot;        // most recent mediation waterfall per AdSlotType
diag.fillRateBySlot;             // FillRateMonitor.fillRate per slot (empty map if monitor disabled)
diag.arbitratorEstimatedEcpmMicros; // null if arbitrator disabled
diag.arbitratorVetoRate;             // null if arbitrator disabled
diag.toJson();                       // hand to a partner/reviewer
```

`AdManager.runIntegrationSelfCheck()` is a **debug-only** "integration
doctor" checklist (init → consent → per-ad-type load → VIP wiring →
navigator key → route observer → ATT plugin) so a partner integrating the SDK
doesn't have to manually click through every demo page to confirm their
`AdConfig` and app-level wiring both work on their device. It's a no-op
returning a single `skipped` item outside debug builds, and deliberately
never calls `destroy()` or grants/revokes VIP — those mutate live
session/entitlement state, which would be a destructive side effect of
what's meant to be a mostly-read-only sanity check (the per-ad-type load
checks are the one exception — they DO attempt real ad loads, same as
clicking through the demo pages would).

```dart
final result = await AdManager().runIntegrationSelfCheck(
  loadTimeout: const Duration(seconds: 15), // per-slot load timeout
);
result.allPassed;   // true if no item has SelfCheckStatus.fail
result.items;        // List<SelfCheckItem>(name, status, detail)
```

Checks added in T98 (all read-only, never trigger a real ad load or an ATT
prompt):

- **Navigator key wired** — fails if `setNavigatorKey` was never called;
  `skipped` (not `fail`) if it's set but not yet attached to a live
  `Navigator` (e.g. the check ran before the first frame).
- **Route observer wired** — `AdScreenRouteLogger` only ever receives
  `didPush`/`didPop`/etc. callbacks if it's really in `navigatorObservers`, so
  a non-zero navigation-event count is real evidence of correct wiring.
  `skipped` (not `fail`) if no route has pushed yet.
- **ATT status readable (iOS)** — confirms the `app_tracking_transparency`
  native plugin responds at all (catches a broken iOS embed early).
  Deliberately never calls `requestTrackingAuthorization()` — that shows the
  real system prompt, which a passive diagnostic must never trigger.
  `skipped` on non-iOS.

**Deliberately out of scope for this pass** (a genuinely different, much
larger engineering effort — flagged here rather than silently claimed done):
SKAdNetwork/`Info.plist` entries, Android manifest permissions/meta-data, and
cross-referencing the CocoaPods dependency graph against the pinning-wall
constraints (see "Publishing to pub.dev" in `CLAUDE.md` / `tool/
check_pinning_wall.sh`). None of these are readable from plain Dart at
runtime — they'd need new native (Swift/Kotlin) platform-channel code to
read the bundled `Info.plist`/`AndroidManifest.xml`, and the pod graph is a
*build-time* concept with no runtime representation at all. `doctor` only
ever reports on state this package can already see from Dart.

The results are rendered directly in the built-in `DebugAdOverlay` — tap "🩺
Run integration doctor" in the panel (not auto-run on open, since the
per-ad-type checks attempt real loads). See also the example app's
"Diagnostics & self-check" demo page for both APIs wired to a live UI.

## Native Ad (v1)

`buildNative()` (or `NativeAdWidget` directly, outside `AdScreen`) renders a native ad —
same route-aware/VIP/offline gating as `buildMrec()`, but **the two providers render
through fundamentally different mechanisms** because AdMob's and AppLovin's native APIs
don't share a common Dart-side shape:

- **AdMob**: `NativeAd extends AdWithView`, same base class as `BannerAd`/MREC. It's
  preloaded off-screen with `NativeTemplateStyle(templateType: TemplateType.medium)` —
  Google's built-in template — then shown via `AdWidget`. The template **draws its own
  "Ad"/AdChoices attribution**; the package adds nothing on top of it.
- **AppLovin**: `MaxNativeAdView` is a self-contained widget that loads on mount from
  `adUnitId` + a custom Dart layout (`MaxNativeAdIconView`/`MaxNativeAdTitleView`/
  `MaxNativeAdMediaView`/`MaxNativeAdBodyView`/`MaxNativeAdCallToActionView`, etc.) — it
  does **not** go through the `preloadWidgetAdView` bridge banner/MREC use. Because the
  layout is genuine custom Dart, the package **draws its own "Ad" badge** on this branch
  (mirrors the MREC badge) to stay compliant.

**v1 is a fixed layout, not a customizable editor** — both branches render at a fixed
320px height (Google's recommended size for `TemplateType.medium`), and the AppLovin
branch's asset arrangement (icon + title + rating row, media, body, CTA) is not
configurable from host code. If you need a different arrangement, pull the raw ad
object yourself (`AdManager().adapter?.buildAdmobNativeView(key)` — `key` is any stable
object identifying this ad slot, so the same native view survives a rebuild — for AdMob template
swaps, or build your own `MaxNativeAdView` for AppLovin) instead of `buildNative()`.

There is also no route-pause/auto-refresh concept for native ads (unlike banner/MREC) —
`buildNative()` loads once per mount and doesn't react to navigation.

## Built-in QA test devices (read this before measuring revenue)

This package **always** merges a fixed list of AdMob test-device hashes into
`RequestConfiguration.testDeviceIds`, in release builds too. They are the
maintainers' own QA handsets (`kQaTestDeviceHashes` in
`lib/src/config/ad_config.dart` — the list is public, on pub.dev, and readable
by anyone).

Why it exists: manual QA runs on real hardware against release builds, and a
tester's tap must never be counted as a real click. Getting rate-limited for
invalid activity is far more expensive than a handful of devices that serve
test ads.

What it costs you: if one of those devices ever ends up in the hands of a real
user of **your** app, that user will only ever see test ads and will never
generate revenue. There is currently no opt-out. If that trade-off does not
work for you, fork the package and empty `kQaTestDeviceHashes`.

## Consent & compliance

The SDK supports two patterns for GDPR/personalization consent, plus a
separate CCPA toggle. Pick whichever matches your release strategy.

**There is no built-in consent dialog** — a prior version shipped one (a
plain Allow/Reject sheet), but it was not a Google-certified CMP and
produced no valid IAB TCF consent string, so a "yes" it collected was not a
valid legal basis for personalized ads in the EEA/UK/Switzerland. It was
removed (round 44 audit finding 1). Use Google UMP below, or another
certified CMP wired through `ConsentManager.set`/`setConsent`.

**CCPA "Do Not Sell" toggle**: legally required to be an end-user choice
(Cal. Civ. Code §1798.135) — `CcpaOptOutToggle` (a `SwitchListTile` wired to
`AdManager().doNotSell` / `setDoNotSell(bool)`) is a ready-made widget for
it. Drop it into a Settings/Privacy screen for a California-facing app:

```dart
// After AdManager().initialize() has completed — e.g. your app's Settings
// or Privacy screen:
const CcpaOptOutToggle()
// Or with localised copy:
const CcpaOptOutToggle(strings: CcpaOptOutStrings.vi)
```

`CcpaOptOutStrings`, `VipDialogStrings` (`AdConfig.vipDialogStrings`, the
small redeem-confirmation dialog), and `VipRedeemStrings`
(`VipRedeemScreen.strings`, the full redeem screen — buttons, labels, and
snackbar messages) all follow the same pattern — `.en`, `.vi`, and
`.resolve([locale])`:

```dart
VipRedeemScreen(
  publicKeyBase64: yourPublicKey,
  strings: VipRedeemStrings.resolve(Localizations.localeOf(context)),
)
```

These three are every widget/dialog this SDK shows a real end user. `DebugAdOverlay`
and `RevenuePanel` are the only other SDK widgets that render text at all,
and both are `kDebugMode`-gated (render nothing, subscribe to nothing, in a
release build) — a developer debugging the SDK, not an end user, so they
stay English-only on purpose, the same way Flutter's own DevTools do.

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

### Option 1 — Google UMP form (default, required for EEA/UK/Switzerland users)

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

Alternatively, set `AdConfig(autoRequestUmpConsent: true, umpDebugGeography: ..., umpTestIdentifiers: [...])` to let `AdManager().initialize()` run this flow for you before the first ad request — `umpDebugGeography`/`umpTestIdentifiers` are forwarded through to the same UMP call shown above.

The raw IAB TCF v2.3 consent string Google UMP writes to native storage after a user completes the EEA form is available via `await AdManager().tcfConsentString` (`null` until a TCF session has run) — read-only, for forwarding to any third party (analytics, mediation outside AppLovin/AdMob) that needs the raw string.

**F7 — why this SDK doesn't also forward the TC-string to AppLovin**: [Q18/setConsent](#option-2--google-ump-form-required-for-eea-users-on-admob) only syncs the boolean `hasUserConsent` flag to `AppLovinMAX.setHasUserConsent`, not the raw TC-string — and that's intentional, not a gap. AppLovin MAX SDK 12.0.0+ (this project pins native `13.2.0.1` / Flutter `applovin_max: ^4.6.4`, both well above that threshold) already auto-reads `IABTCF_TCString`, `IABTCF_gdprApplies`, and `IABTCF_AddtlConsent` directly from the platform's shared storage per the IAB standard, the moment UMP writes them — no app code has to relay it. `AdManager().tcfConsentString` above exists only as a manual escape hatch for a *third* party outside AppLovin/AdMob that also needs the raw string.

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

### Option 2 — Manual flag set (you have your own UI or CMP)

If you already integrate a third-party CMP and just want the SDK to forward the flags to the providers:

```dart
await AdManager().setConsent(AdConsent(
  hasUserConsent: true,        // GDPR consent
  isAgeRestrictedUser: false,  // COPPA: app targets children < 13
  doNotSell: false,            // CCPA: California user opts out of data sale
));
```

### CCPA / US state privacy — what the SDK applies on its own

If any CMP on the device has written the IAB **US Privacy** string
(`IABUSPrivacy_String` — Google UMP writes it, so do most third-party CMPs),
the SDK reads it and applies a sale opt-out to **both** providers by itself:
AppLovin `setDoNotSell(true)` and AdMob `restricted_data_processing` on every
request. It reconciles at SDK init and on every app resume, so an opt-out the
user makes in a CMP while your app is backgrounded lands without your code
noticing anything.

`AdManager().usPrivacyOptedOut` reports the same signal if you want to show it.

Two deliberate limits:

- **Tighten-only.** A string that says the user did *not* opt out — and the
  absence of any string, which is the normal case outside the US — never
  clears a `doNotSell` you set yourself through `setConsent`. Your own switch
  is treated as the newer, deliberate decision.
- **The GPP string is only partially decoded.** `IABGPP_HDR_GppString` (the
  multi-state signal covering Virginia, Colorado, Texas and the rest) is
  exposed raw via `AdManager().gppConsentString` for your own use. As a
  fallback when no legacy `IABUSPrivacy_String` exists, `usPrivacyOptedOut`
  also decodes the GPP **US National** section's `SaleOptOut`/`SharingOptOut`
  fields only — it does **not** read that section's separate
  `TargetedAdvertisingOptOut` field, and it does **not** decode any
  state-specific section (California, Colorado, Virginia, Connecticut, ...).
  Mis-parsing a privacy signal is worse than not reading one, so the scope
  stays narrow and exact; both native SDKs also read the raw string
  themselves. If you need targeted-advertising opt-out or per-state handling
  beyond sale/sharing opt-out, decode the rest of the string yourself and
  call `setConsent`.

### Consent country analytics (optional, host-supplied)

`ConsentSettings.country` is an optional `String?` field (e.g. `'DE'`, `'US'`)
you can attach for consent analytics — it flows through to
`AdEventLog`/`ComplianceReport` as `consentCountry` on every logged event, and
`ComplianceReport.consentCountByCountry` aggregates a count per country.

**This is not real geolocation.** The SDK has no way to determine a user's
actual country — Google UMP only exposes an EEA/non-EEA classification (plus
a debug-only override via `AdConfig.umpDebugGeography`), and AppLovin exposes
nothing at all. If you want this field populated, supply it yourself from
whatever source you already trust (e.g. `Platform.localeName`, your own
GeoIP service, or the billing address on file):

```dart
await ConsentManager.instance.set(
  ConsentManager.instance.current.copyWith(country: 'DE'),
);
```

Left `null` (the default) if you never set it — it's simply omitted from the
aggregate, no crash, no placeholder value.

### Cryptographically-signed compliance report export (T96)

`AdManager().exportComplianceReport(...)` builds a `ComplianceReport` — the
evidence bundle to hand an ad network's support team when an account gets
flagged (consent state, safety-layer snapshot, raw ad-event history for the
window). `exportSignedComplianceReport(...)` wraps the same report with an
on-device Ed25519 signature, so an edit made to the exported file AFTER the
SDK produced it is detectable:

```dart
final signed = await AdManager().exportSignedComplianceReport(
  from: DateTime.now().subtract(const Duration(days: 7)),
);
final bundleJson = signed.toJsonString(pretty: true);
// hand bundleJson (or write it to a file) to the ad network's dispute form.
```

The signing key is minted once per install and persisted via
`flutter_secure_storage` — no configuration needed. Anyone (you, or the ad
network reviewer) can verify a bundle independently:

```dart
final ok = await verifySignedComplianceReportJson(bundleJson);
```

or from the command line:

```bash
dart run tool/verify_compliance_report.dart path/to/exported_bundle.json
# → VALID or INVALID
```

**Threat model — read before treating this as proof of anything more than
internal consistency.** The signing key lives on the same device that
produces the report, and travels WITH the exported bundle. This proves the
exported JSON matches exactly what the SDK generated at `generatedAt` — it
stops a casual after-the-fact hand-edit of the file before you submit it. It
is **not** non-repudiation: a device owner who controls the app also controls
the signing key, so this cannot prove the events themselves weren't
fabricated by someone with that level of access. Treat it as "this file is
unmodified since export", not "this device's history is definitely genuine".

### Consent provenance journal (T202)

Opt-in — pass `AdConfig(enableConsentProvenanceJournal: true, ...)`. Default
`false`: it does real SHA-256 hashing (`package:cryptography`) on every
consent change, latency an app with no legal-audit-trail need shouldn't pay
for by default.

`AdManager().consentProvenanceJournal` (nullable until SDK init completes AND
until enabled, same contract as `AdManager().vip`) is an append-only,
tamper-evident (SHA-256 hash chain) history of consent changes — distinct
from `ConsentManager.current` (current state only, overwritten on every
change) and `ComplianceReport` (a point-in-time snapshot): this is the change
*history* neither of those keeps.

```dart
final journal = AdManager().consentProvenanceJournal;
for (final entry in journal?.entries ?? const []) {
  print('${entry.at}: ${entry.source} set hasUserConsent=${entry.hasUserConsent}');
}
await journal?.verifyChain(); // false ⇒ persisted history was tampered with
```

When enabled, every `ConsentManager.set`/`.reset` call records
an entry automatically. Pass `source`/`policyRevision` to tag where a
consent change came from (free text, e.g. `'ump'`, `'host'`, `'manual'` —
same convention as `IncidentEntry.label`); both default to values that make
sense for a plain `AdManager().setConsent(...)` call.

**Deliberately excluded from `clearSdkData()`'s default sweep** — see
below.

### Scoped data erasure (T200)

For a "delete my data" / GDPR-style privacy request, use
`AdManager().clearSdkData(...)`, **not** `AdPreferences.clearAllData()`
(that call wipes the ENTIRE shared `SharedPreferences` instance,
including any key a host app — or a different plugin — stored in the
same namespace):

```dart
// Safe default — clears safety counters, consent settings,
// compliance/analytics history, remote-config cache, experiment id.
// Never touches VIP entitlements OR the consent provenance journal.
await AdManager().clearSdkData();

// Also erase VIP entitlements (a paying user LOSES their VIP status) —
// requires an explicit confirmation flag; throws ArgumentError without it.
await AdManager().clearSdkData(
  scope: SdkDataErasureScope.allIncludingEntitlements,
  confirmedEntitlementErasure: true,
);

// Also purge the consent provenance journal (T202) — a SEPARATE decision
// from entitlements, orthogonal to `scope`: some legal frameworks permit/
// require KEEPING proof that consent was asked/received even after a
// user's general erasure request, so this never happens implicitly.
await AdManager().clearSdkData(purgeConsentProvenanceJournal: true);
```

Only ever removes keys this SDK itself owns (across both
`SharedPreferences` and `flutter_secure_storage`, where VIP entitlements
live) — a host app's own keys in the same storage are never touched at
either scope. If the SDK is already initialised when the entitlements
scope runs, the live `VipManager` instance is used, so the running
session's VIP status updates immediately rather than waiting for the
next restart.

### Compliance checklist

- [ ] `app-ads.txt` placed at the root of your app's domain
- [ ] Privacy Policy URL declared in App Store / Play Store listing
- [ ] iOS App Tracking Transparency prompt shown via `AdManager().requestAtt()` in the splash, **before** `requestUmpConsent` / `AdManager().initialize` (see Option 0)
- [ ] If app targets children, `isAgeRestrictedUser: true` (COPPA). AdMob honours this per-request via `tagForChildDirectedTreatment`. AppLovin MAX 4.x has no runtime child-directed API, so (T40, 2026-07-13) `AppLovinAdapter` refuses to initialize at all when `true` is known **at init time** (persisted from a prior session) — every AppLovin ad surface then stays unavailable for the session (exposed via `AppLovinAdapter.disabledForChildUser`). **Known gap**: on a brand-new install with no persisted consent yet, an app that is *always* child-directed (no consent flow has run yet) will still see AppLovin initialize once, since there's nothing yet to gate on — don't rely on this SDK for an always-child-directed app without adding your own explicit "child app" config ahead of `initialize()`.
  - **This AdMob-vs-AppLovin handling asymmetry (per-request tag vs. full init abort) is intentional**, driven purely by what each provider's native SDK exposes — AdMob has a per-request COPPA flag, AppLovin MAX 4.x does not. It is not an inconsistency to "fix"; treat AppLovin's behavior (no ads at all for a known child-directed session) as the stricter, safer default for that provider.
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

**AdMob's own test-device allowlist (`RequestConfiguration.setTestDeviceIds()`) needs a different, unrelated ID — not the GAID above.** Google has no public formula for it; the only way to get it is to trigger one ad request on the physical device and read the hex hash the native SDK itself prints to logcat (tag `Ads`), in both debug and release builds. `AdManager().adMobTestDeviceHashHint()` returns that instruction plus the device's current GAID (clearly labeled — mixing the two up sends a QA device live production ads instead of test ads) — call it from your own debug UI when you need to walk through this. `AdManager().currentDeviceGaid` exposes the raw GAID alone.

### 4. `setNavigatorKey` must be called before `runApp`

If you forget, App Open on resume and `AdLoadingDialog`'s buffer screen have no `BuildContext` to use and silently skip.

### 5. Initialize the SDK in `SplashScreen`, not `main`

The SDK fires a `BoolEvent` over `SimpleEventBus` when initialization completes. `SimpleEventBus` does replay its most recently fired event to a listener that registers late, but the conventional (and simplest to reason about) pattern is still to register before triggering init:

1. `splash.initState`: register the listener
2. `splash.initState`: schedule `AdManager().initialize` via a post-frame callback
3. The init completes, `BoolEvent` fires, listener runs

If you initialize in `main` directly, the listener registration in your splash will miss the fire and the splash will hang on the hard cap.

### 6. Slot state after dismiss

The SDK's `_lastFullscreenDismissAt` is recorded by a slot-state watcher on the `showing → !showing` transition, not by adapter callbacks. This is the source of truth for the resume-guard window. If you wrap or override slot state mutation, ensure the transition still fires (`slot.markDismissed()` or equivalent).

### 7. AppLovin banner width — `loadBannerIfNeeded(widthPx)` is a no-op by design

`AdProviderAdapter.loadBannerIfNeeded(widthPx)` is only meaningful for AdMob (`AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(widthPx)` picks the pixel-perfect adaptive size at load time). AppLovin's implementation discards `widthPx` — this is not a gap, it's already handled at a different layer: the banner is rendered via `MaxAdView` with `isAdaptiveBannerEnabled: true` (the plugin's default) and no explicit `width`, so `applovin_max` reads the live `MediaQuery` screen width itself at build time (`max_ad_view.dart`'s `_getWidth()`), including on rotation. The one AppLovin API that *does* take an explicit width, `AppLovinMAX.setBannerWidth(adUnitId, width)`, only applies to the native overlay banner created via `createBanner`/`showBanner` — a separate code path this SDK does not use (it exclusively uses the embedded `MaxAdView` widget path), so wiring it in would touch dead API surface for no rendering change. Net effect: AppLovin banners here are adaptive-width in practice, just via automatic `MediaQuery` sizing at display time rather than an explicit width passed at load time like AdMob.

### 8. Don't configure the same AppLovin ad-unit id for `bannerId` and `mrecId`

AppLovin's native load-failure callback reports back the ad-unit id, not which widget (banner vs MREC) requested it — this SDK tells them apart by comparing that id against your configured `bannerId`/`mrecId`. If you configure the exact same ad-unit id for both (a plausible copy-paste mistake — nothing stops you, and some setups may even intend a shared unit), a failure can't always be attributed to the right one with certainty; the SDK logs a warning at `initialize()` if it detects this, and falls back to whichever of banner/MREC actually has a load in flight to disambiguate, but a failure while BOTH are loading at once still can't be told apart. Use two distinct ad-unit ids for banner and MREC.

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
  Widget buildBanner({placement, active});               // anchored adaptive banner
  Widget buildMrec({placement, active});                 // fixed 300x250 rectangle
  Widget buildNative({placement, active});               // fixed layout v1, see Native Ad (v1)
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

`AdRevenueEvent.placement` (2.4.0) reports the placement the ad was **shown**
from — the value you passed to `showInterstitial`/`showRewardedAd`/
`showRewardedInterstitialAd`/`showAppOpenAd`. Before 2.4.0 every revenue event
carried `AdPlacement.unspecified` (App Open: always `AdPlacement.splash`,
including on resume), because the providers wire their paid-event listener at
**load** time, when no placement exists yet. Inline formats (banner, MREC,
native) still report `AdPlacement.unspecified`: nothing "shows" them, so there
is no placement to attribute.

`AdRevenueEvent.mediationWaterfall` (`List<String>?`) reports the adapter
class names the mediation SDK tried for that impression, winner last. On
AdMob this is the full ordered waterfall from `ResponseInfo.adapterResponses`.
**AppLovin MAX only reports the winning network per impression** — no
step-by-step waterfall — so on AppLovin this is always a single-element list
containing just `networkName`. Null if the underlying SDK call returned no
response info.

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

## API stability & deprecation policy (T217)

This package follows [semantic versioning](https://semver.org/): a `MAJOR`
bump means a breaking change, `MINOR` means new backwards-compatible API,
`PATCH` means a fix with no API change. The "Migration" section below is the
historical record of this in practice — every version jump so far has been
"no breaking change" or "deprecations, not removals" (see 1.x → 2.x).

- **Deprecating something:** mark it `@Deprecated('use X instead')` (never
  delete it outright in the same release). It stays callable, with a
  compile-time warning, for **at least one MINOR version** before an actual
  removal — which itself only happens in a MAJOR bump, called out explicitly
  in `CHANGELOG.md` and the "Migration" section above.
- **Marking something not yet stable:** new, still-evolving API is tagged
  `@experimental` (from `package:meta`) in its doc comment while it's being
  shakedown-tested — a signal it may still change shape based on early
  feedback, lifted once it's proven out over a release or two.
- **Enforcement — the API golden test:** `test/api_golden_test.dart` walks
  the fully resolved public export surface of
  `lib/applovin_admob_sdk.dart` (every class/enum/top-level symbol a host
  actually sees, and every public member declared on each — see
  `tool/api_surface.dart`'s doc comment for exactly what counts and what's
  deliberately excluded, namely `@internal`/`@visibleForTesting` seams)
  and fails on any diff from the checked-in
  `test/goldens/public_api_surface.txt`. A hand-written changelog entry is
  easy to forget mid-refactor; a failing test in the same `flutter test` run
  as everything else is not. On a genuine, intentional API change:
  1. Update `CHANGELOG.md`.
  2. Regenerate the golden file:
     `dart run tool/api_surface.dart > test/goldens/public_api_surface.txt`
  3. Review that diff like any other code change before committing it.

---

## Migration

See `doc/AD_PROMPT_FLUTTER.MD` → Appendix D for a step-by-step guide (merged from the former `MIGRATION.md`, 2026-08-20).

- **1.0.14 → 1.0.15** — no breaking change. Update the version, run `flutter pub get`, optionally remove `android:taskAffinity=""` from `MainActivity`.
- **1.0.1x → 1.0.19** — no breaking change. New optional `AdManager().requestAtt()` for iOS ATT (call in splash before UMP); add `NSUserTrackingUsageDescription` to `Info.plist` if targeting iOS. iOS App-Open watchdog fix is automatic.
- **1.0.19 → 1.0.20** — no breaking change, no API change (example-only update).
- **1.0.20 → 1.0.21 → 1.0.22 → 1.0.23** — all backwards-compatible. Just bump the version and run `flutter pub get`. 1.0.21 refreshes dependencies; 1.0.22 adds the opt-in `stack` flag (VIP stacking), `bypassVipGuard` on `showRewardedAd`, and `AdConfig.maxVipStackDuration`; 1.0.23's App-Open-skip-on-dialog behaviour is automatic. (1.0.21/1.0.22 were not published to pub.dev — the public line jumped 1.0.20 → 1.0.23.)
- **1.x → 2.x** — backwards-compatible (deprecations, not removals). Old call sites compile and behave the same.

---

## Support

- **Bug reports**: this package's source repo is private, so there's no public issue tracker — email `loitp@skyjoy.vn` with `roy93~` log output, SDK version, and provider (admob/appLovin). Best-effort, single maintainer, no SLA.
- **Demo app**: `packages/ad_sdk/example/lib/main.dart` — 21 self-contained demo pages, one per feature
- **Architecture deep-dive**: `doc/architecture.md` — state machine, splash flow, safety gate, memory management (in the git repo only; `doc/` is excluded from the pub.dev tarball)

---

## License

MIT — see `LICENSE` file.
