# Architecture

A deep-dive into the internals of `applovin_admob_sdk`. Read this if you intend to extend the SDK, debug a subtle issue, or contribute. For integration, see `README.md`.

## Table of contents

1. [High-level design](#high-level-design)
2. [State machine](#state-machine)
3. [Splash flow](#splash-flow)
4. [Lifecycle observer](#lifecycle-observer)
5. [Safety gate](#safety-gate)
6. [VIP system](#vip-system)
7. [Consent flow](#consent-flow)
8. [Smart App-Open timeout](#smart-app-open-timeout)
9. [Slot-state dismiss watcher](#slot-state-dismiss-watcher)
10. [Memory management](#memory-management)
11. [Versioning](#versioning)
12. [Manifest pitfalls](#manifest-pitfalls)

---

## High-level design

```
┌─────────────────────────────────────────────────────────────────┐
│                         Host app                                │
│  - main()                                                       │
│  - SplashScreen, HomeScreen extend AdScreen                     │
└──────────────────┬──────────────────────────────────────────────┘
                   │ public API
                   ▼
┌─────────────────────────────────────────────────────────────────┐
│                     AdManager (singleton)                       │
│  ┌──────────┐ ┌─────────┐ ┌──────────┐ ┌────────────────┐       │
│  │ Splash   │ │ VIP     │ │ Safety   │ │ Lifecycle      │       │
│  │ flag     │ │ Manager │ │ Config   │ │ Observer       │       │
│  └──────────┘ └─────────┘ └──────────┘ └────────────────┘       │
│  ┌──────────┐ ┌──────────────────────────────────────────┐      │
│  │ Consent  │ │ Stream<AdEvent> · Retry · Splash budget  │      │
│  │ Manager  │ │ · Slot watchers · Resume guard           │      │
│  └──────────┘ └──────────────────────────────────────────┘      │
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
│  │ - BannerAd           │    │ - smart timeout         │        │
│  └──────────┬───────────┘    └────────┬────────────────┘        │
│             ▼                         ▼                         │
│   google_mobile_ads             applovin_max                    │
└─────────────────────────────────────────────────────────────────┘
```

`AdManager` is provider-agnostic. Switching from AdMob to AppLovin requires only changing `AdConfig.provider` — every `AdManager` API call routes through the adapter contract.

---

## State machine

Every ad slot (`appOpen`, `interstitial`, `rewarded`, `banner`) holds an `AdSlot` instance with a single state at any time:

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
              │ beginShow()  └──────────►──────────────┤
              ▼                                        │
         ┌─────────┐                                   │
         │ showing │                                   │
         └────┬────┘                                   │
   ┌──────────┴────────────┐                           │
   │ markDismissed()       │ markShowFailed()          │
   ▼                       ▼                           │
   idle                cooldown ─────────►─────────────┘
```

State transitions are guarded:

- `beginLoad()` only succeeds if state is `idle` or `cooldown` (after backoff window). Returns `false` otherwise — the caller knows not to dispatch a duplicate native load.
- `beginShow()` only succeeds from `ready`. Prevents double-show races.
- `markDismissed()` returns to `idle` (caller usually triggers a fresh load right after).
- `markShowFailed()` returns to `cooldown` (with backoff before re-load).

Wrapping state in a `ValueNotifier<AdSlotState>` enables reactive widgets to render the current state without tight coupling:

```dart
ValueListenableBuilder<AdSlotState>(
  valueListenable: AdManager().adapter!.bannerSlot.state,
  builder: (_, state, __) => state == AdSlotState.ready
      ? const BannerWidget()
      : const Skeleton(),
);
```

This state machine replaces ~14 hand-managed boolean flags from the 1.x code (`_isInterLoading`, `_isMaxInterReady`, `_lastInterErrorTime`, etc.) and eliminates whole classes of races by design.

---

## Splash flow

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
    │                        │ first-install  │                │
    │                        │   grace grant  │                │
    │                        │ pick adapter   │                │
    │                        ├───────────────►│                │
    │                        │                │ initialize()   │
    │                        │                ├───────────────►│
    │                        │                │ ✓              │
    │                        │◄───────────────┤                │
    │                        │ ConsentManager.bootstrap        │
    │                        │ applyConsentToProviders         │
    │                        │ EventBus.fire(true)             │
    │ ◄──── cb(true) ────────┤                │                │
    │ AdLoadingDialog.showAdBuffer (1s)       │                │
    │ showAppOpenAd(bypassSafety:true)        │                │
    ├──────────────────────►│                │                │
    │                        ├───────────────►│ show           │
    │                        │                ├───────────────►│
    │                        │                │ dismiss        │
    │                        │◄───────────────┤                │
    │ ◄────────────────────┤                │                │
    │ markSplashInactive()                                     │
    │   → schedule consent dialog (+1s)                        │
    │ Navigator.pushReplacement(HomeScreen)                    │
    │ ... ~1s later ...                                        │
    │ ◄── consent dialog auto-shows on home if !VIP ──         │
```

Key invariants of this flow:

1. **`setNavigatorKey` before `runApp`** — required for the SDK to surface dialogs from non-context callers (the lifecycle observer and the consent scheduler).
2. **`EventBus.listen` before `initialize`** — `SimpleEventBus` only delivers fire events to listeners that registered before the fire. Late subscribers miss the init-complete signal.
3. **Splash app open uses `bypassSafety: true`** — the only sanctioned bypass. Prevents the safety gate from blocking the splash flow due to a cold-start `minSessionDurationBeforeAd`.
4. **`markSplashInactive` schedules the consent dialog** — the dialog lands on whatever route the host navigates to next (typically home), avoiding contention with the splash app-open ad.

---

## Lifecycle observer

`AdManager` implements `WidgetsBindingObserver` and listens to `didChangeAppLifecycleState`. On `resumed`, it:

1. Logs the transition with full state (`prev → current`, slot states, VIP, splash flag, backgrounded duration).
2. Calls `adapter.onAppResumed()` (re-enables banner auto-refresh, rebuilds banner if it errored).
3. Calls `showAppOpenAdOnResume()` which evaluates a chain of gates:

```dart
adapter is null → skip
splash still active → skip
VIP member → skip
inter/rewarded currently showing → skip
recent fullscreen dismiss (< 5s) → skip + reload
safety gate denies (cold-start, throttle, etc.) → skip + reload
appOpenSlot not ready → skip + reload
all gates passed → AdLoadingDialog.showAdBuffer + showAppOpenAd
```

Each skip path emits an explicit `⏭️ skipped — <reason>` log. There is no silent return.

The `recent fullscreen dismiss` gate (5-second window) is critical — without it, dismissing an interstitial would trip the "lifecycle resumed" handler, which would in turn trigger an app-open ad on top of the still-dismissing interstitial. The 5-second window is wider than 1.0.14's 2-second window because real devices can take longer than 2 seconds to deliver the dismiss callback after the user actually taps the close button.

`AppLifecycleState.detached` is handled separately — it indicates the Flutter engine is being torn down (process about to die). The SDK emits `🚨 lifecycle DETACHED` so observability stacks can flush analytics one last time.

---

## Safety gate

Every `showFullscreen*` call hits `AdSafetyConfig.canShowFullscreenAd()`, which evaluates these gates in order:

1. **Suspicious pause** — progressive cooldown after a CTR or click anomaly. Doubles each violation up to a cap.
2. **Min session duration** — block first ad until app warmed up. Default 10 seconds.
3. **Per-session cap** — default 6 fullscreen ads per session.
4. **Per-hour cap** — default 3 ads per rolling hour.
5. **Per-day cap** — persisted in SharedPreferences across launches. Default 5 ads.
6. **Throttle** — minimum milliseconds between fullscreen ads. Default 60 seconds.
7. **CTR threshold** — auto-pause if `clicks / impressions > suspiciousCtrThreshold`. Default 30%.
8. **Click rate** — flag if `clicksPerMinute > maxClicksPerMinute`. Default 3.
9. **Rapid resume rate** — flag if `resumesPerMinute > maxRapidResumesPerMinute`. Default 5.

Result is `AdSafetyResult(canShow, reason)`. `dryRun` mode logs the reason but always returns `true` (QA only — never enable in production).

`canShowAppOpenOnResume()` is a separate gate:

1. **Throttle since last fullscreen** — prevents app-open immediately after an interstitial/rewarded dismiss.
2. **Cold start protection** — first resume of the process is always skipped.
3. **Resume too fast** — skip if app was backgrounded for less than `minTimeAppOpenResume` (default 5 seconds).
4. **Rapid resume detection** — skip if too many resumes per minute.

All wait durations format with `_fmtWait(ms)`: shows milliseconds when sub-second (e.g., `wait 645ms`), seconds with one decimal otherwise (e.g., `wait 1.5s`). This eliminates the "wait 0s" log bug from 1.0.14 where sub-second waits truncated to zero.

---

## VIP system

`VipManager` persists `List<VipEntry>` in SharedPreferences as JSON. Each entry has a `key`, `expiresAt`, and `grantedAt`.

```
┌────────────────────────────────────────────────────────────┐
│ VipManager                                                 │
│                                                            │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ List<VipEntry> _entries (in-memory cache)            │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                            │
│  isActive ────────► any entry with expiresAt > now ?       │
│                                                            │
│  ┌──────────────────┐                                      │
│  │ Timer? expiry    │ ── fires at soonest expiresAt ──┐    │
│  │       Timer      │                                 │    │
│  └──────────────────┘                                 ▼    │
│                                              _purgeExpired │
│                                              _refreshActive│
│                                              _scheduleNext │
│                                                            │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ ValueNotifier<bool> activeListenable                 │  │
│  │ Stream<bool> activeStream                            │  │
│  └──────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────┘
            │
            │ AdManager listens to activeListenable
            │ on true → false transition:
            ▼
   loadAppOpenAd + loadInterstitial + loadRewardedAd + preloadBanner
   (so the user does not see "ad not ready" on the first show after VIP expires)
```

The auto-expire `Timer` is the key 1.0.15 improvement. Before, VIP state only refreshed on `load()` / `addVip` / `revokeVip` / `revokeAll` — meaning a user who kept the app open past their VIP expiry stayed falsely VIP until the next launch.

Conflict policy: when adding a key that already exists, the entry whose `expiresAt` is the **latest** wins. This makes restore-purchase flows safe — re-adding the same purchase ID does not shorten the user's remaining time.

---

## Consent flow

```
┌────────────────────────────────────────────────────────────────┐
│ AdConfig.autoShowConsentDialog: true (default)                 │
└────────────────────────────────────────────────────────────────┘
                  │
                  ▼
┌────────────────────────────────────────────────────────────────┐
│ AdManager.initialize()                                         │
│  → ConsentManager.bootstrap(prefs, strings)                    │
│     → load persisted ConsentSettings from SharedPreferences    │
│     → applyConsentToProviders(current.toAdConsent())           │
└────────────────────────────────────────────────────────────────┘
                  │
                  ▼
┌────────────────────────────────────────────────────────────────┐
│ AdManager.markSplashInactive()                                 │
│  → _maybeScheduleConsentDialog()                               │
│     → if VIP active                                  → skip    │
│     → if hasBeenAsked == true                        → skip    │
│     → else: Timer(consentDialogPostSplashDelay)                │
└────────────────────────────────────────────────────────────────┘
                  │ ~1s later
                  ▼
┌────────────────────────────────────────────────────────────────┐
│ Timer fires                                                    │
│  → re-check: VIP became active during the 1s window? → skip    │
│  → re-check: navigator.currentContext null? → skip + log warn  │
│  → ConsentManager.showDialog(ctx)                              │
│     → showCupertinoDialog (binary Allow / Reject)              │
│     → user picks                                               │
│     → ConsentSettings.copyWith(hasBeenAsked: true, askedAt: …) │
│     → persist to SharedPreferences                             │
│     → applyConsentToProviders                                  │
└────────────────────────────────────────────────────────────────┘
```

Skipping for VIP is intentional. The first-install grace and any redeemed VIP keys give the user an ad-free session, so prompting for ad consent during that window adds friction without compliance benefit. The dialog will surface naturally once VIP expires.

The consent dialog is a custom `Material` `Dialog` (not stock `CupertinoAlertDialog`) wrapped in a transparent `Material` widget so the `Text` widgets inherit the host app's `DefaultTextStyle` instead of falling back to Flutter's debug raw-renderer font (the "yellow text on red underline" debug appearance).

---

## Smart App-Open timeout

AppLovin's `onAdHiddenCallback` fires unreliably — sometimes within milliseconds of dismiss, sometimes 10-30 seconds later (especially when the user clicked the ad and was sent to a browser before returning).

The 1.0.14 fixed 10-second timeout fired false-positive force-dismisses in this scenario. 1.0.15 replaces it with a lifecycle-aware polling timeout:

```
showAppOpen called
  → schedule first tick at +5s

every tick (5s):
  if _appOpenDismiss != captured || !appOpenSlot.isShowing:
    # Already dismissed via natural callback. Watcher exits.
    return

  if app foreground (lifecycle == resumed):
    if attempt < 1:
      # Just-resumed transition. AppLovin's hidden callback is in-flight
      # via method channel. Give it one more 5s tick to land.
      → re-arm at +5s
    else:
      # Foreground for two consecutive ticks. Real hung overlay.
      → force dismiss(false), exit
  else:
    # App still backgrounded. Ad probably still showing or user in browser.
    if attempt >= 18:
      # 90s hard cap.
      → force dismiss(false), exit
    else:
      → re-arm at +5s
```

This allows ads to run as long as 90 seconds before the SDK gives up — far beyond AppLovin's typical 5-30 second range, which covers the click-to-browser-return UX without false-positives.

---

## Slot-state dismiss watcher

The 1.0.14 SDK recorded `_lastFullscreenDismissAt` inside the adapter's `onDone` callback. For the rewarded slot, this fired when the reward was earned (mid-video), not when the user actually dismissed — causing the resume-guard window to leak through and an app-open ad to fire on top of the just-dismissed rewarded.

1.0.15 replaces this with a slot-state watcher attached during `AdManager.initialize`:

```dart
void _attachFullscreenDismissWatchers() {
  for (final slot in [appOpenSlot, interstitialSlot, rewardedSlot]) {
    _slotPrevState[slot.type] = slot.value;
    void listener() {
      final prev = _slotPrevState[slot.type];
      final curr = slot.value;
      if (prev == AdSlotState.showing && curr != AdSlotState.showing) {
        _lastFullscreenDismissAt = DateTime.now().millisecondsSinceEpoch;
        SafeLogger.d(_tag, '🛡️ ${slot.type.name} dismissed — armed');
      }
      _slotPrevState[slot.type] = curr;
    }
    slot.state.addListener(listener);
    _slotWatcherDisposers.add(() => slot.state.removeListener(listener));
  }
}
```

The watcher fires on the actual `showing → !showing` transition regardless of how the adapter wires its callbacks. Source of truth for the resume guard.

The adapter-callback writes are still kept as belt-and-braces fallback (they cannot be wrong, only redundant). The slot watcher is authoritative.

---

## Memory management

- **Future.delayed** callbacks that pin caller closures are replaced with cancellable `Timer` fields throughout the SDK. On `destroy()`, every timer is cancelled to avoid late callbacks against half-disposed state.
- **Native AdMob ad object** has its `fullScreenContentCallback` set to `null` *before* `dispose()`. This prevents late callbacks from mutating slot state on a destroyed object.
- **AppLovin native listeners** are cleared in `destroy()` via `setAppOpenAdListener(null)`, `setInterstitialListener(null)`, etc. Without this, AppLovin's internal closures pin the entire adapter (and transitively the AdManager singleton) in memory.
- **`WidgetsBindingObserver`** is re-registered on `initialize()` and removed on `destroy()`. Re-init in tests does not double-subscribe.
- **VIP entries** are persisted in SharedPreferences. Lazy purge on every `load()` and on the auto-expire Timer fire. No background sweeper needed.
- **Daily ad count** is persisted with the date stamp. On a new day, the count resets to zero on the next read — no scheduled job needed.
- **Memory-pressure log** is throttled to 60 seconds per event. `didHaveMemoryPressure` can fire dozens of times per minute when the user is rapidly backgrounding/foregrounding the app; without throttle, the log buffer floods and useful events get rotated out.

---

## Versioning

| Version | Status | Highlights |
|---|---|---|
| 1.0.20 | Current stable | Example-only release — example splash demos `requestAtt → requestUmpConsent → initialize`. No library/API change vs 1.0.19. |
| 1.0.19 | Stable | iOS App Tracking Transparency (`requestAtt()`, `AttStatus`/`AttResult`); iOS App-Open watchdog fix; AppLovin reload-after-display-fail fix; AdMob parity (watchdog, expiry); rewarded-only VIP grant (removed interstitial fallback). |
| 1.0.17–1.0.18 | Stable | Anti-uninstall-bypass guard for the first-install VIP grace (iOS Keychain + Android Auto Backup); version bump. |
| 1.0.16 | Stable | Documentation-only release. Full English rewrite of README, MIGRATION, and architecture. No runtime code changes vs 1.0.15. |
| 1.0.15 | Stable | Cupertino consent dialog, UMP wrapper, first-install VIP grace, smart App-Open timeout, slot-state dismiss watcher, granular diagnostic logs |
| 1.0.14 | Previous stable | Adapter pattern + state machine, VIP system with redeem dialog, consent flag forwarding, Stream of `AdEvent`, debug overlay |
| 2.0.0 | Unreleased | Will remove all `@Deprecated` symbols listed in `CHANGELOG.md` (legacy GAID-based VIP API, duplicate `ad_sdk.dart` barrel) |

The SDK follows [Semantic Versioning](https://semver.org/). 1.0.x bumps are patch releases — backwards-compatible bug fixes and additive features. 2.0.0 will be a major release with breaking changes (deprecated symbol removal).

---

## Manifest pitfalls

### Do NOT set `android:taskAffinity=""` on `MainActivity`

Some Flutter `flutter create` template versions add this attribute by default. **Remove it** when integrating this SDK with AppLovin:

```diff
  <activity
      android:name=".MainActivity"
      android:exported="true"
      android:launchMode="singleTop"
-     android:taskAffinity=""
      ...
```

#### Why

Activities in Android are organized into tasks. Each activity has a `taskAffinity` — by default, the package name. Activities with the same affinity belong to the same task; activities with different affinities can be split across tasks.

When AppLovin shows a fullscreen ad, it launches `AppLovinFullscreenActivity` — which inherits the application's default task affinity, the package name. With `android:taskAffinity=""` on `MainActivity`, the two activities have different affinities and can land in different tasks.

When the user presses HOME during an ad and reopens the app via the launcher icon, Android's task management gets confused. The `Intent.FLAG_ACTIVITY_NEW_TASK | FLAG_ACTIVITY_RESET_TASK_IF_NEEDED` resolution may bring back the wrong task or fail to merge the two. After the user dismisses the ad, no activity is available to return to in the relevant task — the user is dropped to the launcher.

The user perceives this as a crash even though the process is still alive. The SDK cannot prevent this from the Dart layer because by the time the user returns to the launcher, the Flutter Activity is gone. The fix is the manifest — remove `taskAffinity=""`.

This bug was masked in 1.0.14 because users rarely backgrounded mid-ad. The detailed lifecycle logging added in 1.0.15 surfaced the issue in QA, leading to this documented mitigation.

### Required permissions

The SDK requires three Android permissions:

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>
<uses-permission android:name="com.google.android.gms.permission.AD_ID"/>
```

The first two are obvious. `AD_ID` (added in Android 13) is required to read the advertising ID — both AdMob and AppLovin use it for ad targeting and revenue attribution. Omitting it does not break functionality on Android 12 and below, but on Android 13+ the ad networks fall back to severely limited targeting.

### `minSdkVersion`

AdMob requires Android 5.0 (API 21) or newer. AppLovin requires Android 5.0 as well. Set:

```kotlin
android {
    defaultConfig {
        minSdk = 21
        // ...
    }
}
```

### iOS — `SKAdNetworkItems`

Without `SKAdNetworkItems` in `Info.plist`, AdMob and AppLovin will not serve ads on iOS 14.5+. Copy the canonical list from [AdMob's iOS 14 guide](https://developers.google.com/admob/ios/ios14#skadnetwork). The list has roughly 70 entries and is updated periodically — recheck quarterly.
