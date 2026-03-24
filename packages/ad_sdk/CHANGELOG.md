## 1.0.13

### New Feature: Navigator Key for SDK Dialogs
- **`AdManager.setNavigatorKey()`** — Register your app's `GlobalKey<NavigatorState>` so the SDK can show `AdLoadingDialog` from lifecycle callbacks (e.g. App Open on resume) without a `BuildContext`.
- **Fix #47: App Open resume now shows `AdLoadingDialog`** — Previously used a silent `Future.delayed(1s)` hack because `showAppOpenAdOnResume()` runs from the lifecycle observer (no `BuildContext`). Now uses the registered navigator key to show the actual loading dialog with spinner, matching the same UX as interstitial and rewarded ad flows.
- Fallback: if no navigator key is registered, the old 1s delay buffer is used.

### Bug Fixes
- **Fix #44/45/46: App Open resume guards** — Throttle check (`_lastFullscreenAdTime`), dismiss timestamp guard (`_lastFullscreenDismissTime`), and 1s buffer all now work correctly together.

## 1.0.12

### Memory Leaks
- **Fix N: `SimpleEventBus` listener accumulation** — Added `clearAll()` method, called from `destroy()` to prevent closure-held widget tree leaks.
- **Fix O: `WidgetsBindingObserver` not re-added after `destroy()` + reinit** — Lifecycle observer now re-adds itself on `initialize()` via `_ensureObserverAdded()`. Without this, App Open on resume and all lifecycle features silently stopped working after reinit.

### Invalid Traffic
- **Fix J: Banner impressions now tracked for CTR** — `recordBannerImpression()` counts initial banner loads in `_totalImpressions`, so CTR-based fraud detection covers banner clicks too.
- **Fix L: Suspicious violation count persists across days** — No longer reset at midnight. Progressive cooldown (30min → 24h) properly escalates for repeat offenders.

### Fill Rate
- **Fix R/T: Periodic ad retry timer (every 5 min)** — Proactively refills empty App Open, Interstitial, and Rewarded slots. Also detects expired AdMob App Open ads (>4 hours) and reloads them.

### Bug Fixes
- **Fix U: `SafeLogger.e` no longer logs in release** — Added `kDebugMode` guard to prevent internal SDK info leaking to device logs in production.
- **Fix V: `_isFirstAdLoadTriggered` now resets in `destroy()`** — Without this, Inter + Rewarded ads were never preloaded after reinit because the load chain was skipped.
- **Fix W: `AdConfig.logLevel` now wired to `SafeLogger`** — Previously the config field was ignored; now `none` and `warning` levels suppress verbose logs.
- **Fix Y: AdMob App Open `onAdFailedToShow` returns `false`** — Was returning `true` (implying ad was shown). Now correctly returns `false` and triggers reload.


- **Bug fix (F): No ad reload after AppLovin display fail** — `onAdDisplayFailedCallback` for App Open, Interstitial, and Rewarded now calls `loadAppOpenAd`/`loadInterstitial`/`loadRewardedAd` after failure, so a fresh ad is preloaded for the next attempt.
- **Bug fix (G): App Open display-fail returned `true`** — `_onAppOpenDismissed?.call(true)` changed to `call(false)`. The caller now correctly knows the ad was NOT shown.
- **Bug fix (H): `canShowInterstitial` / `canShowRewardedAd` didn't check dialog state** — Both pre-check methods now return `false` when `AdLoadingDialog.isShowing == true`, preventing a second ad flow from starting while the first dialog buffer is still active.
- **Bug fix (I): `AdSafetyConfig._isColdStart` not reset on `destroy()` + reinit** — Added `AdSafetyConfig.resetForReinit()` which resets cold start flag, session state, timestamps, and suspicious pause. Called from `AdManager.destroy()`.


- **Bug fix (A): AdMob Interstitial early lock not released on null-ad** — `_showInterstitialAdmob` now releases `_isInterstitialShowing` when the cached ad is null, preventing permanent interstitial blockage.
- **Bug fix (B): `showRewardedAd` missing early concurrent guard** — Added `_isRewardedShowing` early lock at the top of `showRewardedAd()` (mirrors 1.0.9 interstitial fix), preventing double rewarded flows from double-tap.
- **Bug fix (C): AdMob Rewarded early lock not released on null-ad** — `_showRewardedAdmob` now releases `_isRewardedShowing` when the cached ad is null.
- **Bug fix (D): App Open timeout fires while ad is still showing** — Timeout (10s) now checks `!_isMaxAppOpenShowing` before force-calling `onAdDismiss(false)`, preventing the callback firing mid-ad (e.g. during a long video).
- **Bug fix (E): Redundant `_isRewardedShowing` check in `_showRewardedAppLovin`** — Removed duplicate guard now handled by the early lock in `showRewardedAd()`.


- **Bug fix: Concurrent dialog guard** (`AdLoadingDialog`) — Added `_isShowing` static flag. If `showAdBuffer` is called a second time while a dialog is already showing (double-tap), the duplicate call immediately invokes `onComplete` without pushing a second dialog. Previously, two stacked dialogs caused `navigator.pop()` to dismiss the wrong one.
- **Bug fix: Early interstitial lock** (`AdManager.showInterstitial`) — `_isInterstitialShowing = true` is now set at the START of `showInterstitial()`, before the 1s dialog buffer. Previously, a double-tap during the buffer could pass the `canShowInterstitial()` check twice and show two dialogs.
- **Bug fix: AppLovin App Open timeout fallback** — `_showAppOpenAdAppLovin` now starts a 10-second timer. If no AppLovin callback fires within 10s (AppLovin internal loading hang), `onAdDismiss(false)` is force-called to unblock the splash screen's navigation flow.


- **Bug fix: Loading dialog hang (root cause — real fix)**
  - **Root cause:** `AdLoadingDialog` captured `Navigator.of(context)` AFTER the async delay, then guarded `pop()` with `context.mounted`. If the parent screen was disposed during the 1s buffer (e.g., user navigated back), `context.mounted == false` → `pop()` was **skipped** → dialog stayed on screen forever with no one to dismiss it
  - **Fix:** Capture `NavigatorState` via `Navigator.of(context, rootNavigator: true)` **BEFORE** the `await` delay. `NavigatorState` is owned by the root navigator widget (not the screen) and outlives any screen disposal. The dialog is now **always** dismissed regardless of `context.mounted`
  - Note: version 1.0.7 partially addressed related symptoms (rewarded skip callback orphan, safety re-check logging) but did **not** fix the actual dismissal race condition


- **Bug fix: Loading dialog hang** — Fixed 3 root causes that caused `AdLoadingDialog` to get stuck on screen permanently:
  1. **AppLovin Rewarded skip bug (critical)**: `onAdHiddenCallback` was not calling `_pendingRewardedDoneFlow(false)` when user closed the rewarded ad without watching it fully. This left the callback orphaned and the loading dialog visible indefinitely
  2. **Safety re-check log gap**: `showInterstitial` / `showRewardedAd` safety failures after the 1s dialog buffer now log the reason (`safetyResult.reason`) and explicitly guarantee `onDoneFlow`/`onEarnedReward` is always called
  3. **AdLoadingDialog logging**: Added `SafeLogger` throughout — pop errors (context detached) are now caught and logged instead of crashing silently


- Replaced real AppLovin credentials in example app with `YOUR_*` placeholders — prevents accidental credential exposure in published package


- Merged example app into a single `main.dart` file for simplicity
- Completely rewrote README with detailed step-by-step integration guide (Android setup, iOS setup, AdMob/AppLovin setup, 7-step guide, ad types reference, AdConfig reference, safety layer table, VIP bypass, TopToast, troubleshooting)


- Fixed double `loadAppOpenAd` in-flight guard for **AppLovin** provider — `_isAppOpenLoading` is now set/reset in `_loadAppOpenAdAppLovin` and its loaded/failed callbacks, preventing duplicate requests and callback overwrites that broke the splash App Open flow
- Fixed hard cap timer not being cancelled before `showAppOpenAd` is called in splash — prevents force-navigation while an ad is actively displaying (example + WiFi splash screens)


- Replaced all `debugPrint` in `AdScreenRouteLogger` with `SafeLogger.d` — consistent logging across the entire SDK
- Bumped dependencies: `google_mobile_ads: ^7.0.0`, `shared_preferences: ^2.5.4`, `connection_notifier: ^3.0.0`, `flutter_lints: ^6.0.0`


- Renamed package from `ad_sdk` to `applovin_admob_sdk`
- `AdConfig` now supports `adNotReadyMessage` and `adLoadingMessage` for localizable UI strings
- `showRewardedAd` auto-shows `TopToast` with `adNotReadyMessage` when no ad is available — callers no longer need to show their own feedback
- `AdLoadingDialog` uses `adLoadingMessage` from config instead of hardcoded `'Loading...'`
- `AdManager` exposes public `config` getter

## 1.0.1

- Added `TopToast` — animated, glassmorphism top-center toast widget (overlay-based, no Scaffold needed)
- `showRewardedAd`: changed to hard gate — `onEarnedReward(false)` when ad unavailable (caller shows user feedback)
- Fixed `_hasPlaceholderIds()` logic bug in example app splash screen

## 1.0.0

- Initial release
- Dual-provider support: AdMob (google_mobile_ads) and AppLovin MAX (applovin_max)
- Ad types: App Open, Banner, Interstitial, Rewarded
- 12-measure AdSafety layer: throttle, session/hourly/daily caps, CTR fraud, progressive cooldown
- RouteAware banner with auto pause/resume on navigation
- VIP device bypass via GAID list
- Shimmer loading placeholder for banner
- AdLoadingDialog buffer before fullscreen ads
- Provider-agnostic AdScreen base class (no external state manager required)
