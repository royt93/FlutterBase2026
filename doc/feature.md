# Feature Status

Updated: 2026-06-14

## Implemented

- WiFi stress test core flow.
- History/detail/statistics screens.
- VIP screen and SDK VIP integration.
- VIP time **cộng dồn toàn cục (global stacking)** — every grant (redeem code OR
  watch-ad) adds onto the latest expiry across ALL active entries, so all VIP
  time accumulates into one growing window (e.g. ~6 active days + a 30-day code
  ⇒ ~36 days). Implemented as a first-class SDK feature: a `stack` flag on
  `VipManager.addVip` / `redeemVip` (default `false` = latest-expiry-wins;
  `true` = global stacking, `grantedAt` reset). SDK bumped to `1.0.22`; host
  consumes it via the local `path` override.
  - Redeem code: `vip_screen.dart` calls `redeemVip(..., stack: true)`.
  - Watch-ad +3d: uses a fixed key `REWARDED_VIP` (was per-timestamp) +
    `addVip(stack: true)` so repeats consolidate into one entry, no list clutter.
  - Watch-ad section is shown even while VIP is active; the flow passes
    `bypassVipGuard: true` to `AdManager().showRewardedAd`, a new SDK flag that
    lets a VIP voluntarily watch a REAL rewarded ad to extend (policy-compliant,
    no auto-grant). The SDK load-on-demands the slot via `_loadRewardedOnDemand`.
  - Tests: SDK `vip_manager_stacking_test.dart` (8) + `rewarded VIP-bypass` group
    in `ad_manager_core_test.dart` (5); host `test/vip_screen_widget_test.dart`
    (5 widget + 1 redeem→stack integration). Docs synced: SDK README/CHANGELOG,
    `doc/AD_PROMPT_FLUTTER.MD`, `example/lib/main.dart`.
  - Anti-abuse: total stacked window is **capped at 90 days** via
    `AdConfig.maxVipStackDuration` (SDK clamps in `addVip` stack branch; set in
    `splash_screen.dart`). Watch-ad is additionally rate-limited by the SDK's
    fullscreen safety caps.
  - Hardening (post-audit): `showRewardedAd` is re-entrancy-safe
    (`_rewardedInFlight` guard), the on-demand load shows a blocking
    `AdLoadingDialog` with a tunable `onDemandLoadTimeout` (15 s), and the wait
    observes the public `AdSlot.state` notifier (no internal `pendingCallback`
    coupling). SDK at `1.0.22`, 217 tests.
  - **Native build pin (important):** the local SDK `1.0.22` declares
    `google_mobile_ads ^7` / `applovin_max ^4.6.4`, but this app ships on the
    proven `google_mobile_ads 6.0.0` + `gma_mediation_applovin 2.5.1` +
    `applovin_max 4.6.0` stack. Switching to the `path` override dragged GMA 7
    in and broke the `GmaMediationApplovinPlugin` native registrant (Android
    build fail). Fixed by `dependency_overrides` pinning GMA 6 + gma 2.5.1 (SDK
    Dart is GMA-6-compatible). **Verified building: Android `apk --debug` ✅,
    iOS `ios --debug --no-codesign` ✅ (pods OK).** Not yet verified: live ad
    playback / VIP-bypass on a real device — needs on-device testing.
- Android + iOS ad integration with `applovin_admob_sdk ^1.0.20`.
- Platform-specific AppLovin ad unit config:
  Android keeps the previously working unit IDs, iOS uses the provided
  `com.saigonphantomlabs.base` iPhone units, and `AdKey.appLovin` selects at
  runtime by platform.
- iOS native ad config added to `ios/Runner/Info.plist`:
  `GADApplicationIdentifier`, `AppLovinSdkKey`,
  `NSUserTrackingUsageDescription`, and `SKAdNetworkItems`.
- iOS ad delivery VERIFIED on Roy's Phone (iPhone 16 Pro Max, iOS 26.5,
  2026-06-14). Debug run: AppLovin SDK init success=true, no native crash;
  after the 30s first-install VIP grace expired the SDK loaded all four formats
  with the iOS unit IDs — banner `REDACTED_APPLOVIN_IOS_BANNER_ID` (real impression served),
  appOpen `REDACTED_APPLOVIN_IOS_APPOPEN_ID`, interstitial + rewarded all `✅ loaded`.
- iOS App Tracking Transparency (ATT) flow added IN the SDK
  (`AdManager().requestAtt()` / `requestAttIfNeeded()`, exporting
  `AttStatus`/`AttResult`; new dep `app_tracking_transparency`). Host calls it
  in splash BEFORE UMP. Verified on Roy's Phone 2026-06-14: returned
  `authorized` with IDFA present; full ad chain after it incl. App Open
  `✅ displayed` on splash. ATT is decoupled from the GDPR consent flag by
  design (native SDKs read ATT directly for IDFA).
- SDK published to pub.dev as `applovin_admob_sdk 1.0.20`; the app now consumes
  the hosted `^1.0.20` (the local `path: packages/ad_sdk` override is removed).
  Smoke-tested on device against the published package — no regression.

## In progress

- (none)

## Blockers (config, not code)

- UMP consent form NOT configured for AdMob app ID
  `ca-app-pub-3612191981543807~9731053733`. Device log: `requestConsentInfoUpdate
  failed: 4 ... no form(s) configured for the input app ID`. SDK degrades
  gracefully (canRequestAds=true) but EU/GDPR users will never see a consent
  form. Configure a Funding Choices / UMP message in the AdMob dashboard before
  release.

## Picked

- Keep `AdProvider.appLovin` as the runtime provider.
- Do not reuse AppLovin ad unit IDs across Android and iOS.
- Keep AdMob config present for swap-readiness, but do not flip provider unless
  explicitly requested.

## Deferred

- Recheck official AppLovin MAX iOS SKAdNetwork requirements before App Store
  release.

## Fixed

- iOS App Open watchdog false-positive (SDK 1.0.19). The lifecycle "foreground =
  hung ad" heuristic in `AppLovinAdapter._scheduleAppOpenTimeoutCheck` is
  Android-only now; on iOS the ad shows while the app stays `resumed`, so it no
  longer force-dismisses at 10s. Verified on iPhone 17 simulator 2026-06-14:
  App Open displayed → `tick #1..#8 (fgHung=false) — re-arming` (past the old
  10s cutoff) → user closed ad → native `👋 hidden` → `dismissed=true` →
  navigate. No `❌ TIMEOUT` force-dismiss. AdMob adapter never had this issue
  (uses native `FullScreenContentCallback`).

### Audit fixes (SDK 1.0.19, 2026-06-14) — all 132 SDK tests pass, analyze clean

Correctness:
- AppLovin reload-after-display-fail no longer stranded by backoff — new
  `AdSlot.beginReload()` bypasses the cooldown window for show-failure refills
  (the load path is healthy); genuine load failures still throttle via
  `beginLoad`. Applied to appOpen/inter/rewarded display-fail paths. Regression
  tests added.
- AdMob `bannerSlot.beginReload()` now runs BEFORE `BannerAd(..)..load()`
  (was after → slot could strand in `loading` on a synchronous fill).
- AdMob App Open now has a 90s hard-cap watchdog (parity with AppLovin) so the
  resume path can't hang if no dismiss callback fires.
- AdMob interstitial/rewarded now expire after 1h (parity with the 4h app-open
  guard) instead of reusing a stale cached ad that fails on show.
- AdMob `onAppResumed` banner reload uses `implicitView` (foldable/split-view).
- `canShowRewardedAd()` vs `vipAutoGrant` mismatch documented.

Policy:
- Interstitial removed from "Start test" (interruptive placement); kept only on
  Stop and navigation transitions.
- VIP is now granted ONLY on a real rewarded `earned==true` — the
  interstitial-as-reward fallback was removed (rewarded-policy compliance).
- Release footgun guards added in `AdManager.initialize`: loud error + assert if
  `dryRun` is on in release, or if AdMob provider ships Google TEST unit IDs.

## Skipped

- Old verification/performance/package-plan reports in `doc/` were removed
  because they described historical states and could mislead current iOS ad
  debugging.

## Ideas

- Add an in-app debug entry to launch AppLovin/AdMob ad inspectors.
- Add a small ad health screen showing SDK init state, loaded slots, consent
  state, VIP state, and last load error.
