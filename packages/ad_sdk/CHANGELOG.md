# Changelog

All notable changes to `applovin_admob_sdk` are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.19] - 2026-06-14

### Added — iOS App Tracking Transparency
- **`AdManager().requestAtt()`** / **`requestAttIfNeeded()`** — show the iOS ATT
  prompt when needed and return a structured `AttResult { status, idfa,
  allowsTracking }` (`AttStatus` enum). No-op on Android; never throws (degrades
  to `denied`). Call it in the splash **before** `requestUmpConsent`. Requires
  `NSUserTrackingUsageDescription` in `Info.plist`. Decoupled from the GDPR
  consent flag — the native SDKs read ATT directly for IDFA.

### Fixed
- **iOS App Open watchdog false-positive** — the lifecycle-aware show timeout no
  longer force-dismisses on iOS, where the ad shows while the app stays
  `resumed`. The "foreground = hung" heuristic is now Android-only; iOS relies on
  the native hidden/displayFailed callbacks plus the 90 s hard cap.
- **AppLovin reload-after-display-fail** — a slot is no longer stranded by the
  backoff window after a *show* failure; it refills immediately via the new
  `AdSlot.beginReload()` (genuine load failures still back off).
- **AdMob parity** — App Open now has a 90 s show watchdog; interstitial/rewarded
  honour a 1 h freshness expiry; the banner slot transitions to `loading` before
  the native `BannerAd` is created (fixes a synchronous-fill race).

### Internal
- Both adapters now load through an injectable bridge (`AppLovinBridge` /
  `GmaBridge`) for full behavioural unit-test coverage. No public-API change.

### Compliance / docs
- Removed the rewarded→interstitial reward fallback (rewarded-policy compliance);
  removed the interstitial on "Start" actions in the example host.

Upgrading from 1.0.18 requires no code changes for existing integrations. To use
ATT, add `NSUserTrackingUsageDescription` and call `AdManager().requestAtt()`.

## [1.0.18] - 2026-04-27

### No code changes
- Version bump only. Runtime behaviour, public API surface, and bundled
  assets are identical to 1.0.17. Upgrading from 1.0.17 to 1.0.18
  requires no code changes — only a `pubspec.yaml` version bump and
  `flutter pub get`.

## [1.0.17] - 2026-04-27

### Added — Anti-uninstall-bypass for first-install VIP grace (iOS-side)
- **`FirstInstallGuard`** (internal, `lib/src/vip/_first_install_guard.dart`) —
  protects the `firstInstallVipGrace` feature against the trivial bypass
  of "uninstall + reinstall to claim a fresh 24-hour grace window."
  Wired automatically inside `AdManager.initialize`; host apps need no
  code changes.
- **iOS defence** — writes a single boolean flag to the iOS Keychain
  (`kSecAttrAccessibleAfterFirstUnlock`, no `synchronizable`, no
  `kSecAttrAccessGroup`). Keychain entries persist across app uninstall
  by default on iOS, so a reinstall on the same device finds the flag
  and the guard skips re-granting. Deliberately uses a constant flag
  rather than `identifierForVendor` (IDFV) — Apple resets IDFV when the
  user deletes all of a vendor's apps and reinstalls, which would let
  a standalone-app reinstall silently bypass the guard.
- **Android defence (host-app responsibility)** — there is no reliable
  local-only Play Install Referrer signal that distinguishes a fresh
  install from a reinstall (per Google's docs, referrer info is reset
  when the application is reinstalled). Real Android anti-bypass relies
  on the host app's **Auto Backup** configuration restoring
  `FlutterSharedPreferences.xml` (which contains the
  `prefs.isFirstInstallGraceApplied()` flag) on Play Store reinstall,
  short-circuiting the outer grace block before the guard runs. The
  guard itself returns `false` (allow grace) on Android — anti-bypass
  is performed entirely by the host's `AndroidManifest.xml` /
  `<data-extraction-rules>` + Google Cloud Backup.
- **Call-order guarantee (iOS)** — `AdManager` writes the Keychain
  anti-bypass flag *before* the `prefs.markFirstInstallGraceApplied()`
  flag, so a process kill between the two writes leaves the persistent
  marker set and the next install on the same device is still blocked.
- **Debug bypass** — `kDebugMode` builds skip both `hasAlreadyGranted`
  and `markGranted`, so QA can iterate on `flutter run` without the
  Keychain signal locking them out of the grace UX. Anti-bypass
  validation must happen on signed release builds (TestFlight / Play
  Store internal track).
- **Fail-open philosophy** — every storage error is caught and logged;
  the guard returns `false` (allow grace) so a transient Keychain
  hiccup never denies grace to a legitimate first-time user.
- **15 new unit tests** covering debug bypass, Keychain present/absent/
  tampered/error, Android always-grant behaviour, `markGranted`
  no-op on Android, idempotency, and fail-open error swallowing.

### Changed
- New required dependency for the iOS guard:
  - `flutter_secure_storage: ^9.2.4` — iOS Keychain wrapper.
- Approximate binary size delta: +400 KB (Keychain wrapper native code).

### Host-app integration notes
- **Android (required for anti-bypass)** — add Auto Backup configuration
  to `android/app/src/main/AndroidManifest.xml`:
  ```xml
  <application
      android:allowBackup="true"
      android:dataExtractionRules="@xml/data_extraction_rules"
      android:fullBackupContent="@xml/full_backup_content">
  ```
  Create `android/app/src/main/res/xml/data_extraction_rules.xml`
  (Android 12+) and `full_backup_content.xml` (Android 6-11) including
  `FlutterSharedPreferences.xml` so Google Auto Backup restores the
  grace flag on Play Store reinstall.
  Without these, **Android anti-bypass does not work** — uninstall +
  reinstall always re-grants the grace window. (Acceptable for many
  apps; configure Auto Backup only if you want to block this bypass.)
- **iOS** — no host-side configuration required.

### Removed
- **`play_install_referrer` dependency** — initially included for an
  Android conservative-skip path, removed after research confirmed
  Install Referrer cannot detect Play Store reinstall (timestamps
  reset per Google's documented behaviour). Real Android anti-bypass
  comes from Auto Backup, not Install Referrer.

### Limitations (documented, not fixed)
- **iOS factory reset** ("Erase All Content and Settings") wipes
  Keychain → bypass succeeds. Acceptable; factory resets are rare.
- **Android Play Store reinstall without Auto Backup or within Auto
  Backup's ~24 h cache window** still bypasses the guard. This is a
  fundamental local-only limitation — closing it requires a backend
  (Firebase Anonymous Auth + Firestore, or a custom server).
- **iOS encrypted backup restore to a new device** could carry the
  Keychain flag onto the new device, denying that device's first
  install grace. Edge case; acceptable trade-off vs. weakening
  anti-bypass on the primary device.

## [1.0.16] - 2026-04-26

### Documentation
- **Full English rewrite of `README.md`** — restructured into 13 sections
  with table of contents. Quick start expanded into 6 copy-paste steps
  any Flutter developer can follow without prior AdMob/AppLovin knowledge.
  Added complete public API reference, FAQ, and dedicated Pitfalls section
  covering the `android:taskAffinity=""` issue (the most common cause of
  perceived crashes during background → foreground ad cycles).
- **Full English rewrite of `MIGRATION.md`** — clear 1.0.14 → 1.0.15
  upgrade path (no breaking changes), plus legacy 1.x → 2.x path with
  auto-migration details. Added Common issues and FAQ sections.
- **Full English rewrite of `doc/architecture.md`** — deep-dive for
  contributors and advanced integrators. Added detailed sections on the
  Smart App-Open timeout, Slot-state dismiss watcher, Consent flow
  sequence, Memory management contract, and Manifest pitfalls.

### No code changes
- This is a documentation-only release. The runtime behaviour, public
  API surface, and bundled assets are identical to 1.0.15. Upgrading
  from 1.0.15 to 1.0.16 requires no code changes — only a `pubspec.yaml`
  version bump and `flutter pub get`.

## [1.0.15] - 2026-04-26

### Fixed
- **AppLovin App-Open timeout false-positive** — old fixed 10 s timeout fired
  while user was still interacting with the ad (click → browser → return),
  marking dismiss with `false` and arming the resume guard prematurely.
  Replaced with lifecycle-aware polling: re-arms every 5 s while app is
  paused (= ad still showing), force-dismisses only when app is foreground
  for 2 consecutive ticks without `onAdHiddenCallback` (hard cap 90 s).
- **Banner paid-event not wired** — `BannerAd` extends `AdWithView` which
  has no `onPaidEvent` setter; previous dynamic dispatch silently failed.
  Banner revenue is now correctly emitted via `BannerAdListener.onPaidEvent`
  constructor parameter.
- **App-open shown immediately after rewarded dismiss** — `_lastFullscreenDismissAt`
  was recorded inside the rewarded `onDone` callback which fires on
  reward-earned (mid-video), not on actual dismiss. Replaced with slot-state
  watchers that fire on `showing → !showing` transition for all 3 fullscreen
  slots — authoritative dismiss timestamp regardless of adapter quirks.
- **VIP grace not auto-expiring mid-session** — added `Timer` in `VipManager`
  scheduled for the soonest `expiresAt`. Fires `_purgeExpired` + `_refreshActive`
  when an entry expires, so the SDK reflects VIP loss without requiring a
  full re-init. Especially relevant for short debug grace windows.
- **Inter/rewarded/app-open not preloaded after VIP expires mid-session** —
  added listener on `VipManager.activeListenable`; on `true → false` flip,
  triggers `loadAppOpenAd + loadInterstitial + loadRewardedAd + preloadBanner`
  so the user doesn't see "ad not ready" on first show after losing VIP.
- **`canShowFullscreenAd` / `canShowAppOpenOnResume` reported "wait 0s"** —
  sub-second waits truncated to 0. New `_fmtWait(ms)` helper renders ms when
  < 1 s ("wait 645ms") and 1 decimal seconds otherwise ("wait 1.5s").
- **Splash budget warning fired while splash app-open ad still showing** —
  `_armSplashBudget` now detects `appOpenSlot.isShowing` on first elapse
  and re-arms a 30 s hard cap instead of force-firing `markSplashInactive`.
- **`canShowAppOpenOnResume` returned `bool`** — refactored to return
  `AdSafetyResult` (canShow + reason), aligning with `canShowFullscreenAd`.
  Callers can log the specific block reason + remaining wait time.

### Added — Consent flow
- **`ConsentManager`** — standalone helper class owning the Cupertino consent
  dialog UI, persistence (`SharedPreferences`), and provider apply pipeline.
  Accessible via `AdManager().consentManager` or `ConsentManager.instance`.
- `ConsentSettings` — persistent user-choice record with `hasBeenAsked`,
  `askedAt`, JSON serialisation.
- `ConsentDialogStrings` — localisation, includes `ConsentDialogStrings.vi`
  for Vietnamese.
- Custom binary Cupertino dialog (Allow / Reject) with hero icon, gradient
  Allow button, accent colours, scale-in animation, haptic feedback.
- `AdConfig.autoShowConsentDialog` (default `true`) — SDK auto-presents the
  dialog ~1 s **after** `markSplashInactive` (post-splash, on home), not
  during splash flow. Skipped for VIP users.
- `AdConfig.consentDialogPostSplashDelay` (default 1 s) — tunable.
- `AdConfig.consentBarrierDismissible` (default `false`).

### Added — UMP (User Messaging Platform) wrapper
- `requestUmpConsentFlow(testMode, debugGeography, testIdentifiers, …)` —
  wraps Google's built-in `ConsentInformation` + `ConsentForm` (no extra
  dependency, available since `google_mobile_ads` 6.x).
- `AdManager().requestUmpConsent(…)` — auto-applies UMP result to providers.
- Re-exports `ConsentStatus` and `DebugGeography` from `google_mobile_ads`
  so callers don't need a direct import.

### Added — First-install VIP grace
- `AdConfig.firstInstallVipGrace: FirstInstallVipGrace` (default `auto` =
  30 s in debug, 24 h in release) — auto-grants a one-time VIP entry on the
  very first SDK init for this install. Improves D1 retention by giving
  the freshly-installed user an ad-free first session.
- `FirstInstallVipGrace` class with `auto` / `disabled` / `day` /
  `debugShort` presets and custom `Duration` constructor.
- `AdConfig.firstInstallVipKey` (default `__FIRST_INSTALL__`) — VIP entry
  key for analytics discrimination.
- `AdPreferences` — new keys `_keyFirstInstallApplied` (one-shot guard)
  and `_keyFirstInstallAt` (epoch-ms install timestamp for analytics).

### Added — Diagnostic logging
- `🚀 AdManager singleton CREATED` marker fires once per process on cold
  start. Two markers in the same logcat session = Android killed and
  restarted the process.
- `🚨 lifecycle DETACHED` warning when Flutter engine tears down.
- Lifecycle observer logs full state (prev → current, slot states, VIP
  flag, splash flag, backgrounded duration) — wrapped in `_safeLifecycleLog`
  so a closure-evaluation throw cannot abort the observer.
- All ad-load/show paths emit explicit `⏭️ skipped — <reason>` logs for
  every gate (adapter null, VIP, no network, slot showing, safety reason)
  instead of returning silently.
- AppLovin `onAdDisplayedCallback` extended with `network`, `creativeId`,
  `placement`, `latencyMillis` for revenue diagnosis.
- Memory-pressure log throttled to 60 s/event so fast bg/fg cycles
  don't flood the buffer; payload includes banner state and VIP flag.
- `DebugAdOverlay` — new `enabled` constructor flag plus static
  `globallyVisible` `ValueNotifier` for runtime toggle (e.g., from a
  shake-menu or dev console).

### Added — Misc
- `AdConfig.autoShowConsentDialog` skip path also covers the case where
  the user redeems a VIP key during the 1 s post-splash schedule window
  (re-checked at fire time).
- `AdManager.processStartedAtMs` getter.

### Changed
- `loadInterstitial` / `loadRewardedAd` / `loadAppOpenAd` / `showInterstitial`
  / `showRewardedAd` / `showAppOpenAd` skip-path logs now name the specific
  reason (adapter null vs VIP vs no network vs already showing vs safety).
- Banner preload during VIP active is now skipped at AdManager level —
  saves a network request and avoids inflating internal impression counter.

### Notes for integrators
- **Activity manifest**: do **not** set `android:taskAffinity=""` on your
  `MainActivity` when using AppLovin. With empty affinity, AppLovin's
  `AppLovinFullscreenActivity` lands in a different Android task; after
  user backgrounds + foregrounds and dismisses the ad, the task may be
  empty and the user is dropped to launcher. Default affinity (= package
  name, by simply omitting the attribute) is safe.

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
