# Changelog

All notable changes to `applovin_admob_sdk` are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Docs
- Added a "Known limitations — read before adopting" section to the README
  (ad-policy risk sits with AppLovin/Google, not this package; the real
  ad show/dismiss lifecycle is only partially automatable — 3/15
  integration_test scenarios are manual-only; limited real-world production
  history beyond this repo's own host app; single maintainer, no SLA).
  Written for anyone evaluating this SDK for a new app/partner before a
  wholesale integration.

## [1.0.24] - 2026-07-10

### Added — durable redeemed-key ledger for signed VIP keys on iOS
- New `RedeemedKeyLedger` (`lib/src/vip/_redeemed_key_ledger.dart`) backs
  `VipManager.redeemSignedKey`'s one-time-use check with an iOS Keychain
  entry, alongside the existing `AdPreferences` (SharedPreferences) check.
  `AdPreferences` alone is wiped on uninstall, so a user could
  uninstall/reinstall to redeem the same signed key repeatedly; the Keychain
  entry survives that. Android intentionally has no durable backstop here,
  same reasoning as the existing `FirstInstallGuard` (no local primitive
  survives uninstall without an install-referrer plugin for a narrow
  benefit) — `AdPreferences` remains the sole check there. Fails open: any
  Keychain read/write error is swallowed and treated as "not redeemed" so a
  storage hiccup never locks out a legitimate key. Test:
  `test/redeemed_key_ledger_test.dart`.

### Added — VIP grace-period expiry nudge
- `VipManager` exposes `graceNudgeThreshold` (default 24h),
  `graceNudgeDueListenable`, and `acknowledgeGraceNudge()`. Once a VIP
  entry's `expiresAt` comes within the threshold, the nudge notifier flips
  true so the host UI can prompt the user to redeem/extend before ads
  resume; acknowledging persists the current `expiresAt` so the same expiry
  doesn't re-nudge, but stacking a new expiry (redeem/watch-ad-to-extend)
  makes it due again. Inactive/no-VIP state is never due. Test:
  `test/vip_manager_grace_nudge_test.dart`.

### Added — VIP entries integrity checksum
- `AdPreferences.getVipEntriesRaw()`/`setVipEntriesRaw()` now store an
  FNV-1a checksum alongside the VIP entries JSON, as a single combined
  `SharedPreferences` value (`'<checksum>|<json>'` written via one
  `setString` call). A mismatched checksum is logged and treated as absent
  data, deterring casual on-device editing of the plaintext VIP entries to
  self-grant free ad-free time — this is a tamper *deterrent*, not
  root/jailbreak-proof protection (a rooted device can still recompute the
  checksum). Pre-upgrade data with no checksum is trusted once and
  backfilled into the new format. FNV-1a was chosen over `String.hashCode`
  (not stable across Dart/Flutter versions) and over the existing async
  `cryptography`-package HMAC (would force every VIP-entries caller async).
  Note: an earlier two-separate-keys design was replaced with the single
  combined key above after it surfaced a real race — a concurrent
  fire-and-forget `VipManager._save()` write could be observed mid-flight
  with one key updated and the other still stale, causing a false
  "tampered" read. Test: `test/ad_preferences_test.dart`.

### Changed — native ad SDK dependency pins retested, still blocked upstream
- Retested bumping `applovin_max`/`gma_mediation_applovin` to the latest
  upstream versions (`4.6.4`/`2.6.1`) to see whether the CocoaPods
  version-pin conflict documented in the host `pubspec.yaml`
  `dependency_overrides` had been resolved. It has not: `2.6.1` now
  requires `meta ^1.17.0`, while `flutter_test` from the CI-pinned Flutter
  SDK (3.35.1) forces `meta 1.16.0` — a Dart-level version-solve conflict,
  never even reaching the CocoaPods layer. No SDK code change; the pins
  stay at `applovin_max 4.6.0` / `google_mobile_ads 6.0.0` /
  `gma_mediation_applovin 2.5.1` in the host app. See
  `doc/audit/audit_partner_lead_20260710.md` findings #2/#3.

### Added — Privacy Options footer button on VipRedeemScreen (T28)
- `VipRedeemScreen` gained `onPrivacyOptionsTap` (`VoidCallback?`) and
  `VipRedeemStrings.privacyOptions`, mirroring the existing
  `onPrivacyPolicyTap`/`privacyPolicy` pair. The footer now renders whichever
  of the two buttons has a non-null callback (previously only the privacy
  policy button existed). Closes the gap where `AdManager().showPrivacyOptions()`
  (T06) had no host call site — GDPR requires a durable re-consent entry
  point, not just a one-time policy link. Test: `test/vip_redeem_screen_test.dart`
  (footer hidden/shown/tap cases for `onPrivacyOptionsTap`).

### Added — rewarded disclosure hook on `AdScreenState.showRewardedAd` (T22)
- `showRewardedAd` gained optional `disclosureTitle`/`disclosureSubtitle`/
  `disclosureButtonLabel`/`disclosureCancelLabel` params. When
  `disclosureTitle` is set, a confirm dialog naming the reward is shown right
  before the ad plays; declining calls `onEarnedReward(false)` and never
  reaches the ad. Omitted (default): behaviour is unchanged — return type
  changed `void` → `Future<void>`, non-breaking via Dart's void-return
  covariance. Test: `test/ad_screen_test.dart` (`rewarded disclosure hook`
  group — confirm/cancel paths).

### Added — load-time daily safety cap gate (T21)
- `AdSafetyConfig.dailyCapReached()` is a new pure read-only check (no
  CTR-anomaly side effects, unlike `canShowFullscreenAd()`). `loadAppOpenAd`/
  `loadInterstitial`/`loadRewardedAd` and the periodic `_retryRefillAds` scan
  now skip preloading once the daily fullscreen-ad cap is hit — previously
  the cap was only enforced at *show* time, so a capped-out user kept
  burning ad-network load requests that could never convert. VIP members are
  unaffected (the existing VIP guard already returns before this check runs
  in every call site). Test: `test/daily_cap_load_gate_test.dart`,
  `test/ad_safety_config_test.dart` (`dailyCapReached` group).

### Fixed — trial hardening: anti clock-rollback + grace-disabled footgun (T17)
- `VipEntry.isActive`/`remaining` now also check `now.isBefore(grantedAt)` —
  previously only `now.isBefore(expiresAt)` was checked, so rolling the
  device clock backwards past a grant's `expiresAt` made an
  already-expired-by-real-time entry "come back to life". A rolled-back
  clock is now treated as the entry having already been consumed
  (fail-safe), not as extra time granted. `VipManager`'s purge/active/
  stacking logic needed no change — everything already routes through
  `VipEntry.isActive`. Test: `test/vip_entry_test.dart` (`anti
  clock-rollback (T17)` group).
- `AdManager.releaseFootgunWarnings` now also warns (release builds only,
  same log-ERROR + `assert(false, ...)` treatment) when
  `AdConfig.firstInstallVipGrace` is `.disabled` — previously a partner
  could silently ship with no ad-free first-install trial. Test:
  `test/ad_manager_core_test.dart` (`firstInstallVipGrace` cases in the
  `releaseFootgunWarnings` group).

### Added — ad-unit-id validation in release footguns (T16)
- `AdManager.releaseFootgunWarnings` now also warns (release builds only,
  same log-ERROR + `assert(false, ...)` treatment as the existing dryRun/
  Google-test-id guards) when: any resolved `bannerId`/`interstitialId`/
  `appOpenId`/`rewardedId` is empty, or (AdMob provider only) an id doesn't
  match AdMob's `ca-app-pub-<16 digits>/<ad-unit id>` format — the classic
  "pasted an AppLovin id into the AdMob config" mistake. Test:
  `test/ad_manager_core_test.dart` (`releaseFootgunWarnings` group).

### Added — per-platform ad-unit ids (T15)
- `AdMobConfig`/`AppLovinConfig` gained optional `android*Id`/`ios*Id`
  overrides for `bannerId`/`interstitialId`/`appOpenId`/`rewardedId` (e.g.
  `androidBannerId`, `iosBannerId`). Resolved via `Platform.isAndroid`/
  `Platform.isIOS` at read time, falling back to the existing single id when
  no override is set — fully backward compatible. Test:
  `test/ad_config_platform_test.dart`.

### Added — Privacy Options entry point + re-consent (T06)
- `AdManager().isPrivacyOptionsRequired()` and `AdManager().showPrivacyOptions()`
  (wrapping `ConsentInformation.getPrivacyOptionsRequirementStatus` +
  `ConsentForm.showPrivacyOptionsForm`) are now documented in the README as the
  **required durable re-consent entry point** Google's UMP policy mandates
  (a permanent "Privacy Settings" button). `showPrivacyOptions()` safely no-ops
  (no native UI) when Google doesn't require it for the current user, and
  re-applies the resulting consent to the active ad provider (npa/RDP) when it
  does. Test: `test/privacy_options_test.dart` — required→opens form,
  notRequired→no-op, re-consent re-applies to the active adapter.

### Added — shared `VipRedeemScreen` widget
- Extracted the full VIP redeem screen (hero status, key input, watch-ad-extend,
  active-entries list, buy placeholder, confetti) into the SDK as a reusable
  `VipRedeemScreen` + `VipRedeemStrings` (localizable, mirrors the
  `ConsentDialogStrings` pattern). The host and the SDK example now render the
  **identical** screen — host injects Vietnamese strings, the example uses the
  English defaults. Privacy-policy opening is a callback (`onPrivacyPolicyTap`)
  so the SDK needs no `url_launcher` dependency; `confetti` is added.
- Widget tests: renders inactive state + privacy-footer visibility. Verified on
  a Samsung S24 Ultra.

### Fixed — code-review follow-ups
- VIP: `redeemSignedKey` now claims the key id **atomically** (synchronous
  check + in-flight set) so a concurrent double-tap of the same signed key can't
  slip past the one-time-use check and grant twice. Enforced in the SDK, not
  just the host UI. Test: concurrent double-redeem grants exactly once.
- Consent: `initialize()` logs a **loud runtime warning** when AppLovin's CMP is
  disabled AND `autoRequestUmpConsent` is false AND `requestUmpConsent()` was
  never called before init — the "no consent form anywhere" footgun. Runtime,
  not config-static, so it never false-alarms hosts that gather consent in
  their splash.

### Improved — offline/network UX (T09 + T10)
- T09: verified the banner **collapses** to a zero-size box when offline (no
  shimmer / battery drain) and **reloads automatically on reconnect** (via the
  T08 connectivity watch bumping `initRevision`). Added a widget test.
- T10: `isConnected` now falls back to the **last-known** connectivity state
  (from the T08 watch) with a warning log instead of a silent `true` when the
  detector is unavailable. Kept optimistic on purpose — a broken detector must
  not permanently block ads; genuine offline loads just fail and back off, and
  the watch refills on reconnect (network-error fast-retry is subsumed by T08).

### Hardened — lifecycle & memory (T11 + T12 + T13)
- T13: `AdLoadingDialog.resetState()` (called by `AdManager.destroy()`) now pops
  a still-showing dialog before clearing its flags, so a mid-dialog destroy /
  re-init can't strand a non-dismissable loading dialog on the navigator.
  (`_eventStream` is intentionally left open — it's a process-lifetime singleton
  broadcast exposed publicly; closing it would break host subscribers and it is
  bounded to one instance, so it is not a leak.)
- T11: added regression tests proving the fullscreen single-use guard — a
  second show while one is showing is rejected by the slot state machine
  (`isReady` + atomic `beginShow` + null-on-dismiss), a disposed ad is never
  re-shown, and dispose happens exactly once. (No code change needed; the guard
  already existed — the tests lock it down.)
- T12: `BannerAdWidget` now guards against stacking multiple post-frame
  `_initBanner` callbacks (`_initScheduled`) when `build` runs repeatedly, so a
  banner loads exactly once across rebuilds. (`loadBannerIfNeeded` already
  bailed on a cached ad; this removes the wasteful callback pile-up.)
  (dispose-before-recreate was already handled by that early-return.)

### Added — consent gate + UMP as single CMP (T01 + T03)
- **`AdManager.canRequestAds`** consent gate: every load path (app-open,
  interstitial, rewarded, banner) AND every show path now skips when consent
  hasn't been granted, mirroring Google UMP's `ConsentInformation
  .canRequestAds()`. `requestUmpConsent` stores the result and, when the gate
  opens (blocked→allowed), refills the held slots. Google policy: never request
  or show an ad while `canRequestAds` is false. Defaults `true` so non-UMP /
  non-EEA hosts are unaffected.
- **`AdConfig.autoRequestUmpConsent`** (default false): when true,
  `initialize()` runs UMP before the first ad request and gates on the result —
  the SDK owns the whole consent flow. `umpTagForUnderAgeOfConsent` forwards the
  under-age flag.
- **`AdConfig.disableAppLovinCmpFlow`** (default true): the AppLovin adapter
  disables AppLovin's own Terms & Privacy (CMP) flow so UMP is the single
  consent prompt — no double prompt. UMP's result is still forwarded to AppLovin
  via `setHasUserConsent`.
- **T03**: the splash App Open ad (even `bypassSafety: true`) no longer shows an
  impression before consent is resolved; the show gate also prevents a
  previously-loaded ad from showing after consent is revoked.

### Added — offline signed VIP keys (T18)
- New `verifySignedVipKey` + `VipManager.redeemSignedKey` verify Ed25519-signed
  keys **offline** against an embedded public key. Only the public key ships, so
  a decompiler cannot forge new keys (the old local base64 map could be extracted
  and reused infinitely). VIP duration is encoded in the key.
- Per-device one-time-use: a redeemed key id can't be redeemed again on the same
  device (`AdPreferences` redeemed-id store). Global one-time-use still needs a
  server — documented as a known offline limitation.
- New deps: `cryptography` (pure-Dart Ed25519). Tooling: `tool/vip_keygen.dart`
  (generate a key pair) and `tool/vip_mint.dart` (mint signed keys with the
  private key — never shipped). See README → "Signed VIP keys".
- Host `vip_keys.dart` now holds only the public key + demo keys; `vip_screen`
  redeems via `redeemSignedKey`.

### Added — connectivity auto-refill on reconnect (T08)
- The SDK now initialises `ConnectionNotifierTools` (nobody did before, so
  `isConnected` silently always returned `true` and the offline guards never
  fired) and subscribes to `onStatusChange`.
- On an offline→online transition the SDK refills idle/cooldown ad slots,
  nudges the banner preload, and bumps `initRevision` so banner widgets re-init
  — within ~1s (debounced) instead of waiting up to 5 min for the poll timer.
  Suppressed for VIP members and while uninitialised. Subscription cancelled on
  `destroy`. Test seams: `debugConnectivityChanged`, `debugReconnectDebounce`.

### Fixed — AdMob non-personalized ads (`npa`) now actually applied (T02)
- Previously `applyConsentToProviders` only set AdMob's global
  `RequestConfiguration` (COPPA/age tags) and never attached the per-request
  non-personalized flag, so a user who declined consent could still be served
  **personalized** AdMob ads. The doc comment claimed an `npa` extra was
  forwarded, but no code did so.
- `AdProviderAdapter` gains `applyConsent(AdConsent)`. `AdMobAdapter` maps
  `!hasUserConsent` → `AdRequest(nonPersonalizedAds: true)` on **every** load
  (banner, interstitial, rewarded, app open); it defaults to non-personalized
  until consent is applied and resets to that on `dispose`. `AppLovinAdapter`'s
  implementation is a no-op (it forwards consent via static `AppLovinMAX` APIs).
- `AdManager` calls `applyConsent` on the adapter at init, from `setConsent`,
  and on any `ConsentManager` change (auto dialog / set / reset / privacy
  screen), so personalization tracks consent across every path.
- Tests: adapter-level npa propagation + AdManager wiring (integration) +
  UI-driven consent (widget). Example app shows a live "personalized vs
  non-personalized" indicator on the Consent page.

## [1.0.23] - 2026-06-15

### Changed — App Open ad never stacks on top of a modal
- `AdScreenRouteLogger` now tracks how many `PopupRoute`s (dialogs, bottom
  sheets, Cupertino popups) are on the navigation stack and exposes
  `AdScreenRouteLogger.isDialogOnTop`. `showAppOpenAdOnResume` consults it (plus
  `AdLoadingDialog.isShowing`) and **skips the App Open ad while any dialog is
  presented** — e.g. the consent dialog or a VIP redeem confirmation. Showing a
  fullscreen ad over a modal is bad UX and an AdMob policy risk. The counter is
  reset by `AdManager.destroy()` so a mid-dialog teardown can't wedge it.

### Fixed — retry-refill scan bails early for VIP members
- `_retryRefillAds` now returns immediately when the user is a VIP member.
  Each `load*()` already guarded on VIP, so behaviour is unchanged, but this is
  a defense-in-depth backstop and avoids a pointless periodic scan/log.

## [1.0.22] - 2026-06-15

### Added — VIP time stacking + rewarded-while-VIP
- `VipManager.addVip` and `redeemVip` gained a `stack` flag (default `false`,
  fully backward compatible). With `stack: true`, the grant **accumulates onto
  the latest expiry across ALL active entries** (global stacking) — so VIP time
  from every source (redeem code, watch-ad) adds to one growing window (e.g. ~6
  active days + a 30-day code ⇒ ~36 days). The granted key's entry becomes the
  new latest (created if new, updated if it existed) and `grantedAt` resets to
  now. Without `stack`, the default latest-expiry-wins replacement is unchanged.
- `AdManager.showRewardedAd` gained a `bypassVipGuard` flag (default `false`).
  When `true`, a VIP member can voluntarily watch a **real** rewarded ad (e.g. to
  extend their own VIP window). Since the rewarded slot is not preloaded while
  VIP, the SDK loads it on demand and waits before showing. No auto-grant — the
  reward is still only earned by completing the ad. Policy-compliant (a real ad
  is shown).
  - On-demand load observes the slot's **public** `AdSlot.state` notifier (not
    the internal `pendingCallback`), with a caller-tunable `onDemandLoadTimeout`
    (default 15 s) param on `showRewardedAd`.
  - A blocking `AdLoadingDialog` covers the on-demand wait (new
    `AdLoadingDialog.show()` / `dismiss()` non-timed pair).
  - `showRewardedAd` is now **re-entrancy-safe**: a second call while a first is
    mid load/show is rejected (`onEarnedReward(false)`), independent of any
    caller-side lock.
- `AdConfig.maxVipStackDuration` (default `null` = uncapped) — optional cap on
  the **total** window produced by stacking. When set, a stacked grant is clamped
  to `now + maxVipStackDuration`. Plumbed to `VipManager` at init.

### Tests
- +24 tests (222 total). `vip_manager_stacking_test.dart` (13 — global stacking
  incl. cross-key + order-independence, cap clamp, persistence, notifier,
  watch-ad fixed-key); `rewarded VIP-bypass` group in `ad_manager_core_test.dart`
  (6 — default vs. bypass, on-demand success/failure, non-VIP, re-entrancy guard);
  `rewarded_ondemand_dialog_test.dart` (2 widget — cold-VIP loading dialog during
  async on-demand load + timeout dismissal).

## [1.0.21] - 2026-06-15

### Changed — dependency refresh
- `google_mobile_ads` `^6.0.0` → `^7.0.0`, `flutter_secure_storage` `^9.2.4` →
  `^10.0.0`, `applovin_max` `^4.6.3` → `^4.6.4`. No public-API change; all 132
  tests pass. (Bumping `google_mobile_ads` to 8/9 requires Dart ≥3.10 / a newer
  Flutter, so 7.x is the current ceiling; `connection_notifier` is kept at
  `^2.0.1` because `^4` pulls `connectivity_plus 7`, which conflicts with hosts
  on `connectivity_plus 6`.)
- Dropped the deprecated `encryptedSharedPreferences` AndroidOptions flag
  (flutter_secure_storage 10 auto-migrates).

### Example
- Interstitial demo now passes `placement: AdPlacement.levelComplete` to show
  per-placement revenue tagging; VIP demo documents the `AdConfig.vipDeviceGaids`
  allow-list + `isVIPMember()`.

## [1.0.20] - 2026-06-14

### Example only
- The bundled example (`example/lib/main.dart`) now demonstrates the recommended
  consent ordering in its splash: `AdManager().requestAtt()` →
  `AdManager().requestUmpConsent()` → `AdManager().initialize()`. No library /
  public-API change vs 1.0.19 — upgrading requires nothing.

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
