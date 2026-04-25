# Changelog

All notable changes to `applovin_admob_sdk` are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.0] - Unreleased

### Added — Architecture
- **Adapter pattern**: `AdProviderAdapter` interface with `AdMobAdapter` and `AppLovinAdapter` implementations. The orchestrator (`AdManager`) is now provider-agnostic.
- **State machine** (`AdSlot` + `AdSlotState`): replaces ~14 hand-managed bool flags. Each ad type has a single source of truth: `idle → loading → ready → showing → cooldown / suspended`.
- `RewardResult` — typed result of `showRewardedAd`, includes `label` and `amount`.
- `BannerListenables` — banner reactive state encapsulated per-adapter.

### Added — Configuration
- `AdConfig.safety: AdSafetyParams` — every safety knob now configurable from your app (caps, throttle, CTR threshold, dryRun).
- `AdConfig.splashMaxDuration: Duration` — SDK-enforced splash timeout (default 8 s).
- `AdConfig.logTagFilter: List<String>?` — only emit logs from selected tags.
- `AdConfig.onLog: AdLogSink?` — pipe SDK logs into Crashlytics / Sentry.
- `AdConfig.vipKeyValidator: Future<bool> Function(String)?` — your VIP key check.
- `AdConfig.vipDialogStrings: VipDialogStrings` — localise the Cupertino redeem dialog.
- `AdLogLevel.error` — between `warning` and `none`.

### Added — VIP system
- `VipManager` — persistent entries, `Duration` expiry, latest-wins conflict, lazy purge.
- `redeemVip(context, key, duration, validator, strings)` — full Cupertino dialog flow (verifying → success / failed).
- `addVip(key, duration)` — headless variant for restore-purchase or scripted tests.
- `revokeVip(key)` / `revokeAll()`.
- `vip.activeListenable`, `vip.activeStream`, `vip.expiresAt`, `vip.entries`.
- Auto-migration of legacy `addVIPMember(gaids)` lists to `VipEntry(year-2099)` on first init.

### Added — Compliance
- `AdConsent { hasUserConsent, isAgeRestrictedUser, doNotSell }` — GDPR / COPPA / CCPA flags.
- `AdManager().setConsent(consent)` — forwards to AppLovin's static privacy methods (`setHasUserConsent`, `setDoNotSell`) and AdMob's `RequestConfiguration` (`tagForChildDirectedTreatment`, `tagForUnderAgeOfConsent`).
- Conservative default: non-personalised ads until the app calls `setConsent`.

### Added — Premium / "xịn sò"
- `Stream<AdEvent>` on `AdManager().events` — `AdLoadEvent`, `AdShowEvent`, `AdClickEvent`, `AdRewardEvent`, `AdRevenueEvent`. Pipe into Firebase / AppsFlyer for LTV tracking.
- `Backoff` — exponential cooldown (`baseMs * 2^failures`, capped at `maxMs`).
- `AdPlacement` — opaque slot identifier with suggested constants (`home`, `shop`, `levelComplete`, …) plus `AdPlacement.custom('foo')`.
- `DebugAdOverlay` — floating debug panel showing realtime SDK state (`kDebugMode` only).
- `RevenuePanel` — simple revenue dashboard widget.
- Memory-pressure handler — drops cached fullscreen ads on `didHaveMemoryPressure`.
- Splash budget enforcement — `AdConfig.splashMaxDuration` auto-fires `markSplashInactive`.

### Changed
- `AdManager` shrunk from 1456 → ~580 LOC (orchestrator only).
- `SafeLogger` overloaded to accept lazy `String Function()` — zero CPU cost when level is suppressed.
- Banner widget refactored to provider-agnostic via `BannerListenables`.
- All `late` / `!` / `setState` removed from SDK code (per integration policy). Reactive state uses `ValueNotifier`.

### Fixed
- **ML1** — `Future.delayed` 10 s timeout in App-Open show converted to cancellable `Timer` that drops on `destroy()`.
- **ML2** — App-Open-on-resume fallback delay converted to cancellable `Timer`.
- **ML3** — AppLovin native listeners (`setAppOpenAdListener` etc.) cleared in `destroy()` so closures don't pin the singleton.
- Several historical race conditions (Fix #1, #4, #36, #42, #46, #48) are now eliminated by design through `AdSlot` state-machine transitions.

### Removed
- `lib/ad_sdk.dart` duplicate barrel — use `package:applovin_admob_sdk/applovin_admob_sdk.dart`.

### Deprecated (will be removed in 3.0)
- `AdManager().addVIPMember(List<String> gaids)` — use `AdManager().vip.addVip(key:, duration:)`.
- `AdManager().deleteVIPMember(List<String> gaids)` — use `AdManager().vip.revokeVip(key)`.
- `SafeLogger.setEnabled(bool)` / `setVerbose(bool)` — use `SafeLogger.configure(level: AdLogLevel.x)`.

### Migration
See `MIGRATION.md` for a step-by-step 1.x → 2.x guide.

---

## [1.0.14]

### Bug Fixes
- **Fix #48** — `_assertInitialized` no longer throws; returns `bool` with warning log. All call sites now gracefully early-return when the SDK is not yet initialized.
- 47 prior numbered fixes (Fix #1 through Fix #47) — see git history for individual entries. Production-hardened single-file `AdManager` baseline with 12-layer safety.
