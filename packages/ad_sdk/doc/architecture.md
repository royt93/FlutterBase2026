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

- 2.0.0 (current) — adapter + state machine, VIP, consent.
- 3.0.0 (planned) — remove all `@Deprecated` symbols listed in CHANGELOG.
