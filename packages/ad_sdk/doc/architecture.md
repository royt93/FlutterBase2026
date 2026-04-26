# Architecture

## Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         Host app                                │
│  - main()                                                       │
│  - SplashScreen, HomeScreen extends AdScreen                    │
└──────────────────┬──────────────────────────────────────────────┘
                   │ public API
                   ▼
┌─────────────────────────────────────────────────────────────────┐
│                     AdManager (singleton)                       │
│  ┌──────────┐ ┌─────────┐ ┌──────────┐ ┌────────────────┐       │
│  │ Splash   │ │ VIP     │ │ Safety   │ │ Lifecycle      │       │
│  │ flag     │ │ Manager │ │ Config   │ │ Observer       │       │
│  └──────────┘ └─────────┘ └──────────┘ └────────────────┘       │
│  ┌──────────────────────────────────────────────────────┐       │
│  │ Stream<AdEvent> events ─── Retry timer ── Splash budg│       │
│  └──────────────────────────────────────────────────────┘       │
└──────────────────┬──────────────────────────────────────────────┘
                   │ adapter contract
                   ▼
┌─────────────────────────────────────────────────────────────────┐
│                  AdProviderAdapter (abstract)                   │
│  ┌──────────────────────┐    ┌─────────────────────────┐        │
│  │ AdMobAdapter         │ OR │ AppLovinAdapter         │        │
│  │ - AppOpenAd          │    │ - listener-based        │        │
│  │ - InterstitialAd     │    │ - widget AdView         │        │
│  │ - RewardedAd         │    │ - per-slot AdSlot       │        │
│  │ - BannerAd           │    │                         │        │
│  └──────────┬───────────┘    └────────┬────────────────┘        │
│             ▼                         ▼                         │
│   google_mobile_ads             applovin_max                    │
└─────────────────────────────────────────────────────────────────┘
```

---

## State machine

Every ad slot (`appOpen`, `interstitial`, `rewarded`, `banner`) holds an
`AdSlot` with one of six states:

```
                ┌─────────┐
                │  idle   │◄───────────────────────────┐
                └────┬────┘                            │
                     │ beginLoad()                     │
                     ▼                                 │
                ┌─────────┐                            │
                │ loading │                            │
                └────┬────┘                            │
              ┌──────┴───────┐                         │
   markReady()│              │ markFailed()            │
              ▼              ▼                         │
         ┌─────────┐    ┌──────────┐                   │
         │  ready  │    │ cooldown │                   │
         └────┬────┘    └────┬─────┘                   │
              │              │ retry timer / backoff   │
              │ beginShow()  └──────────────►──────────┤
              ▼                                        │
         ┌─────────┐                                   │
         │ showing │                                   │
         └────┬────┘                                   │
   ┌──────────┴────────────┐                           │
   │ markDismissed()       │ markShowFailed()          │
   ▼                       ▼                           │
   idle                cooldown ─────────►─────────────┘
```

`suspended` is reachable from any state (set externally by the safety
gate) — the slot stays put until the gate clears.

---

## Splash flow (sequence)

```
host.main                AdManager        Adapter         provider native
    │ setNavigatorKey()      │                │                │
    ├──────────────────────►│                │                │
    │ runApp()               │                │                │
    │                        │                │                │
SplashScreen.initState                        │                │
    │ markSplashActive()     │                │                │
    ├──────────────────────►│                │                │
    │ incrementSplashCount() │                │                │
    ├──────────────────────►│                │                │
    │ EventBus.listen(cb)    │                │                │
    │                        │                │                │
    │ initialize(config)     │                │                │
    ├──────────────────────►│                │                │
    │                        │ SafeLogger.cfg │                │
    │                        │ AdSafety.init  │                │
    │                        │ VipManager.load│                │
    │                        │ pick adapter   │                │
    │                        ├───────────────►│                │
    │                        │                │ initialize()   │
    │                        │                ├───────────────►│
    │                        │                │ ✓              │
    │                        │◄───────────────┤                │
    │                        │ EventBus.fire(true)             │
    │ ◄──── cb(true) ────────┤                │                │
    │ AdLoadingDialog.showAdBuffer            │                │
    │ showAppOpenAd(bypassSafety:true)        │                │
    ├──────────────────────►│                │                │
    │                        ├───────────────►│ show           │
    │                        │                ├───────────────►│
    │                        │                │ dismiss        │
    │                        │◄───────────────┤                │
    │ ◄────────────────────┤                │                │
    │ markSplashInactive() + Navigator.pushReplacement()       │
```

---

## Safety gate

Every `showFullscreen*` call hits `AdSafetyConfig.canShowFullscreenAd()`,
which evaluates:

1. **Suspicious pause** — progressive cooldown after CTR / click anomaly.
2. **Min session duration** — block first ad until app warmed up.
3. **Per-session cap** — default 6 ads.
4. **Per-hour cap** — default 3 ads.
5. **Per-day cap** — persisted in prefs, default 5 ads.
6. **Throttle** — min ms between ads.
7. **CTR threshold** — auto-pause if (clicks / impressions) > threshold.

Result is wrapped in `AdSafetyResult(canShow, reason)`. `dryRun` mode
logs the reason but always returns `true` (QA only).

---

## Memory management

- `Future.delayed` callbacks that pin caller closures → replaced with
  cancellable `Timer` fields.
- Native AdMob ad object → `fullScreenContentCallback = null` **before**
  `dispose()` (prevents late-callback mutations on a destroyed object).
- AppLovin native listeners → cleared in `destroy()` via
  `setXxxListener(null)`.
- `WidgetsBindingObserver` re-registered on `initialize()`,
  removed on `destroy()`.
- VIP entries / GAID list / daily count → persisted in
  SharedPreferences. Lazy purge of expired entries.

---

## Versioning

- 1.0.15 (current) — Cupertino consent dialog, UMP wrapper, first-install
  VIP grace, smart App-Open timeout, slot-state dismiss watcher, granular
  diagnostic logs.
- 1.0.14 — adapter + state machine, VIP system, basic consent flags.
- 3.0.0 (planned) — remove all `@Deprecated` symbols listed in CHANGELOG.

---

## New in 1.0.15

### `ConsentManager` (orchestrator above `AdConsent`)

```
┌────────────────────────────────────────────────────────────┐
│ ConsentManager (singleton, bootstrapped during initialize) │
│ ┌──────────┐ ┌────────────────┐ ┌────────────────────────┐ │
│ │ persist  │ │ Cupertino      │ │ provider apply         │ │
│ │ JSON in  │ │ dialog (binary │ │ pipeline               │ │
│ │ prefs    │ │ Allow/Reject)  │ │ (admob + applovin)     │ │
│ └──────────┘ └────────────────┘ └────────────────────────┘ │
└────────────────────────────────────────────────────────────┘
       │
       │ auto-show ~1s after markSplashInactive
       │ skip if VIP active
       │ skip if hasBeenAsked == true
       ▼
   user picks → persist → applyToProviders
```

### `FirstInstallVipGrace` (build-mode-aware)

```dart
FirstInstallVipGrace.auto      // 30s debug, 24h release (default)
FirstInstallVipGrace.disabled  // never grant
FirstInstallVipGrace.day       // force 24h both modes
const FirstInstallVipGrace(Duration(hours: 12))  // custom
```

Grant fires once per install (tracked via `_keyFirstInstallApplied` in
prefs). After grace duration, `VipManager` auto-expire timer fires +
`AdManager._onVipActiveChanged` listener kicks secondary preload.

### Smart App-Open timeout (lifecycle-aware)

Replaces fixed 10s. Strategy:

```
  every 5s tick:
    if !appOpenSlot.isShowing → exit (natural callback fired)
    else if app foreground → grace tick once → force dismiss(false)
    else (app paused) → re-arm +5s
  hard cap: 90s (18 ticks)
```

Avoids false-positive when AppLovin's `onAdHiddenCallback` arrives 10-30s
late after click → browser → return.

### Slot-state dismiss watcher

Replaces brittle adapter-callback timestamp writes:

```dart
// In AdManager.initialize():
_attachFullscreenDismissWatchers();   // listens to slot.state for all 3 fullscreen
// → fires _lastFullscreenDismissAt = now ON state transition out of `showing`
```

Source of truth for the resume guard's `dismissDelta < 5000ms` check.
Works regardless of adapter quirks (rewarded fires onDone on earn vs
dismiss, etc.).

### Process-restart diagnostic

```
constructor _internal() {
  print('roy93~ [AdManager] 🚀 AdManager singleton CREATED — ...');
}
```

Two `🚀 CREATED` markers in the same logcat session = Android killed +
restarted the process between them. Useful for diagnosing memory-pressure
kills vs SDK crashes.

### Detached lifecycle warning

```
@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  // ...
  if (state == AppLifecycleState.detached) {
    SafeLogger.w('🚨 lifecycle DETACHED — Flutter engine being torn down');
    return;
  }
  // ...
}
```

Fires before process death (when OS is tearing down). Useful for last
opportunity to flush analytics.

---

## Manifest pitfall

**Do NOT** set `android:taskAffinity=""` on `MainActivity`:

```xml
<activity
    android:name=".MainActivity"
    android:launchMode="singleTop"
    <!-- android:taskAffinity=""  ← causes AppLovin overlay to land in
         a different Android task; on user HOME → reopen, the activity
         stack becomes empty after ad dismiss → user dropped to launcher,
         appears as "app crashed". -->
    ...>
```

Default affinity (= package name) is safe. Just omit the attribute.
