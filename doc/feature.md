# Feature Status

Updated: 2026-06-14

## Implemented

- WiFi stress test core flow.
- History/detail/statistics screens.
- VIP screen and SDK VIP integration.
- Android ad integration with `applovin_admob_sdk ^1.0.18`.
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
- App consumes the SDK via local `path: packages/ad_sdk` while the redesign is
  in flight (hosted `^1.0.18` line commented). Revert + bump to `^1.0.19` after
  publishing.

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

### Audit fixes (SDK 1.0.19, 2026-06-14) — all 108 SDK tests pass, analyze clean

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
