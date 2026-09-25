# Changelog

All notable changes to `applovin_admob_sdk` are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

- **Changed (T173 hardening):** `BannerAdWidget` now checks the adapter capability
  `BannerErrorSelfCollapse`/`AdManager.collapsesBannerOnError` instead of
  hardcoding the AdMob provider when distinguishing internal banner error
  self-collapse from real external invisibility. AdMob opts in; AppLovin and
  custom adapters keep the safe default (`false`).
- **Tests:** Added unit/widget coverage for the banner self-collapse capability
  and expanded `gma_bridge_test.dart` to cover production fullscreen wrapper
  show callbacks, rewarded SSV, reward callbacks, and all 4 fullscreen load
  failure callbacks; `gma_bridge.dart` line coverage is now >90%.

## [3.2.1] - 2026-09-25

- **Fixed (T173):** `BannerAdWidget._onVisibilityChanged` distinguished internal
  error self-collapse (`AnimatedSize` height = 0 on `onAdFailedToLoad`) from
  external scroll/navigation invisibility. Keeps errored AdMob banner instances
  registered in `InlineAdInstanceRegistry` so the Debug Overlay retains the
  failed slot count and `needsRecovery` debt is preserved for the resume retry
  scanner. External route push, `TickerMode`, `dispose()`, and manual
  `active: false` remain immediate and continue to dispose cleanly.
- **Fixed (T193):** `AdManager._selfCheckLoad` now checks `slot.isReady` BEFORE
  invoking `load()`. AdMobAdapter validates freshness against its private cached
  native ad object reference rather than the logical slot alone; calling `load()`
  on an already-ready slot could replace a healthy preloaded ad with a network
  request leading to cooldown/no-fill. A health diagnostic must never destroy
  existing ready inventory.
- **Fixed (Integration Tests):** Eliminated first-install 30s VIP grace window
  race conditions in `r173_debug_overlay_banner_row_test.dart` by explicitly
  revoking VIP before testing banner mount, and added preload settling buffer
  in `t193_self_check_already_ready_test.dart` to prevent secondary preload
  completion races during slot state seeding. Verified 100% pass on real device
  (`TECNO BG6`) and iOS Simulator under AdMob.

## [3.2.0] - 2026-09-22

- **Fixed (2026-09-24):** `AdManager.debugShouldSkipRealAppLovinNativeView`
  was marked `@visibleForTesting`, but unlike every other `debug*` seam in
  this file it's genuinely called from production code in a different
  library (`NativeAdWidget`), not just tests — caught by
  `dart pub publish --dry-run`'s `invalid_use_of_visible_for_testing_member`
  warning. Changed to `@internal`, which the existing `test/api_golden_test.dart`
  tooling already treats the same as `@visibleForTesting` for public-API
  purposes.
- **Fixed (2026-09-24):** `round40_readiness_controller_demo_test.dart` —
  `AdReadinessSplashController`'s own splash re-arms for another +30s if a
  real App Open ad is still in flight when its hard-cap would otherwise
  fire (same behavior `AdManager`'s own splash logic has), which this
  test's original 30s wait window didn't cover. Widened to 140s (measured
  4/4 clean real-device runs using ~100-102s with a 100s window — right at
  the edge — before settling on 140s for real margin).
- **Fixed (2026-09-24):** `vip_watch_ad_to_extend_test.dart` and
  `vip_fast_refill_demo_test.dart` both navigated via the "VIP / redeem"
  HomePage tile, which opens `VipRedeemScreen` — a different page entirely.
  The buttons these tests actually need ("Watch ad → +3 days VIP (stack)"
  and "End VIP now") live on `VipDemoPage`, reached via the "VIP API
  playground" tile instead. Neither test had ever been on the right page;
  not a timing issue.
- **Fixed (2026-09-24):** `multi_instance_ad_test.dart` — `BannerDemoPage`
  and `NativeDemoPage` each embed a third, unrelated Banner/NativeAdWidget
  (the "IndexedStack via buildBanner()/... (T153/T154)" examples
  demonstrating the IndexedStack + `active` pattern), so the T65
  multi-instance assertion found 3 instead of 2 — not a leaked
  previous-route instance as first assumed. Now excludes that widget
  (Native's T154 has a `ValueKey`; Banner's T153 doesn't, so it's excluded
  by `IndexedStack` ancestry instead — both need `skipOffstage: false`
  since the non-selected `IndexedStack` branch is offstage).
- **Fixed (2026-09-24):** `t136_waterfall_tuner_persistence_test.dart` was
  never actually reachable — its single `emitRevenue()` call per session
  could never satisfy `recommendation()`'s per-provider
  `otherRevenueSamples >= minSampleSize` gate (a `round-61 audit fix`,
  gated separately from the summed-across-both-providers load-attempt
  check the test's own comment described), so it returned `null`
  regardless of whether persistence worked. Found by first ruling out
  timing (confirmed via a raw-SharedPreferences dump that session A's
  write landed correctly) and a missing `await` on `WaterfallTuner`'s
  documented `ready` future (real fixes, kept, but not the actual cause).
  Also excluded `round37_reload_while_showing_test.dart` from
  `integration-retry.sh`'s full-suite run — its own header says a HUMAN
  must manually tap a real interstitial's close button, same requirement
  as `app_open`/`interstitial`/`rewarded_ad_test.dart`, and actually landed
  the `round37_coppa_hardstop_test.dart` exclusion a prior CHANGELOG entry
  had already claimed but the code edit was missed.
- **Changed (BREAKING):** bumped `google_mobile_ads` from `^7.0.0` to
  `'>=9.0.0 <9.1.0'`, and this package's own environment floor from Flutter
  `>=3.27.0`/Dart `>=3.6.0` to Flutter `>=3.38.1`/Dart `>=3.10.0`. This
  resolves the CocoaPods pinning wall documented in CLAUDE.md — a
  consuming app can now pair `applovin_max ^4.6.4` with
  `gma_mediation_applovin 2.6.2` (or `2.6.3`) directly, no
  `dependency_overrides` hold-back needed. `google_mobile_ads` is pinned
  below `9.1.0` on purpose: that version ships a confirmed upstream iOS
  build regression (non-modular-header Xcode failure from its new Ad
  Preloading API) — verified locally (`flutter build ios --simulator`
  fails on `9.1.0`, succeeds on `9.0.0`). Consuming apps on Flutter
  `<3.38.1` must upgrade Flutter before taking this release. On Android,
  `google_mobile_ads 9.0.0`'s native `play-services-ads 25.3.0` ships
  Kotlin metadata compiled with Kotlin 2.3.0 — a consuming app's own
  Kotlin Gradle plugin must be `>= 2.3.0` (was `2.1.0` in this SDK's
  example app) or `compileDebugKotlin` fails with "Module was compiled
  with an incompatible version of Kotlin"; Kotlin 2.3.0 also removed the
  old `android.kotlinOptions { jvmTarget = ... }` DSL in favor of a
  top-level `kotlin { compilerOptions { ... } }` block.
- **Fixed (2026-09-23):** `multi_instance_ad_test.dart` — `BannerDemoPage`
  and `NativeDemoPage` each embed a third, unrelated Banner/NativeAdWidget
  (the "IndexedStack via buildBanner()/... (T153/T154)" examples
  demonstrating the IndexedStack + `active` pattern), so the T65
  multi-instance assertion found 3 instead of 2 — not a leaked
  previous-route instance as first assumed. Now excludes that widget
  (Native's T154 has a `ValueKey`; Banner's T153 doesn't, so it's excluded
  by `IndexedStack` ancestry instead — both need `skipOffstage: false`
  since the non-selected `IndexedStack` branch is offstage).
- **Fixed (2026-09-23):** a real 30s AppLovin native-ad retry timer
  (`NativeAdWidget._onNativeErrorChanged`, round-38 audit fix) could crash
  when an on-device integration test used a fake `debugAdapterFactory`
  under an AppLovin config — the fake adapter never runs real native
  `AppLovinSdk` init, so the retry's real `MaxNativeAdView` platform view
  NPEs deep inside AppLovin's own native SDK. Added
  `AdManager.debugForceSkipRealAppLovinNativeView` (explicit opt-in,
  guarded like every other `debug*` seam — always off in release) so a
  test can request the real platform view be skipped without inferring it
  from the adapter's type, which would have also affected
  `test/native_ad_widget_test.dart`'s unrelated widget tests. Not reachable
  in production (`debugAdapterFactory` itself is release-blocked).
- **Fixed (2026-09-23):** `.github/scripts/integration-retry.sh`'s
  AppLovin-only-test exclusion regex didn't match
  `r36_real_applovin_appopen_over_banner_test.dart` (a different naming
  shape than the `*_ad_test.dart` files it already excluded), so a full
  local run forcing `AD_PROVIDER_ADMOB=true` would run it by mistake and
  fail on its own self-guard assertion. Also excluded
  `round37_coppa_hardstop_test.dart`, same class of AppLovin-only test.
- **Fixed (2026-09-23):** several `example/integration_test/` files had
  fixed, too-short polling windows (originally sized for CI's emulator)
  for real-device navigation/tile-render timing
  (`r173_debug_overlay_banner_row_test.dart`,
  `gaid_reset_on_destroy_integration_test.dart`,
  `revenue_dashboard_test.dart`, `rewarded_interstitial_ad_test.dart`) —
  widened them. `gaid_reset_on_destroy_integration_test.dart` also had two
  real bugs found via a real-device diagnostic dump of on-screen text: an
  ambiguous two-widget `tap()` (a popped route's AppBar title and
  HomePage's tile briefly share the same exact text mid-transition, same
  root cause already documented in `revenue_dashboard_test.dart` — fixed
  by targeting the tile through its `DemoTile` ancestor instead of a bare
  `.first`), and — the real root cause of the residual ~10-20% flake —
  changing `tester.view.physicalSize` immediately before a `tap()` with
  only one bare `pump()` in between: `getCenter()` can compute the tap
  coordinate against the stale pre-resize layout on a real device, silently
  landing on empty space instead of throwing. Fixed with a few
  duration-pumps to let the relayout settle first. Verified with 20
  consecutive clean real-device runs after the fix (was intermittently
  stuck on HomePage before, confirmed via the diagnostic, not a network
  race as initially suspected).
- **Fixed (2026-09-23):** `diagnostics_demo_test.dart` — a single
  zero-duration `pump()` right after tapping "Run runIntegrationSelfCheck()"
  sometimes missed the frame where the button's spinner
  (`CircularProgressIndicator`) is shown, on a real device. Poll a few short
  pumps instead, falling through immediately if the check already finished
  (a legitimately fast real per-slot result shouldn't fail the test either).
  Found via a full 127-file real-device run (Pixel 7 Pro, then Tecno KJ7);
  bisected against the pre-migration commit first to confirm these
  predated the `google_mobile_ads` bump above, not caused by it.
- **Changed (round 72 audit, MINOR, breaking):** `verifySignedVipKey` and
  `VipManager.redeemSignedKey` now reject the legacy `AVP1` key format
  (no expiry, no app binding) by default. Pass `allowLegacyV1: true` if
  your app has already distributed real AVP1 codes and needs them to keep
  redeeming — `tool/vip_mint.dart` has minted `AVP2` by default since
  2.0.0, so this only affects codes minted with `--v1`.
- **Fixed (round 72 audit, MAJOR):** a 4-pass independent-review sweep
  (3 separate reviewer passes, each re-scanning all of `lib/` from
  scratch — the annotation alone doesn't block a release build, so every
  one of these needed a runtime `kReleaseMode`/`_testSeamsBlocked`/
  `debugSimulateReleaseModeForTestSeams` guard at its actual read/call
  site) found 18 more `@visibleForTesting` debug seams left ungated after
  round 69's original sweep — same class of gap as rounds 68-71, just
  missed the first four times because each seam has a different name, in
  a different file:
  - `AdManager`: `debugFirstInstallGuardFactory`, `debugForceAutoUmpError`,
    `debugInitRetryDelays`, `debugConsentGateRecoveryRetryDelay`,
    `debugBumpInitGen`, `debugReconnectDebounce`,
    `debugResumeConsentRecheckTimeout`, `debugResetPreInitExperimentId`,
    `debugReconcileProviderExplorationSlot`, `debugResetLastSkip`
  - `ConsentManager`: `debugPersistDelay`, `debugApplyBarrier`
  - `AdEventLog`: `debugPersistDelay` (a same-named-but-different-class
    sibling of `ConsentManager`'s, missed by grep for exactly that reason),
    `debugInjectRawEntry`
  - `IabStorage.debugOpenOverride` — could have hijacked every
    TCF/GPP/US-Privacy read
  - `AdPreferences.debugFillRateWriteDelay`, `AdPreferences.resetForTest`
  - `VipManager.resetSaveQueueForTest`, `RedeemedKeyLedger.resetWriteChainForTest`
    — both sit directly in the VIP anti-replay/anti-resurrection write
    serialization this SDK's whole VIP security model depends on
  - `UmpConsentManager.debugUmpFormBackstopOverride` — could have let ads
    show over a live UMP consent form
  - `AttConsentManager.resetPendingAttRequest`
  - `SafeLogger.resetForTest`
  - `bootstrap()`'s `debugRequestAtt`/`debugRequestUmp` parameters — could
    have skipped the real ATT/UMP prompts entirely in a release build
  - `RevenuePanel.debugModeOverride` — could have shown a real live-revenue
    number to the end user (this one guarded with `kReleaseMode` directly,
    not a simulate-flag, same as `bootstrap()`'s two above — a compile-time
    constant needs no runtime flag to already be unconditionally safe)

## [3.1.0] - 2026-09-22

- **Added:** wake lock — `AdConfig.keepScreenOnDuringSession` (default
  `true`) keeps the device screen on for the whole SDK session, so a
  rewarded video or an idle splash waiting on an App Open ad isn't
  interrupted by the device auto-locking. Enabled on a successful
  `AdManager.initialize()`, always released on `AdManager.destroy()`.
  `AdManager.setKeepScreenOn(bool)` overrides it at runtime independent of
  init state, for a host that wants to flip it mid-session. Backed by
  `wakelock_plus`, pinned to exactly `1.4.0` (not `^1.4.0`) — the newest
  version still satisfying this package's own Dart/Flutter floor; 1.5.0+
  needs Dart >=3.10.0, same class of wall as `google_mobile_ads` 8/9 (see
  this file's own pinning-wall notes and `CLAUDE.md`).
- **Fixed (round 71 audit, BLOCKER):** `AdManager.autoRequestUmpConsent`'s
  UMP flow ran fire-and-forget, so `adapter.initialize()` (the real
  AppLovin/AdMob native SDK) started immediately after, while EEA/UK
  consent was still resolving. `canRequestAds` being closed first meant no
  *ad request* went out before consent, but the native SDK's own init-time
  behavior was never gated on it. Native init now waits for the UMP flow
  to actually resolve (bounded by its existing 240s hard cap, so this
  cannot hang forever) before proceeding.
- **Fixed (round 71 audit, BLOCKER):** the debug-seam-guard gap rounds
  68-70 fixed elsewhere (`@visibleForTesting` is a lint, not a runtime
  check) also existed on 4 seams added since: most severe,
  `AdManager.debugApplyConfigVipGaidWhitelist` could self-grant a 50-year
  VIP entry with no signature check in a release build. Also fixed:
  `VipManager.clearRedeemedKeyLedgerForTest` (could wipe the anti-replay
  ledger for signed VIP keys), `debugFormDismissTimeoutOverride` in the
  UMP consent flow, and 3 static consent barriers in `AdManager`.

## [3.0.10] - 2026-09-21

- **Fixed (round 70 audit, MAJOR):** the debug-seam-guard gap rounds 68/69
  fixed on `AdManager` (`@visibleForTesting` is a lint, not a runtime
  check) also existed on `AppLovinAdapter`, `AdMobAdapter`,
  `AdSafetyConfig` and `IabStorage` — 11 seams across the 4 files. Most
  severe: `debugSimulateRewardedShowAndDismiss` on both ad adapters fires
  the reward-granting callback directly with no real ad shown, reachable
  in a shipped app via `AdManager().adapter as AdMobAdapter`;
  `AdSafetyConfig.debugExpireSuspiciousPause` defeats the invalid-traffic
  throttle outright. All 11 now share the same `kReleaseMode`-gated no-op
  guard as `AdManager`'s. See `doc/audit/audit_round70_consolidated.md`.

## [3.0.9] - 2026-09-21

- **Fixed (round 69 audit, MAJOR):** round 68 guarded 5 `AdManager`
  `@visibleForTesting` seams (`debugSetAdapter`/`debugAdapterFactory`/
  `debugVipManager`/`debugConsentManager`/`debugConfig`) against being
  called from a shipped release build. A full adversarial pass of the rest
  of `ad_manager.dart` (9195 lines — never fully audited before this round)
  found **28 more seams sharing the identical gap**, including
  `debugApplyUmpConsentResult` (forges GDPR consent state directly),
  `debugResetGuardState` (wipes every footgun guard at once), and
  `debugResetBannerCooldown`/`debugResetMrecCooldown`/
  `debugResetNativeCooldown` (clear the ad-request-spam cooldowns the
  safety layer depends on). All 33 now share the same `kReleaseMode`-gated
  no-op guard. See `doc/audit/audit_round69_consolidated.md` for the full
  list and the (verified-safe) members deliberately left unguarded.

## [3.0.8] - 2026-09-20

- **Bumped:** `connection_notifier` `^4.1.0` → `^4.1.1` (patch only) — the
  one direct dependency that was behind latest with no version-floor
  tradeoff attached. No behavior change expected.
- **Added:** 4 more device hashes to the built-in QA test-device fleet
  (`kQaTestDeviceHashes` in `lib/src/config/ad_config.dart`, now 17 total).
  A live incident on 2026-09-10/09-20 established that an AdMob test-device
  hash depends on the APK's *signing certificate*, not just device
  identity — a debug build and a release-signed build on the same physical
  phone report different hashes, and the hash can change again between
  release-signing keys. Two devices (TECNO BG6, TECNO KJ7) needed their
  debug/release-variant hashes added alongside the ones already present;
  none were removed, matching the "only add, never remove" policy a stale
  hash is harmless under.

## [3.0.7] - 2026-09-20

Docs-only release, no code changes.

- **Fixed:** the existing "don't copy `example/` wholesale into a real
  app" warning only lived deep in README's Pitfalls checklist — exactly
  where someone who opens pub.dev's Example tab and copies the whole
  `main.dart` file first, before reading anything else, would never see
  it. That's the single most predictable way to conclude "the SDK doesn't
  work": the copied file replaces the host app's own UI with a 48-page
  demo menu, keeps Google's placeholder test ad-unit IDs, and skips the
  native Android/iOS setup (AppLovin SDK key, AdMob App ID) that no
  example file can supply for you. Added a bold warning as the literal
  first lines of `example/lib/main.dart`, pointing to the README Quick
  start instead.

## [3.0.6] - 2026-09-20

Docs-only release, no code changes. Reverts part of 3.0.5.

- **Reverted:** 3.0.5 added `example/example.md` so pub.dev's Example tab
  would show a short walkthrough instead of `example/lib/main.dart`'s raw
  source. On review this traded away something deliberate: with
  `example.md` present, a visitor never sees a single line of real,
  working code on the package page — only prose describing it — which is
  exactly the outcome `main.dart`'s own top-of-file comment says was
  already considered and rejected (splitting the example up "makes the
  package look unfinished on pub.dev"). Removed `example/example.md`; the
  Example tab shows `main.dart` again.
- **Fixed:** `example/lib/main.dart` had ~124 lines of internal
  task-tracking shorthand in comments (`T117`, `T94`, `Round-27 audit
  fix`, `R2-02`, ...) meaningless to anyone outside this repo, right in
  the one file pub.dev shows to every visitor evaluating the package.
  Stripped the shorthand from comments, kept every explanation, changed
  no code — same 4949 lines, same 48 demo pages, `flutter analyze` clean.
  (A handful of matching UI-visible string literals, e.g. a demo page
  title like `'Banner adaptive sizing (T157)'`, were left alone — those
  are code values, not comments, and touching them risks breaking a
  widget key or golden test elsewhere.)

## [3.0.5] - 2026-09-20

Docs-only release, no code changes.

- **Fixed:** `README.md` was 142,860 bytes — over pub.dev's ~131,072 byte
  (128 KB) render limit — so the live pub.dev page silently cut off content
  mid-sentence past roughly the "Other advanced opt-in modules" section,
  hiding "Consent & compliance", "Public API", "FAQ", "Migration",
  "Support" and "License" from every visitor. Condensed verbose prose
  (mainly in "VIP system" and "What's new in 2.0.0") down to 128,203 bytes
  — under the limit — without touching "Quick start", "Consent &
  compliance", "Known limitations", or any code sample.
- **Fixed:** the Quick Start splash-screen sample said UMP consent was
  required but showed no call for it. It was never missing — `initialize()`
  requests it automatically via `AdConfig.autoRequestUmpConsent` (default
  `true`) — the sample just didn't say so. Added a comment explaining it.
- **Fixed:** pub.dev's Example tab was showing `example/lib/main.dart`'s
  raw ~5,000-line source (its own internal round/task-number comments and
  all) instead of a readable walkthrough, because pub.dev's file-priority
  order for that tab (`example/example.md` > `example/lib/main.dart` > ...
  > `example/README.md`) put the actual entry-point file ahead of the
  README — `example/README.md` was never going to be shown while
  `main.dart` exists, regardless of its content. Added `example/example.md`
  (highest priority in that order) with the walkthrough + demo-page table,
  and added the previously-missing iOS ATT call to both example docs'
  quickstart snippet.
- **Fixed:** `doc/AD_PROMPT_FLUTTER.MD` had ~25 scattered `Q10`/`Q14A`/`Q27`
  -style references to a numbered question list that isn't included
  anywhere in this repo and no longer exists — removed them; they added no
  resolvable information for either a human reader or an AI agent.

## [3.0.4] - 2026-09-20

- **Fixed (round 68 audit, MAJOR, `agy`/Gemini):** `tool/vip_keygen.dart`
  writes the Ed25519 VIP-signing private key to `.vip-private-key` (or a
  custom `--private-out` path) with no `.gitignore` entry anywhere in the
  repo covering it — a `git add .` after generating a key would have
  committed it, letting anyone with repo access mint unlimited valid VIP
  codes offline. Added `.vip-private-key`/`*.vip-private-key` to both the
  root and `packages/ad_sdk/.gitignore`. No key was ever committed.
- **Fixed (round 68 audit, MAJOR, external `claude` reviewer):**
  `AdManager.debugSetAdapter`/`debugAdapterFactory`/`debugVipManager`/
  `debugConsentManager`/`debugConfig` were only `@visibleForTesting` — an
  analyzer lint, not a runtime guard (`kReleaseMode` never gated them,
  unlike this file's other test-seam footguns). Any code running in the
  same isolate as a shipped release build — including a compromised
  transitive dependency — could call one of these to silently swap out
  the real ad adapter, VIP state or consent state, zeroing ad revenue or
  faking VIP/consent-active with no crash and no signal. Now a no-op
  (logged) once `kReleaseMode` is true, following the same
  `isActuallyRelease`-style pattern already used for the consent/test-ad-ID
  footgun guards. New `AdManager.debugSimulateReleaseModeForTestSeams`
  test seam and regression tests in
  `test/ad_manager_debug_seam_release_guard_test.dart`.
- **Fixed (round 68 audit, MINOR):** `IabStorage`'s class-level doc comment
  in `lib/src/core/iab_storage.dart` had no code between it and the
  private `_GppBitReader` class declared right above `IabStorage` —
  adjacent `///` blocks with nothing in between attach to whichever
  declaration follows immediately, so the doc merged onto the private
  class instead and never reached the generated docs for the public
  `IabStorage` API.

## [3.0.3] - 2026-09-20

- **Fixed (round 67 audit, MAJOR):** `ConsentManager._load()` read disk
  immediately on every `bootstrap()` call, including a reinit-without-
  `destroy()` on the same singleton (this file's own documented design).
  It did not wait for an in-flight `set()`/`reset()` write on that same
  instance, and a real platform-channel persist has a real async gap —
  reading disk inside that gap returned the pre-write value and silently
  overwrote `_current`/`_settingsListenable` with it. A host's own
  `set(hasUserConsent: true)` landed on disk correctly, but the in-memory
  `current` and the value actually applied to AppLovin/AdMob both
  reverted to the stale prior value for the rest of the running session
  — a compliance-relevant regression, not just a display glitch. Fixed
  by having `_load()` await the existing `_persistLock` (round 39) before
  reading disk, so a read always happens after any in-flight write lands.
  New regression test in `test/consent_manager_reload_race_test.dart`.
- **Fixed (round 65 audit, MAJOR):** `NativeAdWidget`'s
  `onAdLoadedCallback`/`onAdLoadFailedCallback` never got round 46's
  (R46-03) `capturedAdapter` identity guard — only
  `onAdClickedCallback`/`onAdRevenuePaidCallback` had it. That guard
  exists because `AdManager.destroy()` + re-`initialize()` swaps in a
  brand-new `AppLovinAdapter` instance whose native registry has never
  heard of an already-built widget's `instanceKey`; a late platform-view
  callback still closing over the OLD adapter falls through to
  `AdManager().adapter` (the NEW one) and silently plants a fresh, live
  registry entry keyed by an instance that no longer belongs to it. The
  old doc comment on these two callbacks assumed a same-adapter
  already-disposed-key throw would catch this, which only holds for a
  same-adapter dispose, not a cross-adapter swap. Fixed by adding the
  same `identical(adapter, capturedAdapter)` guard used by the other two
  callbacks. 2 new regression tests in `test/native_ad_widget_test.dart`.
- **Fixed (round 63 audit, MAJOR):** `ConsentManager.bootstrap()` only
  ever reassigned its journal field when a caller's `provenanceJournal`
  argument was non-null, so a host that disabled
  `AdConfig.enableConsentProvenanceJournal` on a later `initialize()`
  (a reinit without `destroy()` — this singleton survives that, by its
  own documented design) kept silently appending consent-change entries
  to the OLD journal, even though `AdManager().consentProvenanceJournal`
  correctly reported `null` and the host had no public API left to read
  or clear what kept being written. Fixed by making the reassignment
  unconditional, including `null` — symmetric with every other value.
  Also corrected a stale doc comment above the call site in
  `ad_manager.dart` that claimed only the first `bootstrap()` call honors
  this parameter, which directly contradicted `ConsentManager.bootstrap`'s
  own (correct) doc comment. 2 new regression tests in
  `test/consent_manager_provenance_test.dart`.
- **Fixed (round 62 audit, MAJOR):** `AdManager.applySignedFeatureFlags()`'s
  rollback guard (`SignedFeatureFlags.verify(previousRevision: ...)`)
  tracked the last-applied revision in an **in-memory-only** field, which
  reset to `null` on every app restart. A stale-but-still-validly-signed,
  still-unexpired feature-flags payload could therefore replay after any
  cold start and re-disable a feature the app had already moved past in a
  previous session (this mechanism is disable-only — `arbitrator`/
  `waterfallTuner`/`journeyPrefetcher`/`selfHealingObserver` — so the
  impact is an availability/degradation risk, not an entitlement bypass).
  `remote_ad_safety_provider`'s equivalent revision guard already persists
  correctly via `AdPreferences.getRemoteSafetyRevision()`/
  `setRemoteSafetyRevision()`; feature flags now follow the same pattern
  (`getFeatureFlagsRevision()`/`setFeatureFlagsRevision()`). New
  `AdManager.applySignedFeatureFlags` regression tests in
  `test/feature_flags_test.dart` simulate a restart via a new
  `debugFeatureFlagsRevision` test seam.
- **Fixed (round 62 audit, MINOR):** `redactSensitiveData()`'s 3 patterns
  only matched handwritten `key: value`/`key=value` shapes — a
  JSON-quoted key (`"gaid": "abc-123-def"`) has a `"` immediately after
  the key name instead of whitespace/`:`/`=`, so the whole match failed
  to start and the value passed through unredacted. This is a dormant gap
  (no current call site logs a JSON-quoted-key string through this
  defense-in-depth redactor), fixed before anything relies on it. New
  regression test in `test/safe_logger_test.dart`.
- **Fixed (round 61 audit, MAJOR):** `WaterfallTuner.recommendation()`
  gated on trailing *load* attempts (`minSampleSize`, 6) before trusting
  a comparison, but the score that actually decides a recommendation
  (`fillRate * avgEcpmMicros`) depends on `_revenueMicros`, a separate,
  independently-sized list — a load succeeding doesn't mean that
  impression ever showed and paid out. 6 load attempts could coexist with
  a single revenue sample: a real reproduction (6 loads + 6 revenue
  events averaging $0.10 for the current provider vs. 6 loads but only 1
  revenue event at $0.50 for the other) produced a switch recommendation
  driven entirely by one outlier. Fixed by additionally requiring the
  *recommended* provider's revenue-sample count to clear the same bar
  (deliberately not the current provider's — a current provider that's
  genuinely failing, e.g. 0% fill rate, has 0 revenue samples too, and
  that's a confident signal from a well-sampled fill rate, not a case
  this gate should block). 3 new regression tests in
  `test/waterfall_tuner_test.dart`; 4 pre-existing tests whose fixtures
  emitted too few revenue events to exercise the code path they were
  actually testing were updated to emit enough. 2197/2197 suite green,
  `flutter analyze` clean.
- **Fixed (round 60 audit, MAJOR):** `MonetizationDigitalTwin._groupByDay()`
  counted revenue from **every** `AdRevenueEvent` — including banner/mrec/
  native — into a day's `revenueMicros`, but only counted fullscreen
  `AdShowEvent`s into `shown` (banner/mrec/native never emit one).
  `forecastDailyCap()` divides `revenueMicros / shown` to get
  `avgRevenuePerShow`, so any app running both banner and fullscreen ads
  (this SDK's normal dual-format case) got a severely inflated forecast —
  e.g. $50/day banner + 5 real $2 interstitials produced an
  avgRevenuePerShow of $12 instead of $2, a ~6x overstatement that could
  lead a host to raise its fullscreen daily cap on a false revenue signal.
  Fixed by scoping the revenue sum to the same fullscreen slot types
  `AdShowEvent` covers (`appOpen`/`interstitial`/`rewarded`/
  `rewardedInterstitial`). 2 new regression tests in
  `test/digital_twin_test.dart` cover both the exclusion and that all 4
  fullscreen formats (not just interstitial) still count.
- **Fixed (round 59 audit, MAJOR):** `AdEventLog._eventExtra()` never
  persisted `AdRevenueEvent.requestId` (or `AdShowEvent.requestId`) into
  the compliance log, even though both classes have carried the field
  since T185. Because `RevenueAnomalyDetector.analyze()` reads
  `requestId` from that same persisted log to power two of its five
  anomaly kinds, `RevenueAnomalyKind.duplicateImpression` and
  `.requestIdCollision` could structurally never fire on real,
  production-sourced data — silently, with no error or log line
  indicating the feature was inert. The existing unit test for this
  detector hand-built its fixture maps with `'requestId'` set directly,
  so it kept passing throughout and never exercised the real
  `AdEventLog.recordEvent()` serialization path that was actually
  dropping the field. Fixed by adding `requestId` to both event types'
  serialized fields; added a pipeline-level regression test that goes
  through the real `AdEventLog` → `RevenueAnomalyDetector` path instead
  of a hand-built map.
- **Added:** `AdConfig.onConsentProvenanceEntryAppended` — opt-in hook,
  ignored unless `enableConsentProvenanceJournal` is `true`. Called right
  after each `ConsentProvenanceEntry` is persisted to the local, on-device
  hash-chain journal. `verifyChain()`'s own doc comment already documented
  that a local-only hash chain cannot detect a fully forged chain — an
  attacker with full control of the device's own storage can rewrite it
  self-consistently from scratch. This hook lets a host app mirror each
  entry to its own server as it happens, giving it an external anchor
  outside device storage for entries recorded before any later on-device
  tampering. The SDK makes no network call itself here — the callback may
  be sync or `async` (e.g. to `await` an HTTP call), is never awaited by
  the SDK either way (fire-and-forget, never delays a real consent
  change), and any error it raises, sync or async, is swallowed.
- **Fixed (round 57 audit, MAJOR, same day):** the round-57 external
  review of the hook above (codex hit its usage limit; an internal
  fork ran the same adversarial brief as a substitute) found that the
  `try`/`catch` swallowing callback errors only caught a *synchronous*
  throw. An `async` callback — the natural way to write "await an HTTP
  call", i.e. exactly what this hook exists for — never throws
  synchronously; it returns a `Future` that rejects instead, which the
  SDK wasn't awaiting or attaching an error handler to, so the rejection
  escaped as an **unhandled zone error** (fatal in many Crashlytics/
  Sentry setups) despite the doc comment's explicit promise that a
  throwing callback "never fails the underlying consent change." Fixed
  by widening the field to `FutureOr<void> Function(...)` and attaching a
  no-op `catchError` to the returned Future without awaiting it (stays
  fire-and-forget). New regression test covers the async-throw case the
  original 3 tests missed.

## [3.0.2] - 2026-09-20

- **Fixed (round 49 audit, MAJOR):** `AdManager().clearSdkData(scope:
  SdkDataErasureScope.allIncludingEntitlements)` — the SDK's own documented
  "erase my data" flow (Apple 5.1.1(v)/GDPR/CCPA) — also erased the iOS
  Keychain flag `FirstInstallGuard` uses to stop the first-install 24h VIP
  trial from being re-granted without a real uninstall. A user tapping that
  button and reopening the app got a fresh trial every time, no reinstall
  needed. The Keychain flag is no longer touched by this scope, matching
  how `RedeemedKeyLedger`/`ConsentProvenanceJournal` already carve
  themselves out of entitlement erasure for the same anti-abuse reasoning.
- **Fixed (round 49 audit, MAJOR):** `AdScreenState`'s three full-screen ad
  completion callbacks (`showInterstitialAd`'s `onDoneFlow`,
  `showRewardedAd`'s `onEarnedReward`, `showRewardedInterstitialAd`'s
  `onDone`) checked `mounted`/disposed state before starting the ad, but
  not when the ad actually finished — if the host navigated away while the
  ad was still on screen, the late native "ad closed" callback ran the
  host's `onDone` against an already-disposed screen (`setState` after
  dispose / deactivated-widget context lookup crash). All three now guard
  the completion callback too.
- **Fixed (round 49 audit, MAJOR):** `AdSafetyConfig.resetSessionCounters()`
  documented itself as preserving fraud history, but was zeroing
  `_fullscreenImpressions`/`_fullscreenClicks` — exactly the state its own
  CTR-anomaly gate needs 5 cumulative impressions to ever evaluate. Calling
  this reset repeatedly (e.g. wired to a common action, as the M2/round-6
  incident already warned against for a different counter) could
  permanently prevent the click-fraud gate from ever tripping, no matter
  how bad the real click-through rate was.
- **Fixed (round 49 audit, MINOR):** `ProviderFailoverAdvisor` and
  `FillRateMonitor` counted a load failure toward their thresholds even
  when the device was offline at the time, so a network flap during a
  reconnect-debounce refill could run several loads that fail purely from
  lost connectivity and trip a false "switch providers" recommendation or
  fill-rate alert. Both now ignore a load failure while
  `AdManager().isConnected` is `false`.
- **Tooling:** `dart run tool/vip_mint.dart`/`vip_keygen.dart`/
  `vip_crl_mint.dart` on a Dart 3.10+ toolchain prints
  `Running build hooks...` to stdout ahead of the script's own output,
  silently corrupting a captured `$(dart run tool/vip_mint.dart ...)` key
  or CRL string. Docs and the CLI security test now use bare
  `dart tool/vip_mint.dart` (no `run` subcommand), which doesn't trigger
  the build-hooks step. (Round 49 audit, found independently by an
  external `agy` pass.)
- **Fixed (round 51 audit, MAJOR):** `ProviderFailoverAdvisor`'s open-circuit
  state (`_openedAt`) only ever lived in memory — a restart right after the
  circuit tripped (consecutive failures reaching the threshold) rehydrated
  the failure count but not the open state, so `shouldFailoverNextSession`
  silently read `false` again until one more real failure landed. The open
  timestamp is now persisted and restored alongside the failure count.
- **Fixed (round 51 audit, MAJOR):** `ConsentProvenanceJournal.verifyChain()`
  only ever re-derived its hash chain from its own currently-stored entries,
  so truncating the tail or forging an entirely new chain both still
  verified as valid — despite the method's own doc comment claiming it
  detects an entry "removed after being recorded". Added
  `signConsentProvenanceJournal()` (same on-device Ed25519 signed-export
  this package's other compliance records already have via
  `signBypassAuditTrail`/`signComplianceReport`) so an exported journal can
  at least be checked for post-export tampering, and corrected
  `verifyChain()`'s doc comment to state its real, narrower guarantee.
- **Fixed (round 51 audit, MINOR):** `FillRateBaselineMonitor` counted a load
  failure into its session tally and 7-day persisted history even when the
  device was offline at the time — the same class of false signal
  `ProviderFailoverAdvisor`/`FillRateMonitor` were already fixed for in
  round 49, just not applied here too.
- **Fixed (round 51 audit, MINOR):** `FillRateBaselineMonitor`'s revenue
  regression check gated only on load-attempt sample size
  (`session.attempts`/`baseline.attempts` `>= minSamples`), not on how many
  actual paid events fed the averages being compared — a single paid event
  on each side could swing the average by ~100% and fire a regression alert
  off pure n=1 noise. Now also requires `revenueCount >= minSamples` on
  both sides before considering a revenue regression.
- **Fixed (round 51 audit, MINOR, tooling):** `BypassAuditTrail.clear()` was
  missing the same `.catchError` this file's `flush()`/`_schedulePersist()`
  already carry (T155) — a transient persist failure inside `clear()` threw
  uncaught out to its caller instead of being logged and absorbed.
- **Fixed (round 52 audit, MAJOR):** `requestAttIfNeeded()` held the
  fullscreen-ad mutex indefinitely (until the 15-minute backstop) if the ATT
  plugin call threw synchronously instead of failing asynchronously — the
  same bug class `requestPrivacyOptionsFlow()`'s UMP path was already fixed
  for (round-8 QC), just not applied to the ATT path too.
- **Fixed (round 52 audit, MAJOR):** `installAdCrashGuard()` treated
  `FlutterError.onError`/`PlatformDispatcher.onError` as one all-or-nothing
  unit — if a host replaced only one of the two since the last install, the
  other (still this guard's own untouched wrapper) got silently re-captured
  as "the previous handler" and wrapped again, permanently losing the real
  original underneath it. A later `destroy()` then restored the guard's own
  stale wrapper instead of the host's true original handler. Each handler
  is now checked and (re)installed independently.
- **Fixed (round 52 audit, MINOR):** `AdBootstrapResult.toString()` printed
  the raw device GAID — a public return value a host may log or pass to a
  crash reporter directly, outside this SDK's own log redaction. Now prints
  `hasGaid: bool`, matching `AttResult.toString()`'s existing convention for
  the IDFA.
- **Fixed (round 54 audit, MINOR):** `AdManager().clearSdkData()` erased
  `ProviderFailoverAdvisor`'s persisted streak/circuit keys but never reset
  a live advisor instance's in-memory copy — its next ad-load event would
  silently re-persist the pre-erasure state right back. Added
  `ProviderFailoverAdvisor.resetInMemoryState()`, now called from
  `clearSdkData()` when a live advisor is enabled.
- **Fixed (round 54 audit, MINOR, example app only):**
  `NativeDemoPage._simulateWatchdogTimeout()` was missing the `mounted`
  guard after its `await`, unlike every other async handler in that class —
  navigating away mid-call could call `setState()` on a disposed widget.
- **Fixed (round 55 audit, MINOR, tooling):** `tool/vip_keygen.dart` wrote
  the private-key file with default permissions, then `chmod 600`'d it
  afterward — a real (if narrow, local-attacker-only) TOCTOU window where
  the file was briefly readable by anyone else on the same machine. Now
  shells out to a subprocess with `umask 077` set before the file is ever
  created, so no such window exists.
- **Fixed (round 56 audit, MAJOR):** GPP US-state/national/California
  section strings from a standards-compliant CMP are commonly two-segment
  (`CoreSegment.GpcSegment` — every reference CMP implementation defaults
  to including the optional GPC sub-segment). `IabStorage`'s bit-packing
  decoder didn't strip the segment separator before decoding, so `.`
  (not in the base64url alphabet) threw a `FormatException` that every
  caller's `catch` silently treated as "no usable signal" — a real
  US-privacy opt-out expressed only in a two-segment section (the common
  case, not an edge case) was invisible, closing a compliance gap that had
  been an open, unresolved question since round 43. Fixed once in the
  shared `_GppBitReader` constructor (`section.split('.').first`), so all
  21 US-state/national/California parsers get it uniformly.

## [3.0.1] - 2026-09-19

- **Fixed (round 48 audit, MINOR):** a rapid online→offline flap while a
  reconnect-debounce timer was pending left that timer running; since its
  callback only checked `isInitialised`/VIP status, not current
  connectivity, it fired the full "network back online" refill (UMP retry,
  ad refill, banner/MREC preload) while the device was actually offline
  again. Wasted work, not harmful (every call already fails safely
  offline), but now cancelled correctly on the offline transition.

- **Fixed (round 46 audit, MAJOR):** round 44's fix routing pre-init
  `setDoNotSell()` through `setConsent()` (so it wasn't silently dropped)
  had a side effect nobody intended — it also satisfied
  `consentFootgunWarning`'s "a consent flow ran" check, even though
  `setDoNotSell` only supplies the CCPA axis, not a GDPR/UK consent
  decision. A release build with `autoRequestUmpConsent: false` and no
  AppLovin CMP could call `setDoNotSell(true)` pre-init and silently
  bypass the guard meant to catch exactly that configuration.
  `setConsent()` now takes a `qualifiesAsConsentFlow` parameter
  (default `true` for every genuine external caller); the internal
  `setDoNotSell` routing passes `false`. (R46-01)
- **Fixed (round 46 audit, MINOR — a regression in round 45's own R45-04
  fix):** the release-blocking test-ad-ID guard and the consent-flow
  guard shared one mutable flag, so `setConsent()` resolving normally
  (as it does moments after init in any real app) silently cleared the
  test-ID block too. Now its own dedicated flag, untouched by
  `setConsent()`. (R46-02)
- **Fixed (round 46 audit, MINOR):** `BannerAdWidget`/`MrecAdWidget`
  click callbacks lacked the stale-view check their revenue callbacks
  already had (round 33), so a click for an adViewId the widget had
  since moved on from was still recorded. Also, `NativeAdWidget`'s
  round-45 disposed-instance guard was per-adapter-instance, so a late
  callback surviving a `destroy()` + re-`initialize()` could land on,
  and contaminate, the new SDK session; native click/revenue callbacks
  now also require the callback's adapter to still be `identical` to
  the one current when the listener was built. (R46-03)

- **Fixed (round 45 audit, MAJOR):** round 44's TCF-vendor-consent fix
  (`applyConsentToProviders` skipping `AppLovinMAX.setHasUserConsent` when a
  real IAB TC string already exists) only guarded the *post-init* code path,
  which never actually runs on an ordinary cold start — `setConsent()`
  buffers instead of applying until the SDK is already initialised. The
  *pre-init* call in `AppLovinAdapter.initialize()` (the one that actually
  reaches AppLovin first on every launch) still called
  `setHasUserConsent` unconditionally, silently overriding a returning EEA
  user's real vendor-specific TCF consent with a coarse, AdMob-shaped
  boolean. Now guarded the same way. See
  `doc/audit/audit_round45_consolidated.md` (R45-01).
- **Fixed (round 45 audit, MINOR):** AppLovin native ad clicks delivered
  after the widget (and its native instance) was already disposed were
  still recorded against the global click/invalid-traffic counters and
  emitted through `eventSink` — unlike the revenue callback, which already
  guarded against this. Now checks `isNativeInstanceDisposed` the same way.
  (R45-02)
- **Fixed (round 45 audit, MINOR):** `loadRewardedInterstitialAd`/
  `showRewardedInterstitialAd` silently never became ready on AppLovin (MAX
  has no equivalent ad unit type), indistinguishable from "not filled yet."
  Now emits an explicit `AdSkipEvent(reason: 'unsupported_provider')` so a
  host can tell the two cases apart and disable the placement
  deterministically. (R45-03)
- **Fixed (round 45 audit, MINOR):** shipping Google's public TEST AdMob ad
  unit IDs in a real release build only logged a warning and
  `assert(false, ...)` — an assertion stripped out of release builds
  entirely, so the one build that needed blocking got no enforcement. Now
  release-blocking like every other footgun guard: `canRequestAds` stays
  false for the process if a release build is still on a Google test ad
  unit ID. (R45-04)

## [3.0.0] - 2026-09-18

- **Fixed (round 44 audit, MAJOR):** `applyConsentToProviders` used to call
  `AppLovinMAX.setHasUserConsent(bool)` unconditionally with a purpose-only
  boolean computed for AdMob's `npa` flag — a value with no vendor-consent
  basis for AppLovin. Per AppLovin's own MAX integration docs, the SDK
  auto-reads a real IAB TCF string from platform storage the moment a
  certified CMP (UMP) writes one, and the explicit `setHasUserConsent` call
  is documented as the path for apps with no CMP at all. The explicit call
  is now skipped whenever a real TC string already exists on the device,
  letting MAX evaluate its own vendor consent instead of being overridden.
  `setDoNotSell` (CCPA, an unrelated axis) is unaffected — still always
  called.
- **Fixed (round 44 audit, MAJOR):** `setDoNotSell(true)` (CCPA/CPRA "Do Not
  Sell" opt-out) called before `initialize()` was silently discarded —
  logged "ignored" and returned — contradicting its own docstring's "safe
  to call before initialize()" claim. Now routes through the same pre-init
  buffer `setConsent()` already uses, so the choice survives and reaches
  both providers once `initialize()` runs. `doNotSell`'s getter now falls
  back to the buffered value while there is no `ConsentManager` yet.
- **Fixed (round 44 audit, MINOR):** native ads were the one inline surface
  never blanked while a fullscreen ad (App Open) was on screen — a live
  native ad could stay visible underneath it, the ad-over-ad placement
  Google/AppLovin policy prohibits. `native()`'s listenables now inherit and
  release the fullscreen hold the same way `banner()`/`mrec()` already do,
  on both providers; a new `AdManager.nativeVisible(key)` drives
  `NativeAdWidget` the same way `bannerVisible` already drives
  `BannerAdWidget`. See `doc/audit/audit_round44_consolidated.md` finding 4.
- **BREAKING (round 44 audit, finding 1):** Removed the built-in non-CMP
  consent dialog (`showConsentDialog`, `ConsentDialogStrings`,
  `ConsentManager.showDialog`/`showDialogIfNeeded`/`updateStrings`/`strings`,
  `AdConfig.autoShowConsentDialog`/`consentDialogStrings`/
  `consentBarrierDismissible`/`consentDialogPostSplashDelay`). It was a plain
  Allow/Reject sheet, not a Google-certified CMP — it produced no valid TCF
  consent string, so a "yes" it collected was not a valid legal basis for
  personalized ads in the EEA/UK/Switzerland, yet was written straight
  through to AppLovin's `setHasUserConsent`. **Migration:** use Google UMP
  (`autoRequestUmpConsent: true`, the default) or another certified CMP
  instead — see README's "Consent & compliance" section. Apps that never set
  `autoShowConsentDialog`/never called `ConsentManager.instance.showDialog`
  directly are unaffected — this was already an opt-in-by-config path, off
  whenever `autoRequestUmpConsent: true` (the default) since round 5.

## [2.9.23] - 2026-09-18

- **Fixed (example app only, no SDK behavior change):** a focused re-audit
  of the 2.9.22 fixes found two narrow residual gaps in
  `RemoteSafetyDemoPage`'s cleanup:
  1. its fire-and-forget `destroy()`/`initialize()` restore chain had no
     `.catchError`, so a rejected Future there would surface as an
     unhandled Zone error;
  2. navigating away from the page WHILE "Apply provider" was still in
     flight ran `dispose()` before `_wired` ever flipped true, so
     cleanup was skipped even though the in-flight call could still go on
     to successfully rewire the live `AdManager` singleton.
  Both fixed: the restore chain now swallows a failed retry, and the
  in-flight apply call itself detects `!mounted` and performs the
  restore if it succeeds after the page is already gone.
- **Docs (round 43, AdMob-only focused compliance re-audit — see
  `doc/audit/audit_round43_admob_compliance.md`):** corrected
  `ump_consent.dart`'s doc comments, which overstated the durable "Privacy
  Options" entry-point requirement as EEA/UK-only — it also applies to the
  US-states/GPP consent message type; the code itself was already
  region-agnostic, so this is a doc-only fix. Ad placement/density/
  reward-granting and the rest of consent/privacy handling were
  independently re-verified against Google's live (2026-09-18) policy
  docs and found compliant, with one non-urgent note folded into
  `CLAUDE.md`'s existing pinning-wall section (`tagForChildDirectedTreatment`/
  `tagForUnderAgeOfConsent` are now deprecated in favor of a unified
  `ageRestrictedTreatment` API, only reachable once this package can adopt
  `google_mobile_ads` 9.1.0+ — already blocked by the documented
  Flutter/Dart floor, and non-urgent since Google keeps the legacy pair
  working through 2026).

## [2.9.22] - 2026-09-18

Fixes for the round-42 audit findings (see `doc/audit/audit_round42_consolidated.md`
and its per-reviewer reports for the full findings and severity reasoning).

- **Fixed (BLOCKER, policy):** `NativeAdWidget`'s AppLovin branch never
  included `MaxNativeAdOptionsView`, the mandatory privacy-information/
  AdChoices-equivalent icon AppLovin's own native-ad integration guide
  requires. Every AppLovin native ad impression from this SDK was
  policy-non-compliant, unconditionally, on both platforms. Fixed by adding
  it to the existing layout, positioned per AppLovin's own reference
  example.
- **Fixed (MAJOR, reward integrity):** the AppLovin stale-callback fix
  shipped in 2.9.21 (commit `8d8d990`) had a narrow residual gap: when a
  show-confirmation watchdog abandoned a cycle and a new cycle started
  showing before the old cycle's real native callback finally arrived with
  an empty/ambiguous `creativeId`, that late event could be misattributed
  to the NEW cycle's caller instead of being discarded. Fixed by refusing
  to start a new Interstitial/Rewarded show for 35s after a watchdog
  abandonment (matching AppLovin's own documented "late by 10-30s"
  callback ceiling), so by the time a new show genuinely begins, the old
  cycle's straggler window has already closed.
- **Fixed (MAJOR, API honesty):** `showRewardedAd`'s `vipAutoGrant` path
  reused the `onEarnedReward` boolean to mean "VIP gets the perk, no ad
  shown" as well as "the provider confirmed a genuine completed ad view."
  The bundled example's "Watch ad for +10 coins" button fired this path
  for VIP users with no ad ever requested. Doc comment now states this
  explicitly; the example's button now discloses the no-ad case
  ("Claim +10 coins (VIP perk, no ad shown)").
- **Fixed (MAJOR, consent):** `disableAppLovinCmpFlow: false`'s own doc
  comment told a host to flip only that one flag to use AppLovin's own CMP
  "instead of" UMP, but nothing checked whether `autoRequestUmpConsent`
  (`true` by default) was also turned off — following that doc comment
  literally ran BOTH consent flows concurrently on the same EEA user, each
  able to silently overwrite the other's answer on AppLovin.
  `consentFootgunWarning` now warns on this exact combination.
- **Fixed (MAJOR, example quality):** the example app's `DemoConfig` set
  only Android-valued AdMob test ad-unit ids with no iOS overrides for any
  format — an iOS run of the example silently requested Android test units
  for every AdMob surface and never actually validated AdMob on iOS. Added
  Google's published iOS test ad-unit ids for every format.
- **Fixed (MINOR):** `CompatibilityMatrix.minimum` had no (iOS, AppLovin)
  entry even though the adapter code handles it fine — self-inflicted
  doc/CI gap, now closed.
- **Fixed (MINOR):** the release-build test-ad-id footgun checks
  (`_adUnitIdFootgunWarnings` and the Google-test-id detector) only
  covered banner/interstitial/appOpen/rewarded; `rewardedInterstitialId`,
  `mrecId`, and `nativeId` now get the same coverage (only when
  configured — these three are genuinely optional formats).
- **Fixed (MINOR, example):** `RemoteSafetyDemoPage` had no `dispose()`
  despite globally rewiring the live `AdManager`'s safety config; leaving
  the page without tapping "Restore demo defaults" left that config
  altered for the rest of the session. `dispose()` now runs the same
  restore as a best-effort, fire-and-forget cleanup.
- **Docs:** corrected a stale `NativeAdWidget` doc example pairing a
  120px custom height with the (higher-minimum) medium template; corrected
  `vipKeyValidator`'s doc comment, which implied `null` accepts every key
  in all build modes (it only does in debug/profile — release rejects
  every key); corrected a stale integration-test file count in `CLAUDE.md`;
  corrected `test/interstitial_rewarded_watchdog_test.dart`'s file-level
  comment, which incorrectly claimed Interstitial/Rewarded have no
  show-confirmation watchdog at all (they do — Round-7's `AdSlot.beginShow`
  watchdog — the file's own test seams just don't arm it); documented
  (not changed — reconfirmed as the existing, deliberate round-32 product
  decision) the AVP2 bundle-binding fail-open on a `PackageInfo` read
  failure.

## [2.9.21] - 2026-09-17

- **Fixed (BLOCKER, real-device smoke test):** every AppLovin fullscreen ad
  (Interstitial, Rewarded, App Open) had its `displayed`/`hidden`/earned-
  reward native callback silently discarded as "stale" — **100% of the
  time, on real devices** — even though the ad genuinely showed. Root
  cause: the stale-cycle guard compared `identical(ad, _interstitialAd)`
  (the loaded `MaxAd` Dart object), an assumption (never verified against
  the real plugin) that `applovin_max` reuses the same object across a
  show cycle. It doesn't — `AppLovinMAX.createMaxAd` deserializes a BRAND
  NEW `MaxAd` from the platform channel on every single callback, so the
  identity check was always false. Consequence in production: the 10s
  show-confirmation watchdog always fired, reporting a genuinely-displayed
  ad as "swallowed" — and for Rewarded specifically, **a user who watched
  the entire ad had their earned reward silently dropped**. Revenue
  correlation (T185, `AdRevenueEvent.requestId`) was broken by the same
  root cause (an `Expando<String>` also keyed by ad-object identity) and
  was always `null` for AppLovin fullscreen ads. Fixed by replacing both
  mechanisms with `MaxAd.creativeId` comparison, which the real
  network/mediation stack does vary between genuinely different ad
  instances (trusting the callback when creativeId is empty/unavailable,
  e.g. AppLovin's own test-mode creatives, rather than guessing). Found
  during a real-device AdMob/AppLovin smoke test (Galaxy A50s, TECNO KJ7)
  requested after publishing T202 — no code change had touched this path;
  it had been silently broken since AppLovin support first shipped. 4 new
  regression tests simulate the real plugin's actual per-callback object
  semantics (existing tests never caught this because they reused one
  `MaxAd` instance across a whole load→show→hide cycle); 3 existing
  cross-cycle tests updated for the same reason.

- **New (T202):** `ConsentProvenanceJournal` — append-only, tamper-evident
  (SHA-256 hash chain) history of consent changes, exported from the
  package barrel alongside `ConsentProvenanceEntry`. **Opt-in** —
  `AdConfig(enableConsentProvenanceJournal: true, ...)`, default `false`
  (real SHA-256 hashing on every consent change is latency an app with no
  legal-audit-trail need shouldn't pay for by default — a 5-parallel-
  adversarial-review follow-up on this same feature also found it hangs
  `flutter_test`'s `testWidgets()` in specific file/test-ordering
  combinations if wired unconditionally, so it stays off unless a host asks
  for it). Reachable as `AdManager().consentProvenanceJournal` (nullable
  until SDK init completes AND until enabled, same contract as
  `AdManager().vip`); when enabled, every `ConsentManager.set` / `.reset` /
  `.showDialog` call records an entry (`source`, `policyRevision`,
  `hasUserConsent`, `isAgeRestrictedUser`, `doNotSell`, `regionSignal`).
  Distinct from `ConsentSettings` (current state only) and
  `ComplianceReport` (a point-in-time snapshot) — this is the change
  history neither of those keeps.
  - Deliberately kept OUT of `AdManager().clearSdkData()`'s default sweep,
    under EITHER `SdkDataErasureScope` — some legal frameworks (GDPR Art.
    17(3), CCPA) permit/require retaining proof that consent was
    asked/received as a "legal basis defense" even after a user's general
    erasure request. `AdManager().clearSdkData(purgeConsentProvenanceJournal:
    true)` removes it explicitly (also clears the live in-memory copy
    immediately, same as `VipManager`'s entitlement erasure does), as a
    deliberate, separate decision from erasing VIP entitlements.
  - `ConsentManager.bootstrap`/`.set`/`.reset`/`.showDialog` gained new
    optional parameters (`provenanceJournal`, `source`, `policyRevision`) —
    all additive with backward-compatible defaults, no behavior change for
    an existing caller that doesn't pass them.
  - **Follow-up self-audit (5 parallel adversarial reviews) found and fixed
    4 real bugs** in this feature before it shipped: (1) concurrent
    `append()` calls could read a stale `prevHash`, producing a chain
    `verifyChain()` wrongly flagged as tampered — now serialized via a
    Future-chained queue; (2) a `destroy()`+reinitialize() cycle orphaned
    the journal `ConsentManager` actually wrote to, leaving
    `AdManager().consentProvenanceJournal` permanently stale — `bootstrap()`
    now adopts a non-null journal on every call, not just the first; (3)
    `AdManager().clearSdkData(purgeConsentProvenanceJournal: true)` — the
    documented erasure escape hatch — didn't exist at the `AdManager` layer
    (only on the internal, unexported `AdPreferences`), a compile error if
    copied from the docs verbatim; (4) `showDialog()` recorded an entry but
    could never be told a distinct `source`, making the SDK's own consent
    dialog indistinguishable from a scripted `set()` call in the journal.

- **Fixed (self-audit):** with `codex review` unavailable all session, a
  self-review of every commit from this session (5 parallel adversarial
  reads, no confirmation bias — fresh agents, not the same context that
  wrote the code) found and fixed 4 real defects:
  - `InlineAdController.attach()` (T201) crashed via its own debug assertion
    on a legitimate Key-change remount (Flutter mounts the new State,
    calling `attach()`, before disposing the old one, which calls
    `detach()`) — the assert is gone; the last attach now simply wins, and
    a stale detach from the old State is already a safe no-op.
  - `BannerAdWidget`/`MrecAdWidget`'s `controllerRefresh()` (T201) didn't
    check `_pausedByController` the way every other reinit path already
    does — `refresh()` while paused silently un-paused and reloaded. Now
    gated the same way `NativeAdWidget` already was.
  - `RevenueIntegrityLedger` (T145/T185)'s FIFO fallback match could
    misattribute a late/orphaned revenue event to a DIFFERENT pending show
    that has its own distinct `requestId`, when two shows of the same
    (providerTag, type, placement) were pending at once — silently masking
    a real revenue-integrity gap. The fallback now only ever considers
    requestId-less pending entries, matching this class's own "resolved
    EXACTLY — no guessing" promise for entries that do carry an ID.
  - `AdManager._destroy()` (T183) discarded `JourneyPrefetcher.dispose()`'s
    returned `Future` instead of awaiting it (that method's signature
    changed from `void` to `Future<void>` in T183, but this one call site
    was missed) — a pending persisted write could be silently dropped on
    teardown. Fixed with the exact same capture-before-null-then-
    await-later pattern `_waterfallTuner`/`_selfHealingObserver` already
    use two lines above it in the same function.
  Also documented (no code change, low severity / already-moot today):
  `compliance_signing.dart`'s concurrent-mint lock is keyed globally, not
  per-`FlutterSecureStorage` instance; `tool/api_surface.dart`'s API golden
  walker doesn't see members of a plain Dart `extension` (only
  classes/enums/mixins/extension types) — this package exports none today.

- **Changed (T183):** `JourneyPrefetcher`'s rolling time-to-show averages
  now persist across app restarts (`persist: true`, the new default) —
  previously purely in-memory, so every cold start re-learned "how long
  after this signal does the user actually see the ad" from zero. New
  `JourneyPrefetcher.ready` (a `Future<void>`) completes once a prior
  session's data has finished hydrating and this instance has started
  listening for new events — `notifySignal`/`averageTimeToShow` never wait
  for it themselves, same as every other on-device signal in this SDK.
  `dispose()` is now `Future<void>` (was `void`) so a pending persisted
  write isn't silently dropped on teardown, bounded by a 2s timeout the
  same way `WaterfallTuner.dispose` already is. Pass `persist: false` to
  opt out of the disk write entirely. Only ever stores a duration between
  an app-defined signal string and an ad type — never the signal's own
  content or anything personally-identifying.

- **New (T219):** `ConsentDialogStrings`, `CcpaOptOutStrings`,
  `VipDialogStrings`, and `VipRedeemStrings` (found mid-task — a separate,
  ~30-field string class for the full `VipRedeemScreen`, distinct from
  `VipDialogStrings`' small redeem-confirmation-dialog subset) each gained
  a named `.en` preset (identical to the plain default, just discoverable
  by name symmetrically with `.vi`) and a `resolve([Locale? locale])`
  static helper that picks `.vi` for a Vietnamese locale and `.en`
  otherwise — pass `Localizations.localeOf(context)` to resolve against
  the app's own configured locale, or omit it to fall back to the
  device's own locale (works before any widget has built, e.g. directly
  in `main()`). `VipDialogStrings` and `VipRedeemStrings` also each
  gained a `.vi` preset for the first time — `VipDialogStrings`' Vietnamese
  text previously only existed as a copy-paste example in a doc comment,
  and `VipRedeemStrings` had no Vietnamese text anywhere at all. No
  existing default changed — a host passing nothing still gets exactly
  the same strings as before.

- **New (T217):** Public API stability & deprecation policy, documented in
  README.md — semver commitment, `@Deprecated`/`@experimental` usage, and a
  minimum one-MINOR-version deprecation window before any removal.
  Enforced by a new API golden test (`test/api_golden_test.dart` +
  `tool/api_surface.dart`, dev-only `analyzer`/`path` dependencies): it walks
  the fully resolved public export surface of `applovin_admob_sdk.dart`
  (excluding `@internal`/`@visibleForTesting` seams) and fails on any
  unreviewed diff from the checked-in `test/goldens/public_api_surface.txt`,
  so an accidental breaking change can no longer slip through unnoticed in
  an unrelated refactor.

- **New (T201):** `InlineAdController` — an imperative `refresh()`/`pause()`/
  `resume()`/`status` handle a host attaches to ONE `BannerAdWidget`/
  `MrecAdWidget`/`NativeAdWidget` instance (new `controller` param on all
  three, mutually exclusive with `active`), instead of juggling its own
  `active: bool` state variable and forcing a rebuild every time it
  changes, or reaching for `AdManager`'s singleton methods (which have no
  notion of "this one slot" and risk touching every other placement using
  the same format). Every command only ever calls into that widget's own
  existing gated methods — `refresh()` respects the same
  consent/VIP/connectivity/cooldown gate an automatic reload already
  does (silently skipped, never forced, while in cooldown); `pause()`/
  `resume()` reuse the exact same path `VisibilityDetector`/route-away
  already use for Banner/MREC, and dispose-and-reload for Native (no
  auto-refresh ticker to merely suspend there). A command issued before
  any widget has attached is remembered, not lost, and replays once the
  next widget attaches. `dispose()` is idempotent. Fixed two related gaps
  found while building this: returning to a route (`didPopNext`) used to
  silently reload a Banner/MREC a host had explicitly paused via the new
  controller if a real route push/pop happened in between (a pre-existing,
  narrower version of the same gap for plain `active: false` — outside
  this fix's scope, left for a follow-up); and a controller-driven
  `pause()`/`resume()` invoked from outside any build phase or route
  transition could leave a deferred `addPostFrameCallback` stuck
  unscheduled.

- **New (T200):** `AdManager().clearSdkData({scope, confirmedEntitlementErasure})`
  — a scoped, privacy-safe data-erasure API. Unlike
  `AdPreferences.clearAllData()` (still available, but now documented as
  dangerous — it wipes the ENTIRE shared `SharedPreferences` instance,
  including any key a host app or a different plugin stored in the same
  namespace), this only ever removes keys the SDK itself owns, across
  both storage backends it actually uses (`SharedPreferences` and
  `flutter_secure_storage` for VIP entitlements).
  `SdkDataErasureScope.everythingExceptEntitlements` (the default) clears
  safety counters, consent settings, compliance/analytics history,
  remote-config cache, and experiment id — VIP entitlements are left
  completely untouched. `SdkDataErasureScope.allIncludingEntitlements`
  additionally erases every VIP-entitlement key (VIP entries,
  redeemed-key ledger, first-install grace flag, migration flags,
  revocation cache, legacy GAID list) and requires
  `confirmedEntitlementErasure: true` — passing that scope without it
  throws an `ArgumentError` instead of silently downgrading, since this
  permanently deletes VIP entitlements a user may have paid real money
  for. When the SDK is already initialised, the live `VipManager`
  instance is used so the running session's reactive VIP state updates
  immediately, not just on the next restart.
- **Fix (T199):** `IncidentEntry.deltaMs` could read negative when the
  wall clock moved backward between two `IncidentRecorder.record()`
  calls (an NTP sync, a manual clock edit, a timezone change) — a
  confusing figure in a diagnostics timeline. `deltaMs` is now always
  clamped to `>= 0`, and a new `clockRolledBackMs` field (`int?`, `null`
  unless a rollback was observed) carries the raw negative delta so the
  fact a clock jump happened is never silently hidden by the clamp.
  Included in the JSON export (omitted entirely, not just `null`, when
  there was no rollback — an old exported bundle without this field
  decodes identically to a real "no rollback" entry).
- **Fix (T198):** `JourneyPrefetcher`'s opt-in `routeObserver` (T139) only
  ever fired `notifySignal` on `didPush` — returning to a previous screen
  (`didPop`) or a route being swapped in place (`didReplace`) silently
  missed the journey signal entirely. Now fires on all three: a pop uses
  the REVEALED previous route's name (the screen the user is now looking
  at again), not the one being removed; a replace uses the new route's
  name. No new API — same `notifySignal` entry point, same behavior for
  a host that only ever sees `didPush` fire.
- **Fix (T197):** `FillRateMonitor`, `FillRateBaselineMonitor`, and
  `BypassAuditTrail` now throw a real `ArgumentError` for an invalid
  constructor value (`lowFillRateThreshold`/`regressionThreshold` outside
  `(0, 1)`, `rollingWindowSize`/`minSamples`/`maxEntries` `<= 0`) instead
  of relying on a debug-only `assert` (compiled out of release builds) or
  — for `BypassAuditTrail` — nothing at all. Before this, an invalid
  value in a release build either left the monitor silently useless
  (never alerting, or alerting on almost everything) or, for a negative
  `BypassAuditTrail.maxEntries`, crashed for real the first time its ring
  buffer tried to trim. None of the values are silently clamped into
  range — that would hide the same misconfiguration a different way.
- **New (T196):** `ConsentSettings.copyWith` gained `clearAskedAt`/
  `clearCountry` (`bool`, default `false`) — `askedAt`/`country` are
  themselves nullable fields, so `copyWith(askedAt: null)` was previously
  indistinguishable from "parameter omitted" and could never actually
  clear either one once set (e.g. for a privacy/data-erasure flow).
  Purely additive: every existing call site is completely unaffected.
  Passing both a value and its matching `clear*: true` flag together
  throws an `AssertionError` in debug mode (the two are contradictory).
- **Fix (T195):** `signComplianceReport`/`signJsonPayload` could mint two
  DIFFERENT Ed25519 signing keys when two calls raced on first use
  (before any key was persisted) — both read no stored key, both minted
  their own, and whichever write won silently stranded the other call's
  already-returned signature under a key that would never again match
  what's persisted, breaking the "same install, same public key across
  every export" guarantee. A process-wide async lock now serializes the
  mint-and-persist step: a concurrent caller shares the same in-flight
  result instead of racing it, and a caller arriving after the lock
  releases re-reads the (by-then persisted) key instead of minting a
  second one.
- **Fix (T194):** `MonetizationArbitrator` used to treat a genuinely
  CONFIRMED $0 trailing eCPM (≥ warm-up samples, real average revenue is
  exactly 0 — e.g. a run of pure house ads/cross-promo) identically to
  "no evidence yet", always failing open to `showAd` and defeating the
  point of the arbitrator for exactly the format it should most want to
  veto. It now distinguishes the two internally: only a genuine absence
  of qualified samples fails open; a confirmed `$0` is treated as real
  evidence below threshold, same as any other low eCPM (still subject to
  the same `maxVetoRate` guardrail, still always invokes a registered VIP
  likelihood estimator). `estimatedEcpmMicrosFor`'s public return value
  is unchanged (still `int`, still `0` for both cases) — this is purely
  an internal decision-logic fix, not a public API change.
- **Fix (T193):** `AdManager().runIntegrationSelfCheck()`'s per-format load
  checks used to wait ONLY for a fresh `AdLoadEvent`, which a real
  adapter never emits when it silently reuses an already-fresh, still-ready
  cached ad (e.g. `AdMobAdapter`/`AppLovinAdapter`'s "already ready/fresh
  — keep it" short-circuits) — a genuinely healthy, preloaded slot timed
  out and was reported as a false FAIL. The checks now look at the slot's
  own state directly (readiness-first): an already-`ready` slot passes
  immediately, an already-`cooldown` slot fails immediately with its last
  error code, and only a genuinely in-flight load still waits, up to the
  same timeout as before.
- **Fix (T192):** `DebugAdOverlay` (debug-only, never shown to real users)
  could crash with `setState() or markNeedsBuild() called during build`
  if the panel was already expanded and a different, unrelated widget
  synchronously mutated an `AdSlot`'s state (or called
  `AdManager().initialize()`) from its own `initState()`/`build()` — e.g.
  a demo page preloading an interstitial in `initState()`, the same
  pattern this package's own example app uses. The overlay's internal
  `ValueListenableBuilder`s now defer their rebuild to the next frame
  instead of reacting synchronously.
- **New (T187):** `AdSafetySnapshot` gained `fullscreenClickThroughRate`
  — the exact fullscreen-only click/impression ratio the real CTR-anomaly
  gate (round-39) evaluates, distinct from the pre-existing
  `clickThroughRate` (which mixes in banner/mrec/native traffic and can
  disagree with what actually triggered an anomaly). `AdDiagnostics`
  gained `pendingRevenueChecks` (`int?`, `null` unless the host calls the
  new `AdManager().enableRevenueIntegrityLedger(...)`) and
  `recentRevenueIntegrityIncidents` (`int`, always computable from
  `AdManager().incidentRecorder`) — so "why is revenue low today" answers
  live in the same one-shot snapshot as the rest of `AdDiagnostics`.
- **New (T186):** `RevenuePanel` (non-compact mode) now shows a
  per-`AdSlotType` revenue breakdown below the existing session total —
  each type present shows its own USD total and impression count, sorted
  alphabetically. Same USD-only skip rule as the session total (a
  non-USD `AdRevenueEvent` is never folded into either figure). Compact
  mode (`RevenuePanel(compact: true)`) is unchanged — still a one-line
  summary with no breakdown.
- **New (T185):** `AdShowEvent`/`AdRevenueEvent` gained an optional
  `requestId` (`String?`) — a per-load correlation ID both adapters now
  stamp once and carry through to both events for that same ad instance.
  `RevenueIntegrityLedger` matches a show to its revenue event EXACTLY by
  `requestId` when both sides carry one, instead of only guessing by
  `(providerTag, type, placement)` within a time window (the T150
  heuristic — unchanged, and still the fallback whenever `requestId` is
  null on either side: banner/mrec/native never set it, since neither
  emits a matching `AdShowEvent`). Purely additive: `requestId` defaults
  to `null`, no existing constructor call or event listener breaks.
- **New (T181):** `PlacementSpec.minIntervalOverrideMs` — a per-placement
  override for `AdSafetyParams.minTimeBetweenFullscreenAds` (the app-wide
  "minimum time between two fullscreen ads" throttle), same override
  contract as the existing `frequencyCapOverride`: applies for that
  placement's show calls only, `null` (default) leaves the app-wide
  throttle unchanged. Also threaded through `canShowInterstitial`/
  `canShowRewardedAd`/`canShowRewardedInterstitialAd` (now accept an
  optional `placement` parameter, default `AdPlacement.unspecified` —
  existing callers unaffected) and the resume-triggered App Open flow
  (matched against `AdPlacement.splash`, its default placement), so the
  documented `AdScreenState` pre-check pattern and the automatic resume
  path both see the same override the real show call does. A negative
  `minIntervalOverrideMs` is rejected outright (falls back to the
  app-wide value) rather than silently disabling the throttle — `0`
  remains the real, intentional "no throttle for this placement" value.
- **Internal (T180):** the six opt-in feature `enable*`/`disable*` pairs
  (arbitrator, fillRateMonitor, waterfallTuner, providerFailoverAdvisor,
  selfHealingObserver, journeyPrefetcher) each repeated the same
  "dispose old, assign new" body. Replaced with a shared generic
  `_swapDisposable` helper. Public API (names/signatures) and behavior
  are unchanged — verified by re-running the full test suite plus each
  feature's own on-device integration test.
- **Fix (T177):** `MonetizationDigitalTwin.forecastDailyCap()` used to treat
  a negative `hypotheticalDailyCap` as silently meaning "uncapped", with no
  documentation of that behavior and no test for it — a dev who passed a
  negative number by mistake got a real-looking forecast for a policy they
  never asked to model. Now asserts `hypotheticalDailyCap >= 0` (stripped
  in release builds, same cost/benefit as this internal debug/preview
  tool's other guards); `0` remains a valid input, documented as
  forecasting "fullscreen ads disabled entirely".
- **Fix (T213):** `tool/release_readiness_gate.sh`'s `secret_scan` stage
  could report "release gate: secret passed" with a false PASS when `rg`
  (ripgrep) was not installed — its `rg` call sat inside an `if (...)`,
  where bash's `set -e` does not apply, so `rg`'s "command not found"
  (exit 127) was indistinguishable from "no secret found". Confirmed live:
  reproduced with `rg` genuinely absent from a clean subprocess PATH.
  `api_check` had the same missing-dependency gap, though it already
  failed (just with a confusing raw error) rather than silently passing.
  Both stages now check for `rg` explicitly first, failing with a clear
  diagnostic instead of either a silent pass or an unclear crash. Rewrote
  the test suite to run the real script as a real subprocess (the old
  test only grepped the script's source text for stage names — it could
  not have caught this at all), with real pass/fail fixtures for both
  stages, and removed a vacuous widget test (rendered hand-typed labels)
  and device test (asserted a tautology) — this is a CI shell script with
  no real device-specific behavior to prove.
- **Test (T207):** the SDK lifecycle contract suite only exercised
  `initialize→load→show→background→destroy→reinitialize` through
  `debugSetAdapter`/`debugConfig`, bypassing the real `initialize()`/
  `destroy()` path entirely, and never dispatched an app-lifecycle
  transition at all (unrelated `Text` widget in the widget test; a bare
  double-`destroy()` in the device test). Added a real end-to-end chain
  test through `AdManager().initialize()` (routed via
  `debugAdapterFactory`), dispatching background/resume through the real
  `WidgetsBinding.handleAppLifecycleStateChanged` (not calling the
  callback directly, which would still pass even if `initialize()` never
  registered the observer), with an observable pause/resume side effect
  instead of just "didn't throw"; a genuine mid-native-init `destroy()`
  race (not merely after both concurrent calls settle); and both
  concurrent callers verified to receive the real init result. Rewrote
  the widget test around a real `BannerAdWidget` surviving `destroy()`
  while mounted, and the device test to mirror the same real chain on a
  physical device. No production code changed; it was already correct.
- **Test (T205):** the VIP CLI secret-handling tests (`vip_mint.dart`/
  `vip_keygen.dart`/`vip_crl_mint.dart`) only grepped the tool source for
  certain substrings, which cannot observe the actual security property
  (a real process's stdout/stderr never containing the private key).
  Rewrote to spawn each CLI as a real `dart run` subprocess and inspect
  its real stdout/stderr/exit code, and to verify a subprocess-minted
  key/CRL actually round-trips through the SDK's own real
  `verifySignedVipKey`/`verifySignedCrl` — not just "the CLI exited 0 and
  printed something key-shaped". Also removed a vacuous widget test
  (rendered and matched a hand-typed string, same fake shape as T215's)
  and a device test that only checked an irrelevant, always-unset
  environment variable — this is a dev-machine/CI CLI tool with no real
  device-specific behavior to prove. No production code changed; it was
  already correct.
- **Fix (T210):** `ConsentFallbackReason.offline`/`.staleRevision` were
  declared but never produced — every UMP failure was classified as
  `timeout`/`platformError` even when the device had no connectivity, and
  a fallback recorded under an old policy revision was treated as current
  forever. Now: `AdManager` records `offline` when there is a REAL,
  confirmed connectivity reading showing the device is offline (not the
  optimistic pre-ready default — a `requestUmpConsent()` call from splash,
  before the connectivity watch has resolved, still falls back to
  text-based classification); `ConsentManager` reclassifies a persisted
  fallback whose `policyRevision` is in the SDK's own UMP namespace
  (`'ump-vN'`) but doesn't match the current `kUmpPolicyRevision` as
  `staleRevision` on load, without touching a host's own ATT/custom-reason
  fallback records. The hardcoded `'ump-v1'` literal is now the shared
  `kUmpPolicyRevision` constant. Also added `ConsentManager.fallbackListenable`
  — `recordFallback()`/`clearFallback()` previously updated state with no
  notification at all, so a host status widget could never react to it.
  Replaced a vacuous widget test (rendered and matched a hand-typed
  string) with one exercising the new listenable for real, and fixed the
  device test file, which was missing
  `IntegrationTestWidgetsFlutterBinding.ensureInitialized()`.
- **Test (T211):** the ad-load coalescing tests (unit, widget, device
  integration) only asserted the slot's end state after concurrent load
  calls, which is identical whether the manager's coalescing map actually
  joined the calls or let every one of them through as a real native
  request — `AdSlot.beginLoad()`'s own "already loading" guard already
  masks the difference. Rewrote them to count real adapter invocations,
  added a case proving a failed load's retry issues a genuinely new
  native request (not a stale join), and a case proving
  `debugResetGuardState()` (the same path `destroy()`/reinit use)
  correctly invalidates an in-flight coalesced load so the next call
  starts fresh. Also fixed the device test file, which was missing
  `IntegrationTestWidgetsFlutterBinding.ensureInitialized()` and so never
  ran through the integration_test device harness at all. No production
  behavior change — `_coalesceAdLoad`/`_invalidateCoalescedLoads` were
  already correct; only the tests proving it were not.
- **Fix (T215):** `CompatibilityMatrix.isSupported()` — the check that CI's
  compatibility gate is built on used to compare hardcoded constants
  against themselves and could never fail, so a genuinely incompatible
  Flutter/API-level bump in CI would have passed silently. Now compares
  the real target against the declared, reviewed `minimum` matrix entry
  for the same platform+provider: unknown combinations are rejected by
  default (fail-safe), and — after a second audit round — an unapproved
  *newer* Flutter version is rejected too (exact match on `flutter`, not
  a `>=` floor), since a new Flutter release isn't proven compatible just
  by being newer. `apiLevel` keeps a `>=` floor (a higher Android API
  level is genuinely still supported). `tool/validate_compatibility_matrix.dart`
  now reads the real running `flutter --version --machine` instead of a
  hardcoded string. Also removed a vacuous widget test that only rendered
  and matched a hand-typed string (`CompatibilityMatrix` has no UI
  anywhere in the SDK).
- **Internal (T212):** `AdStressHarness`/`AdStressReport` — briefly added
  and exported publicly in this same "Unreleased" window, never actually
  published — turned out to be a disconnected simulation with no
  connection to `AdManager`/`AdEvent`/a real adapter at all. Rewritten to
  genuinely exercise the SDK (real event bursts, real
  `initialize()`/`destroy()` reinit cycles) and moved out of the published
  package into the SDK's own test suite, since every real check it makes
  needs test-only seams that can't legitimately live in `lib/`. No
  behavior change for any real consumer: this was never shipped in a
  release.
- **New (T174):** `AdSafetyConfig.canShowAppOpenOnResumePeek()` — a
  side-effect-free "would this pass right now" variant of
  `canShowAppOpenOnResume()`, safe to call repeatedly (e.g. to drive UI)
  without consuming the one-shot cold-start flag, the pending-resume gate,
  or growing the rolling resume-timestamp window used for the rapid-resume
  cap. Same split as the existing `canShowFullscreenAd`/
  `canShowFullscreenAdPeek` pair.
- **New (T173):** `DebugAdOverlay`'s slot panel now shows a row for banner/
  MREC/native too — previously only App Open/Interstitial/Rewarded had one.
  Unlike those three (exactly one `AdSlot` each), banner/MREC/native are
  keyed per widget instance, so the new row is a count-by-state summary
  (`Banner  (2) ready=1 loading=1 fails=0`) across every currently-mounted
  instance rather than one line per instance.
- **Fix (T171):** `ProviderFailoverAdvisor(consecutiveFailureThreshold:)`,
  `WaterfallTuner(rollingWindowSize:)`, and `IncidentRecorder(capacity:)`
  now validate their config parameter — a `<= 0` value used to make each
  class misbehave silently or crash instead of doing what a dev almost
  certainly intended: `consecutiveFailureThreshold <= 0` recommended a
  provider failover immediately, with zero real failures; `rollingWindowSize
  <= 0` silently disabled all sample tracking (0) or threw a `RangeError`
  on the very first trim (negative); `capacity <= 0` threw a `RangeError`
  on the very first `record()` in release builds, where the class's old
  bare `assert` is stripped. All three now log a `SafeLogger.w` warning and
  substitute that class's own existing default instead.
- **Internal (T170):** silenced the `deprecated_member_use` warning
  `flutter analyze` raised on `TickerMode.of` in `BannerAdWidget`/
  `MrecAdWidget`. Flutter's own replacement (`TickerMode.valuesOf`) doesn't
  exist before v3.35.0-0.0.pre, and this package still declares
  `flutter: '>=3.27.0'` in `pubspec.yaml` — switching now would compile-fail
  for any consumer on an older Flutter, so the call itself stays and the
  warning is suppressed with `// ignore: deprecated_member_use` instead
  (the same workaround Flutter's own deprecation doc comment on `of`
  recommends). No behavior change.
- **New (T168):** App Open (and every other fullscreen ad path) could show
  over a host's own custom overlay (e.g. a manually-inserted `OverlayEntry`
  via `Overlay.of(context).insert(...)`) — `AdScreenRouteLogger.isDialogOnTop`
  only tracks `PopupRoute`s pushed through a `Navigator`, and Flutter has no
  public API for the SDK to hook an arbitrary host overlay automatically.
  New opt-in API: `markCustomOverlayOnScreen(bool value)` /
  `customOverlayOnScreen` (same pattern as `markUmpFormOnScreen` for the
  native UMP form) — call with `true` right before inserting your overlay
  and `false` right after removing it. Folded into the SDK's fullscreen
  mutex the same way `isDialogOnTop` already is, so it blocks App Open on
  resume AND `canShowInterstitial`/`canShowRewardedAd`/
  `canShowRewardedInterstitialAd`.
- **Fix (T167):** the consent dialog's ad-partners caption unconditionally
  read `'Ad partners: Google AdMob, AppLovin'`, regardless of which network
  the app is actually configured for — this SDK supports exactly one active
  provider per app (AdMob XOR AppLovin, never both at once), so this
  overstated who receives the user's data for every single integration, not
  just a rare misconfiguration. `ConsentDialogStrings.adPartnersLabel`'s
  default now contains a `{providers}` token
  (`ConsentDialogStrings.autoProvidersToken`), auto-substituted by
  `AdManager`/`ConsentManager` with the network the app's `AdConfig.provider`
  actually names. A fully custom `adPartnersLabel` (no token in it) is left
  untouched; a custom template that reuses the token still gets real
  substitution.
- **Fix (T166):** `CcpaOptOutToggle` read `AdManager().consentManager?.listenable`
  exactly once, at `initState()` — if this widget mounted before
  `AdManager().initialize()` finished (e.g. shown during the first few
  seconds of a cold start), `consentManager` was still null and the toggle
  stayed permanently disabled for the rest of that mount, even once init
  genuinely finished moments later. It now also listens to
  `AdManager().initRevision` (the same general-purpose "SDK init state
  changed" signal `BannerAdWidget` already uses for its own analogous
  problem) and re-attaches to the real listenable the first time it becomes
  available, so the toggle self-recovers without the host having to leave
  and re-enter the screen.
- **Fix (T165):** the fill-rate baseline monitor's day computation
  (`AdPreferences.recordFillRateBaselineSample`/`getFillRateBaselineHistory`,
  `FillRateBaselineMonitor._baselineFor`) used `DateTime.now()` (local time),
  independent from the anti-fraud daily-cap counters' UTC-based, clock-
  rollback-clamped `_todayUtcClamped`. A device timezone change could split
  or merge a day's fill-rate samples differently than the anti-fraud
  counters saw the same moment — a reporting/alerting inconsistency only,
  never a cap-enforcement issue. All three now compute "today" through the
  exact same UTC day key (`AdPreferences.todayUtcClamped`, a new public
  wrapper). Also fixed a parsing bug this surfaced: pruning stored history
  parsed a bare `'YYYY-MM-DDZ'` string, which `DateTime.tryParse` silently
  rejects (not valid ISO8601) — every stored day looked "too old" and was
  discarded on every read-modify-write. Fixed to `'YYYY-MM-DDT00:00:00Z'`.
- **Fix (T164):** `applyConsentToProviders` only recorded consent as
  actually applied to the providers when BOTH AdMob's and AppLovin's writes
  succeeded, even for an app that only ever configures ONE via
  `AdConfig.provider`. Now only the provider(s) `config` actually names need
  to have applied; `config == null` keeps the original, more conservative
  require-both behavior.
- **Fix (T163):** `SelfHealingObserver`'s dedupe (one recommendation per
  (type, placement, recommendedProvider)) used a plain `Set<String>` that
  never forgot a key — once a (format, placement) pair had been recommended
  in one direction and later the other, a genuine LATER need to recommend
  the exact same thing as the first time stayed silent forever, since that
  key was already "seen". Now keyed to WHEN it last fired instead: a new
  `reobserveAfter` parameter (default 7 days) lets the same key fire again
  once enough time has passed, while still suppressing a near-duplicate in
  the short term exactly as before. `AdPreferences.getSelfHealingObservedKeys`/
  `setSelfHealingObservedKeys` (a plain key list, no timestamps) are replaced
  by `getSelfHealingObservedAt`/`setSelfHealingObservedAt` (key → last-fired
  timestamp) under a new pref key — the old data is left unread rather than
  migrated, since it has no timestamp to migrate from.
- **Fix (T160):** `_lastShownPlacement` (the map used to attribute a
  revenue event to the placement the ad was actually shown under, rather
  than whatever the adapter reports) was not cleared by
  `destroy()`/reinit-without-destroy(), unlike every other per-session
  field in `_resetGuardState()`. A stale placement from a session that just
  ended could misattribute a revenue event the new session's adapter
  reports before its own first show call. Now cleared in
  `_resetGuardState()` alongside the other session-boundary resets there.
- **Fix (T158):** AppLovin's `onAdLoadFailedCallback` disambiguated a
  banner-vs-MREC failure purely by comparing the reported ad-unit id
  against the configured `bannerId`/`mrecId` — a host configuring the SAME
  ad-unit id for both (a plausible copy-paste mistake) made that comparison
  always false, silently misrouting every MREC failure into the banner
  branch (no data lost, just a slower — 30s watchdog instead of immediate —
  recovery for the MREC side). `initialize()` now logs a warning if
  `bannerId == mrecId` (both non-empty), and the failure callback falls back
  to checking which registry actually has a load in flight to disambiguate
  the genuinely-shared-id case, only defaulting to the pre-existing
  banner-branch behavior when truly ambiguous (both loading at once).
- **Fix (T162):** `JourneyPrefetcher` keys its internal timing map as
  `'$signal|${type.name}'` but split every key on EVERY `|` when matching an
  `AdShowEvent` back to its signal, assuming exactly 2 parts. A `signal`
  string containing a literal `|` (a route name like `/store|deal` under
  auto-mode, or any host-chosen signal string) produced a key with more than
  2 parts, which then never matched — silently disabling time-to-show
  tracking and prefetch timing for that signal forever, with no error.
  Splits on the LAST `|` instead, correctly recovering the type suffix
  regardless of how many `|` the signal itself contains.
- **Fix (T161):** `requestAttIfNeeded()` had no guard against overlapping
  calls — a caller triggering it twice before the first resolved (a bug, or
  a user tapping a "grant permission" button twice) could present Apple's
  native ATT prompt a second time, an undocumented and untested interaction.
  A second call now joins the same in-flight request and resolves with its
  result instead of triggering native `requestAuthorization` again.
- **Fix (T159):** `AdSafetyConfig.placementDailyCapReached` used `??` between
  `maxPerPlacementAdsPerDay` and `maxPerPlacementAdsPerDayById` when both had
  an entry for the same placement — whichever map was checked first silently
  won, ignoring a stricter cap configured in the other map, contradicting
  both maps' own doc comments ("checked in ADDITION to"). The stricter
  (smaller) of the two now always applies when both are set; unchanged when
  only one is set, and `capOverride` still wins over both as before.
- **Fix (T157):** `BannerAdWidget`'s AdMob adaptive banner sized itself from
  `MediaQuery.of(context).size.width` — the FULL SCREEN — regardless of what
  container it was actually placed in, so a banner inside anything narrower
  than the screen (a popup, a dialog, a sidebar, a split-screen pane)
  requested a too-wide banner and overflowed its own container. It now
  measures its real available width and requests a banner sized for that
  instead, with MediaQuery kept only as the fallback for a genuinely
  unbounded container (unchanged full-screen behavior otherwise). Also
  catches a later resize of that container — a rotation, a split-screen
  pane resizing, even one animated by an `AnimatedContainer` with no widget
  rebuild at all — and reloads at the corrected width, debounced so a
  continuously-animating container settles to a single reload instead of
  reloading every frame. `MrecAdWidget` needed no change: its size is
  fixed (300×250) regardless of the width value it passes internally.

## [2.9.20] - 2026-09-06

Round-40 audit — 3 independent reviews (in-session Claude + `codex` + `agy`/
Gemini, each on an isolated repo copy) plus a rebuttal of two user-raised
doubts (docs accuracy, example-app completeness). 0 BLOCKER. 1 MAJOR found and
fixed:

- **Fix (MAJOR, R40-A):** `IabStorage.usPrivacyOptedOut()` and
  `_gppUsStatesOptedOut()` used to return the first *non-null* GPP signal in a
  fixed priority order (US National → California → other US states; and,
  within the 19 states, section-ID order), even when that signal was `false`
  (Did Not Opt Out). A CMP that legitimately populates more than one section
  at once (e.g. a coarse national default alongside a jurisdiction-specific
  override) could have a real opt-out in a lower-priority section
  permanently shadowed by an earlier section's stale/default "did not opt
  out". `true` now wins over `false` from any GPP tier/state; only `null`
  (no section has a usable signal at all) falls through. Found by `codex`,
  independently confirmed against source by both in-session Claude passes;
  missed by `agy`.
- **Fix (MAJOR, R40-A round 2 — a second independent re-review, R2-01):**
  the legacy `IABUSPrivacy_String` was left OUT of the round-1 fix above —
  still checked first and returned immediately if parseable, fully
  authoritative even over a real GPP opt-out. That is the identical failure
  shape round 1 fixed between GPP tiers: neither the legacy string nor GPP
  carries a timestamp, so there is no basis to treat one as more definitive
  than the other. The legacy string is now unioned into the same
  true-beats-false rule as every GPP tier, not treated as a separate
  short-circuit. The existing "legacy takes precedence" test's expectation
  flipped (legacy `N` + GPP opted-out now correctly reads `true`, not
  `false`) and a second test locks in the reverse direction (legacy opted
  out + GPP `N` still `true`).
- **Docs (MINOR):** `CHANGELOG.md` was missing "Published to pub.dev." on
  the 2.9.17-2.9.19 entries — verified via the live pub.dev listing that
  2.9.19 is in fact published and matches local source; only the note was
  missing, not the content.
- **Example app:** added two demo screens exercising features the README
  already documented but the example never ran: `RemoteAdSafetyProvider`
  (T88, `RemoteSafetyDemoPage` — destroys + re-initializes the SDK with a
  live provider, then calls `refreshRemoteSafetyParams()` for real) and
  `AdReadinessSplashController` (T94, `ReadinessControllerDemoPage` —
  destroys + replays splash through the controller shortcut instead of the
  manual flow). `home_page_test.dart` updated (19 → 21 tiles) with new
  navigation tests for both.
- **Fix (IMPORTANT, independent re-review):** both new demo pages let a
  fast double-tap start a second `destroy()`/`initialize()` (or a second
  splash route) before the first one's await resolved — the button only
  disabled once everything had already finished. Added a `_busy` guard on
  both, disabling the button synchronously on the first tap and resetting
  in a `finally` (with a `mounted` check). Confirmed fixed with two
  double-tap regression tests run for real on a Pixel 7 Pro (see below) —
  the fix caught the exact race the review named, no theoretical-only fix.
- **UX (MINOR, independent re-review):** `RemoteSafetyDemoPage`'s "Apply
  provider" mutates the app's live `AdSafetyConfig` globally, with no way
  back short of restarting the app — every other demo screen visited
  afterward would silently inherit the simulated remote values. Added a
  visible warning card and a "Restore demo defaults" button that detaches
  the provider and re-initializes on `DemoConfig`'s own defaults.
- **Fix (IMPORTANT, round 2, R2-02 — test-quality):** the two double-tap
  regression tests originally only asserted a converged end-state ("Provider
  already wired" / exactly one demo-page instance), which two racing
  operations could equally reach — not proof the guard actually stopped a
  second invocation. `RemoteSafetyDemoPage` and `ReadinessControllerDemoPage`
  each gained a `@visibleForTesting` invocation counter
  (`debugApplyCallCount`/`debugReplayCallCount`, incremented only past the
  `_busy` guard); both double-tap tests now assert the counter is exactly
  `1` on top of the end-state checks.
- **Fix (MINOR, round 2, R2-04 — resilience):** `_applyProvider`,
  `_pushUpdate`, `_restoreDefaults`, and `_replay` used `finally` without a
  `catch` — a destroy()/initialize()/refresh failure would surface as an
  unhandled async error with the status stuck on "Applying.../Fetching...".
  All four now catch and surface the failure in the UI (status text or a
  SnackBar) instead.
- **On-device proof (Pixel 7 Pro, real hardware, `AD_PROVIDER_ADMOB=true`):**
  6 `integration_test/` files (7 tests total), each run individually for
  real and passing — `round40_gpp_shadow_test.dart` (2 tests: the R40-A
  fix's cross-tier and within-states shadowing scenarios, off the real
  platform preference store, not a mock), `round40_remote_safety_demo_test.dart`
  (wires a real provider, drags the slider, calls
  `refreshRemoteSafetyParams()`, and asserts `AdSafetyConfig`'s live
  snapshot actually changed to the pushed value),
  `round40_remote_safety_demo_doubletap_test.dart` (asserts
  `debugApplyCallCount == 1`), `round40_remote_safety_demo_restore_test.dart`
  (round 2, R2-03 — confirms "Restore demo defaults" actually puts the live
  `AdSafetyConfig` back on `DemoConfig`'s own default, not just that the
  button doesn't crash), `round40_readiness_controller_demo_test.dart`
  (destroys + replays splash through the real controller, confirms
  `onReady` fires and the SDK is initialised again), and
  `round40_readiness_controller_demo_doubletap_test.dart` (asserts
  `debugReplayCallCount == 1`).
- 5 more unit fixtures for the R40-A fix's remaining cross-tier/malformed/
  legacy-boundary combinations (3 from the first re-review, 2 from R2-01),
  reusing only already-verified fixtures (no new hand-encoded GPP
  bit-strings). 1656/1656 unit/widget tests passing before this round's
  additions, 1662/1662 after, plus 6 example-package widget tests
  updated/added (including the 2 new R3-01 failure-branch tests) and 6
  example-package `integration_test/` files (7 tests) added. 2 known MAJOR-tier trade-offs re-confirmed unchanged from round 39
  (Android trial/VIP replay via reinstall/clear-data — no-backend design,
  documented in README's VIP section).
- **Fix (IMPORTANT, round 5 — a fifth independent re-review):**
  `test/iab_storage_us_states_parallel_test.dart` still asserted the
  pre-R40-A expectation (Virginia's earlier, non-null `false` beats Rhode
  Island's `true`) — this session had re-run `test/ad_manager_core_test.dart`
  directly after every follow-up fix but never the SDK's full `test/` suite
  again after round 1's `_gppUsStatesOptedOut()` change, so this file's own
  contradiction with the round's own fix went unnoticed until an
  independent reviewer ran the whole suite. Updated to expect `true`
  (Rhode Island's real opt-out wins), reusing the same already-verified
  fixtures. Full suite now **1662/1662, 0 failures** (previous full runs
  this round showed 1 failure each time, but a different, genuinely
  order-dependent pre-existing flake in a timing-sensitive test unrelated
  to this round — see `doc/audit/audit_round40_consolidated.md`'s
  Addendum for detail on telling the two apart).
- **Note on R40-A's design:** honoring `true` from any GPP tier/state/legacy
  string over `false` from any other is intentionally fail-closed for
  privacy — a stale signal can still force an opt-out even if it is no
  longer the user's current one. That is the accepted tradeoff (a
  wrongly-honored opt-out costs some monetization; a wrongly-ignored one is
  a compliance risk), not an oversight.
- **Fix (IMPORTANT, round 3, R3-01):** `RemoteSafetyDemoPage._applyProvider()`
  and `_restoreDefaults()` passed `AdManager().initialize()` an
  `onComplete` callback that discarded its `success` flag — a legitimate
  `onComplete(false, gaid)` (init failing without throwing) still fell
  through to the success branch, claiming "Provider wired"/"Restored" while
  the SDK was actually left uninitialised right after `destroy()`. Both now
  capture `success` and branch on it, showing a failure status instead. A
  real `initialize()` failure is network-dependent and not reliably
  forceable from a test, so `debugForceApplyResult`/
  `debugForceRestoreResult` (`@visibleForTesting`, round 4 follow-up) skip
  the real destroy()/initialize() call and inject the outcome directly,
  isolating just this branch's UI handling — `example/test/
  remote_safety_demo_page_test.dart` (2 new tests) exercises both failure
  paths deterministically; the real call's happy path stays proven
  on-device by the existing round40 integration tests.
- **Doc (MINOR, round 3, R3-02):** `usPrivacyOptedOut()`'s doc comment still
  described the pre-R2-01 "legacy is authoritative" behavior a few
  paragraphs above the R2-01 note that superseded it — reworded as an
  explicit historical note so a future maintainer can't restore the old
  precedence by pattern-matching the wrong paragraph.
- Three rounds of independent adversarial review (`codex`, isolated repo
  copy each time, no shared context with this session or with each other):
  round 1 scored 7/10 (GPP fix itself sound; flagged the double-tap race,
  now fixed, and said example test coverage didn't yet match what this file
  claimed). Round 2 scored 6.5/10 and blocked production on R2-01 (above,
  fixed) plus R2-02/R2-03 (above, fixed). Round 3 scored 7/10 and blocked
  production on R3-01 (above, fixed) plus R3-02 (above, fixed). See
  `doc/audit/audit_round40_consolidated.md`'s Addendum for all three
  reviews in full and what shipped in response to each.

## [2.9.19] - 2026-09-05

Round-39 audit (4 independent reviewers: codex, Gemini, and two independent
Claude passes that disagreed on one finding — see `doc/audit/audit_claude.md`
for how that got resolved by writing a regression test instead of taking
either side's word for it). Fixes 4 MAJOR and 3 MINOR bugs, all with
regression tests, plus a real product gap:

- A second `setConsent()` race the round-38 epoch guard didn't reach: the
  AppLovin-only COPPA re-initialisation branch wrote to the real native SDK
  unconditionally, so an older, superseded consent-toggle call could still
  land after a newer one.
- `ConsentManager`'s own disk write (`_persist()`) wasn't serialized: two
  overlapping `set()`/`reset()` calls' real platform-channel writes could
  finish out of order, leaving a stale value on disk that silently reverted
  the user's actual choice the next time the app launched.
- The invalid-traffic (CTR) fraud detector shared one counter across every
  ad type; a continuously auto-refreshing banner/MREC could dilute the ratio
  enough for a bot clicking only fullscreen ads to slip under the threshold.
  Fullscreen now has its own counter.
- The UMP consent retry (both the periodic backstop and the offline→online
  reconnect path) could throw an unhandled zone error and crash the host app
  repeatedly on flaky connectivity combined with a broken UMP integration —
  now wrapped in `runZonedGuarded`, matching the pattern already used at
  init time.
- **Banner/MREC widgets now auto-pause when scrolled off-screen or obscured**
  (new `visibility_detector` dependency), and gained a manual `active`
  parameter — required specifically for a bare `IndexedStack` bottom-nav tab,
  which the automatic detector genuinely cannot see (Flutter never calls
  `paint()` on a non-current `IndexedStack` child, and that's exactly what
  the detector's re-evaluation depends on — see `BannerAdWidget`'s class doc
  comment).
- 3 MINOR: a missing footgun-warning when no privacy-policy link is
  configured for the consent dialog; `AdRetryPolicy.jitterFraction` near
  1.0 could collapse backoff to near-zero (now floored at 10% of the base
  delay); the example app never demonstrated VIP-code revocation (CRL) —
  it now has a demo button.
- Documented (not changed — deliberate design trade-offs of this SDK's
  no-backend architecture): the 1-day trial can be re-farmed on Android by
  reinstalling with Auto Backup off, and a leaked VIP code can be redeemed
  once per device rather than once globally. Both were already partially
  documented; round 39 re-confirmed them and closed the loop.

A second, independent review pass of this round's own fixes (requested
separately, after the above landed) found 3 more real issues in them:

- **MAJOR** — the new `active` param on `BannerAdWidget`/`MrecAdWidget` was
  ignored at the very first mount (only `didUpdateWidget` checked it) — the
  primary `IndexedStack`-tab-not-at-index-0 use case the param exists for
  still loaded an ad on a hidden tab. Fixing it surfaced 3 more independent
  init paths (a destroy→reinit retry, and two consent/VIP-change listeners)
  that also didn't know about `active` and needed the same guard.
- **MINOR** — the COPPA re-init branch's `initialize()` call sat outside its
  own epoch guard, so a superseded call could still trigger a redundant
  extra SDK re-initialisation.
- **NITPICK** — `ConsentManager.resetForTest()` didn't reset two test-only
  static fields, risking cross-test pollution.

A full re-run of all 65 on-device integration test files (Pixel 7 Pro) also
caught a real gap the CTR counter split (above) introduced: one integration
test still used the old banner-based trigger to exercise the CTR-anomaly
event stream, which silently stopped working once banners no longer feed the
fullscreen-only counter — fixed to use the new trigger shape.

Verified: 1656/1656 unit/widget tests, `flutter analyze` clean, no
regressions, plus 65/65 on-device integration test files run for real on a
Pixel 7 Pro (63 genuine passes; 2 failures are a pre-existing, documented gap
— no real AppLovin SDK key is committed in this repo — unrelated to this
round). See `doc/audit/audit_round39_consolidated.md`. Published to
pub.dev.

## [2.9.18] - 2026-09-05

Round-38 audit (4 independent reviewers, 2 further re-audit rounds).
Fixes 2 MAJOR bugs: an AppLovin native ad that failed to load once stayed
permanently blank for the widget's remaining lifetime (its retry timer
never disposed the stale, still-errored bundle); and a `setConsent()`
race where an older, delayed call could silently re-apply a stale
consent value to the real AdMob/AppLovin SDK after a newer overlapping
call had already applied the correct one — the root cause turned out to
be two layers deep (`ConsentManager`'s own persist-then-apply cycle, used
by every `set()`/`reset()`/`showDialog()` call, not just `AdManager`'s),
found only by testing on real hardware, not mocks. Also: the debug
overlay's fill-rate monitor no longer stays latched onto a disposed
monitor after a `destroy()`+`initialize()` cycle; VIP redeem's generic
error handler no longer leaks a raw exception message; 19 sequential GPP
US-state reads now run in parallel (same precedence preserved); and
`dispose()`-while-showing on AppLovin is now logged as diagnosable (no
programmatic dismiss API exists to fully fix it). Verified: 1640/1640
unit/widget tests, `flutter analyze` clean, 2 new on-device integration
tests passing for real on a Samsung device, full app build+install+smoke
run with no crashes. See `doc/audit/audit_round38_consolidated.md`. Published
to pub.dev.

## [2.9.17] - 2026-09-05

Round-37 full re-audit (dual-provider correctness, offline/online
resilience, ad lifecycle, VIP, consent-for-every-country, AdMob/AppLovin
policy compliance). Fixes a BLOCKER: reloading a fullscreen ad in the
background could dispose the ad currently on screen if its cache looked
stale, killing its dismiss callback mid-show. Also: full GPP coverage
(US National + California + 19 US states, previously only partial),
a `Backoff` integer-overflow that silently collapsed exponential backoff
to its base delay after ~51 consecutive failures, a daily/placement ad
cap that had no protection against the device clock being wound
backward, a double-tap that could stack two safety dialogs on top of
each other, three `show*()` paths that left the host with an unhandled
exception and no callback if the underlying adapter threw, and a
consent-dialog visual asymmetry between Allow/Reject flagged by EDPB
deceptive-design guidance. A follow-up independent review then found the
new exception-handling fix could itself double-invoke the host's own
callback if that callback threw — fixed with a delivery-tracking guard,
applied to all four fullscreen show paths including the pre-existing
`showRewardedAd()`. Verified before publish: `flutter analyze` clean,
1632/1632 unit/widget tests, three independent review passes (9.5-9.8/10),
and a full on-device smoke test on a real Samsung S24 Ultra covering every
fix including a real interstitial surviving the reload race and a real
tap dismissing it. See `doc/audit/audit_round37_consolidated.md` for the
complete finding list and scoring rationale. Published to pub.dev.

## [2.9.16] - 2026-09-04

Published to pub.dev. Round-35/36 audit — line-by-line source review of
`lib/src/` (not a diff-since-last-round), split across 4 parallel
independent readers, each cross-checked against real code before being
accepted; a follow-up independent adversarial review of the fix diff
(8.5/10 → gaps closed → 9.5/10, confirmed unchanged by a second
independent pass in round 36). Found and fixed 3 real bugs. Verified
before publish: 1581/1581 unit/widget tests pass (TDD red→green
throughout), `flutter analyze` clean, and a full 48-file on-device
integration run on a real TECNO KJ7 (Android 14, arm64) — 46/48 pass, the
2 failures both pre-existing and unrelated to this release (missing local
AppLovin credentials; a documented `vip_redeem_flow_test` timing flake
tracked since round 34). See `doc/audit/audit_round35_consolidated.md` and
`doc/audit/audit_round36_consolidated.md` for the full record.

**Fixed:**

- `AdCrashGuard.isSdkAttributable()` matched this SDK's package name against
  the **entire** stack trace, not just the throw site. Because the SDK is
  always on the stack immediately beneath any host ad callback it invokes
  (`onReward`, `onAdDismiss`, `onAdClicked`, ...), a genuine bug thrown
  *inside a host app's own callback* was misattributed to the SDK and
  silently swallowed by `installAdCrashGuard()` — logged only to this SDK's
  internal tag, never reaching the host's own Crashlytics/Sentry. Now checks
  only the trace's first (throw-site) frame.
- `ConsentManager.bootstrap()` silently discarded a second call's `prefs`
  argument when a singleton already existed, with no signal that it had
  happened. Now logs a warning via `SafeLogger` when a second call actually
  passes a different `AdPreferences` instance than the one already in use.
- `JourneyPrefetcher` (opt-in, off by default) — a single successful
  `AdShowEvent` credited *every* pending journey signal for that ad type,
  not just the one that actually preceded it. Two different signals pending
  for the same slot type at once (e.g. `"levelStarted"` and
  `"screenEntered"` both awaiting an interstitial) had their time-to-show
  samples conflated. Now resolves only the most recently fired pending
  signal for that type.

**Docs:** replaced hardcoded, release-to-release-drifting test-count and
version numbers in `CLAUDE.md`, `doc/feature.md`, `doc/README_TESTING.md`,
and `doc/architecture.md` with pointers to this file's top entry, so they
stop going stale the way `README.md`'s GPP section did before round 33.

## [2.9.15] - 2026-09-03

Published to pub.dev. Verified before publish: 1571/1571 unit tests, full 48-file
Android integration suite on real hardware (46 pass, 1 skip needing an optional
extra dart-define, 1 self-documented AppLovin-credentials gap — see
`doc/audit/audit_round33_consolidated.md`), and the 4 iOS integration tests
covering this release's changed code (banner/MREC/native/GPP) passing clean on
a real Simulator. Two other iOS integration tests were also checked and confirmed
failing identically on the pre-release baseline (bisected) — pre-existing, not a
regression from this release.

Round-33 audit follow-up — 3 independent agents (codex, agy/Gemini, claude)
re-audited 2.9.14 and, again, disagreed; see
`doc/audit/audit_round33_consolidated.md`. Two real gaps closed this round,
one documented as a known limitation rather than "fixed" because it isn't
fixable from this side of the dependency boundary.

**Fixed:**

- `IabStorage.usPrivacyOptedOut()` only read the legacy `IABUSPrivacy_String`
  — a CMP that writes *only* the newer GPP US National section (some newer
  US-state CMPs do) read as "no signal" instead of "opted out." Now falls
  back to decoding the GPP USNAT (section id 7) Core Segment's `SaleOptOut`/
  `SharingOptOut` fields when the legacy string is entirely absent; the
  legacy string, when present, is still authoritative and unchanged. Scope
  stays deliberately narrow — no attempt to decode the GPP header's own
  section-id list or any section beyond US National — same reasoning m10
  (round 5) gave for not touching GPP at all: mis-parsing a privacy signal is
  worse than not reading one, so only the one well-specified section this SDK
  actually needs is decoded. Test fixtures are real strings generated by IAB
  Tech Lab's own reference encoder (`@iabgpp/cmpapi`), not hand-derived —
  cross-checked this SDK's independent bit-reader against the authoritative
  implementation rather than trusting hand arithmetic on a legal-consent code
  path.
- AppLovin banner/MREC/native `onAdRevenuePaidCallback` had no guard against
  a late callback for an ad-view/native instance the widget has since moved
  on from (a reload handing out a new `adViewId`, or the instance being
  disposed outright) — unlike AdMob's equivalent callbacks, which have
  carried an identity guard since round 6. Plausible-but-unconfirmed finding
  from round 33 (no device reproduction, no test seam for the underlying
  third-party platform views); added the same class of guard preventively:
  banner/MREC now re-check the current live `adViewId` before recording, and
  `_AppLovinMaxAdView`/`_AppLovinMaxMrecView` are now keyed by `adViewId` so
  Flutter tears the old widget down properly on reload instead of reusing its
  element; native now checks the adapter's existing disposed-instance
  tombstone (`AppLovinAdapter.isNativeInstanceDisposed`, newly public) before
  recording.

**Documented, not fixed (known limitation):** `applyConsentToProviders()`'s
AppLovin branch (`ad_consent.dart`) cannot actually confirm its platform
writes succeeded — `AppLovinMAX.setHasUserConsent`/`setDoNotSell` are
fire-and-forget `void` methods in the `applovin_max` package with no `Future`
to await, so the surrounding `try/catch` cannot see a platform-channel
failure the way the (properly awaited) AdMob branch can. This is a dependency
ceiling, not something fixable in this SDK's own code; see the "Known
limitations" section of `README.md` and `doc/AD_PROMPT_FLUTTER.MD` step 4.11
for the full explanation and who this affects (apps with real EEA/UK/
California traffic on `AdProvider.appLovin`).

## [2.9.14] - 2026-09-02

Round-32 follow-up, part 2 — the AppLovin banner/MREC/native revenue-event
gap flagged in 2.9.13's changelog as a separate follow-up.

**Fixed:**

- AppLovin banner/MREC counted an impression and emitted `AdRevenueEvent`
  from `onAdLoadedCallback` (fill time) via the shared static
  `WidgetAdViewAdListener` — the same class of bug round-31 already fixed
  for AdMob's banner/MREC (`onAdImpression` vs `onAdLoaded`). Moved to each
  widget's own `onAdRevenuePaidCallback` on its per-instance `MaxAdView`
  listener — AppLovin's real impression-with-revenue signal for this ad-view
  API (there is no separate pure "displayed" callback here).
- AppLovin native (`NativeAdWidget`) had **no revenue signal wired at all**
  — 0 `AdRevenueEvent`, 0 impression count, for the entire lifetime of the
  SDK on this format, despite `NativeAdListener` supporting
  `onAdRevenuePaidCallback` same as the ad-view listeners. Wired it.

The actual field-mapping logic (which `MaxAd` fields feed which
`AdRevenueEvent` field, the `revenue <= 0` skip) is pulled into a new shared
`appLovinRevenueEvent()` (`applovin_ad_revenue.dart`), reused by the
fullscreen formats' existing `_emitRevenueIfPresent` too — one source of
truth instead of four near-identical copies.

**Known test gap, called out rather than silently left implicit:** the
callback *wiring* (does `MaxAdView`/`MaxNativeAdView` actually invoke
`onAdRevenuePaidCallback` with real data) has no test seam in this repo —
both are third-party platform views, and this package's test suite has
never simulated their native channel. The pure mapping logic has a direct
unit test (`applovin_ad_revenue_test.dart`); the wiring itself needs
on-device verification, done separately (see the round-32 audit doc for the
device-verification log).

Suite: 1562/1562 pass. `flutter analyze`: 0 issues.

## [2.9.13] - 2026-09-02

Round-32 follow-up — user reviewed the ~15 MAJOR findings one by one
(non-technical walkthrough, plain-language pros/cons per item) and approved
a batch of them for this release. Two items were re-verified and downgraded
during that review: audit_round32_deep_consolidated.md's #6 (COPPA-AppLovin
part) was a **false positive** — `AppLovinAdapter` already tears down and
re-initialises correctly when the child-directed flag changes mid-session;
and the AVP1-legacy-VIP-key concern is a **documented intentional
tradeoff** (`signed_vip_key.dart`'s own comment: "AVP1 stays accepted so
keys already handed out keep working"), not a bug — kept as-is, no action.

**Fixed:**

- `remote_ad_safety_provider.dart`: `minSessionDurationBeforeAd` was missing
  the `min: 1` floor round-30 already gave its two sibling throttle fields —
  a remote config of `0` disabled the warm-up anti-bot gate outright.
- `ad_manager.dart`: `canShowRewardedInterstitialAd()` was the one of three
  fullscreen `canShow*` peeks missing the `AdLoadingDialog.isShowing` gate
  its two siblings both have — a host polling it while another fullscreen
  flow's non-dismissable loading dialog was up could open the RI disclosure
  dialog on top of it (UI stuck, not a double-shown ad).
- `example/lib/main.dart`: the splash's buffered App Open `onComplete`
  callback checked `mounted` but not `_navigated` — the exact race
  `AdReadinessSplashController` already guards against (round-31), missing
  from this hand-written example. A slow ad load finishing right as the
  hard-cap timer navigates away could show App Open on top of HomePage.
- `ad_bootstrap.dart`: `bootstrap()` had no bound on how long it waits for
  `AdManager.initialize()` — a wedged native init (never calls back) could
  leave a bare `await bootstrap(...)` splash frozen for the full ~130s
  worst-case retry pileup. New `AdBootstrapOptions.initTimeout` (default
  20s) bounds the wait without cancelling the real init, which keeps
  running and still updates `AdManager`'s state; pass `null` to restore the
  old unbounded wait.

**Documented (no behaviour change, reviewed and kept as intentional):**

- `vip_manager.dart`: the AVP2 bundle-binding check silently skips (rather
  than fails closed) when `PackageInfo.fromPlatform()` throws — comment
  expanded with the explicit tradeoff and a corrected note that passing an
  empty string instead of `null` would NOT actually fix it (verified:
  `signed_vip_key.dart`'s reject condition treats both identically).
- `ad_manager.dart`: `showAppOpenAd`'s `bypassSafety` param got a loud
  doc-comment warning — it is not technically restricted to the splash
  screen, only conventionally.
- `README.md`: documented that `AdScreenRouteLogger`'s dialog-stacking guard
  cannot see `OverlayEntry`-based popups (toast/loading libraries,
  `SnackBar`) — no SDK-side fix possible, host must avoid overlapping them
  with an App-Open-eligible resume window.

**Deferred to a separate follow-up (not in this release):**

- No automatic runtime failover between AdMob and AppLovin when one is
  degraded — provider selection is already fully runtime-configurable
  (`AdConfig.provider`, including a stable per-install A/B cohort via
  `pickProviderCohort()`), but switching mid-session today means the host
  calling `destroy()` + `initialize()` with a different provider itself;
  the SDK does not detect a degraded provider and do that automatically.
  Real feature work, tracked separately.
- AppLovin banner/MREC impression+revenue timing (counted at ad-fill, not
  real display) and AppLovin native ads never emitting a revenue event at
  all — both real, both approved to fix, in progress separately from this
  release.

Suite: 1559/1559 pass. `flutter analyze`: 0 issues.

## [2.9.12] - 2026-09-02

Round 32 — 3 fully independent CLI agents (codex, agy/Gemini, claude) audited
the SDK in parallel, each on its own isolated `git worktree`, with no shared
context with each other or with the orchestrating session. 3 different
verdicts came back (0/1/1 BLOCKER); the orchestrator then read the real
source to verify every BLOCKER claim before trusting it — both turned out
real, independent of each other, both on the consent path. `agy` missed both
(shallower read); its report is kept for reference in
`doc/audit/audit_agy.md` with a correction note, not as a production
verdict. Full detail: `doc/audit/audit_round32_deep_consolidated.md`.

**BLOCKER:**

- **Fix**: `applyConsentToProviders()` (`ad_consent.dart`) swallowed the
  exception from either provider write (AppLovin's fire-and-forget
  `setHasUserConsent`/`setDoNotSell`, or a thrown/timed-out AdMob
  `updateRequestConfiguration`) and then recorded `_lastAppliedToProviders =
  c` unconditionally regardless. Resume/reconcile compares device TCF state
  against that value and skips retrying once they match — so a transient
  write failure during a consent withdrawal could leave a provider
  personalised while the SDK believed it had already gone restrictive. Now
  only records it once both writes actually complete without throwing.
- **Fix**: `IabStorage.tcfAllowsPersonalisedAds()`'s `try { await
  _open().timeout(5s) } on StateError { return null; }` only caught the
  test-harness case. `_open()` itself already swallows everything except
  `StateError`, so the only other way to escape that clause is the
  `.timeout()` firing — a `TimeoutException`, not a `StateError` — if the
  open itself never settles (a wedged `PackageInfo.fromPlatform()` binder
  call is the realistic trigger, Android cold-start). That undid the exact
  fail-closed guarantee round-31 added for this function: 3 of 4 real call
  sites in `ad_manager.dart` have no try/catch around it, so the timeout
  could escape as an unhandled exception instead of failing closed. Added a
  `catch (e)` beside the existing `on StateError`.

Both fixed RED→GREEN (new tests: `ad_consent_test.dart` mocks a provider
write throwing and asserts the committed-consent value doesn't move;
`tcf_personalisation_consent_test.dart` uses `fakeAsync` + a new
`@visibleForTesting IabStorage.debugOpenOverride` seam — `Platform.isAndroid`
can't be faked in `flutter test`, so this is the only way to make the open
step itself hang without a real Android device). `flutter analyze`: 0
issues. Suite: 1555/1555 pass.

~15 further MAJOR findings from this round (no runtime AdMob↔AppLovin
fallback, AppLovin banner/native revenue-event gaps, `bootstrap()` with no
hard-cap, a couple of dialog-stacking edge cases, a missing `min:1` floor on
one remote-safety field, etc.) are catalogued in
`doc/audit/audit_round32_deep_consolidated.md` — left for a follow-up round,
prioritised with the user.

## [2.9.11] - 2026-09-02

**Published to pub.dev** — nhảy thẳng từ 2.9.6 (5 version 2.9.7-2.9.10
chưa từng lên pub.dev). Trước khi publish đã verify thật: pod install
pinning wall (AppLovinSDK resolve đúng 13.5.0), build+chạy `example/` thật
trên iOS Simulator và Android thật (TECNO SPARK Go 2024) — bao gồm form
UMP EEA thật (không priming dialog), xác nhận không lặp lại sau cold
restart.

Round 31 — full re-audit từ đầu của TOÀN BỘ `lib/src/` + `example/` (lần
đầu ai đọc riêng `example/`), ưu tiên sâu AdMob provider. 9 agent song
song, không tin báo cáo cũ, đối chiếu policy Google/Apple mới nhất khi
cần. Tìm 2 BLOCKER + ~20 MAJOR + ~6 MINOR thật; 2 finding khác hoá ra
false positive sau khi tự verify sâu (ghi lại dưới, không "sửa" bằng giải
pháp giả). Mọi fix RED→GREEN mutation-verified. Suite 1553/1553 pass.

**BLOCKER:**

- **Fix**: `AdMobAdapter.initialize()` gọi `updateRequestConfiguration`
  (mang cờ COPPA `tagForChildDirectedTreatment`/`tagForUnderAgeOfConsent`)
  SAU `MobileAds.instance.initialize()` — ngược thứ tự Google Flutter
  Targeting guide yêu cầu, và ngược chính pattern SDK đã tự sửa đúng cho
  AppLovin (MJ1). Mediation network con (Meta/Unity...) init bên trong
  `initialize()` có thể gửi request đầu tiên thiếu cờ trẻ em. Đổi thứ tự.
- **Fix**: `IabStorage.tcfAllowsPersonalisedAds()` không phân biệt được
  "chưa từng có TCF session" (an toàn, mặc định `true`) với "platform
  store đọc lỗi" (nguy hiểm, từng mặc định `true` giống hệt) — nếu đường
  đọc TCF trên iOS (chưa từng verify trên máy thật, CI chết từ
  2026-08-09) âm thầm lỗi, tái phát đúng BLOCKER round-6 (coi `obtained`
  là đủ để bật personalized ads dù EEA user đã từ chối). Đọc trực tiếp
  qua `_open()`, phân biệt store thật sự không đăng ký (test-only,
  không đổi hành vi) với lỗi đọc thật (fail-closed).

**Core (`ad_manager.dart`, `ad_safety_config.dart`, `remote_ad_safety_provider.dart`, `ad_preferences.dart`):**

- **Fix (MAJOR)**: `disableFillRateBaselineMonitor()` copy-paste sai từ
  `destroy()`, tắt luôn cả 3 tính năng opt-in khác không liên quan
  (`WaterfallTuner`/`SelfHealingObserver`/`JourneyPrefetcher`).
- **Fix (MAJOR)**: `_attachFullscreenDismissWatchers()` thiếu
  `rewardedInterstitialSlot` — format này (AdMob-only) vẫn dùng mốc
  dismiss "brittle" cũ (stamp lúc earn-reward, không phải lúc video thật
  đóng), App Open có thể bounce-back ngay sau RewardedInterstitial.
- **Fix (MAJOR)**: `refreshRemoteSafetyParams()` thiếu try/catch quanh
  merge override (khác `initialize()` có), và `posInt()` throw
  `UnsupportedError` với `Infinity`/`-Infinity` (`d == d.truncateToDouble()`
  đúng cho Infinity) — payload remote hỏng có thể crash. Thêm try/catch +
  sửa root cause (`isFinite` check).
- **Fix (MAJOR)**: daily ad count dùng ngày lịch LOCAL
  (`DateTime.now().toIso8601String()`), không như mọi rolling window khác
  trong file (đều dùng `millisecondsSinceEpoch` tuyệt đối) — đổi múi giờ
  thiết bị (không cần chỉnh đồng hồ) là reset counter tuỳ ý. Đổi sang UTC.
- **Fix (MAJOR)**: CTR-anomaly detection tự khoá vĩnh viễn — show bị chặn
  không tính impression để pha loãng tỉ lệ, nên lần show tiếp theo sau khi
  hết pause tự động re-trigger ngay với ratio cũ, escalate vô hạn. Thêm
  gate "chỉ đánh giá lại sau ≥5 impression MỚI kể từ lần trigger trước" —
  không reset counter thô (sẽ phá `ctrComponent` của risk score).
- **Fix (MINOR)** cùng chỗ: exponent clamp (4) khiến `_maxSuspiciousPause`
  (24h) không bao giờ đạt tới (tối đa thực tế 8h) — nâng clamp lên 6.
- **Fix (MAJOR)**: decay math cho suspicious-violation-count không clamp
  `hoursSince` — đồng hồ bị vặn lùi (không cần tiến, khác MJ9) làm hệ số
  decay > 1, KHUẾCH ĐẠI violation count thay vì giảm. Thêm `math.max(0, …)`.
- **Fix (MINOR)**: `unitDouble('suspiciousCtrThreshold')` chấp nhận `0.0`
  — backend serialize thiếu field thành `0` sẽ khiến MỌI click bị coi là
  bất thường. Thêm sàn `> 0.0`.

**AdMob adapter:**

- **Fix (MAJOR)**: banner/MREC/native chưa từng wire `onAdImpression`
  thật — dùng `onAdLoaded` (fill, không phải impression thật) làm proxy,
  không bao giờ emit `AdImpressionEvent` cho 3 định dạng này, và làm méo
  mẫu số CTR-fraud detection. Wire đúng callback thật.
- **Fix (MINOR)**: banner/MREC dùng `onAdOpened` cho click, native dùng
  `onAdClicked` — hai sự kiện được Google tài liệu hoá là khác nhau.
  Thống nhất về `onAdClicked` cho cả 3.

**AppLovin adapter:**

- **Fix (MAJOR)**: App Open chưa từng được thêm ad-identity tracking mà
  round-29 đã thêm cho Interstitial/Rewarded — `onAdHiddenCallback` tự
  tài liệu là "unreliable, có thể trễ 10-30s", late callback từ cycle cũ
  có thể set `_displayConfirmed`/resolve nhầm cycle mới. Thêm `_appOpenAd`
  + identity guard cho cả 3 callback (displayed/display-failed/hidden).
- **Fix (MINOR)**: remote safety override thiếu 2 field T126
  (`maxSameNetworkShowsPerWindow`, `networkFatigueWindowMs`) — network-
  fatigue guard không remote-tunable được dù mọi field số khác đều có.
- **Fix (MINOR)**: doc comment sai ở `_emitRevenueIfPresent` (nói revenue
  đến từ load callback — thực ra là display/impression time, hành vi
  đúng, chỉ comment sai).
- Đối chiếu tự verify: 2 finding khác của audit lần này (banner/mrec
  `incrementDailyAdCount`/`incrementPlacementDailyCount` thiếu write-chain;
  widget listener thiếu `_teardownStarted` guard) hoá ra **false positive**
  — lần lượt vì `SharedPreferences` legacy cache mutate đồng bộ (không có
  race thật trong Dart đơn luồng) và vì `_bannerDisposed`/`_mrecDisposed`
  đã tự bảo vệ qua scratch-object fallback. Không sửa; ghi lại lý do +
  test pin đúng hành vi hiện tại để tránh "sửa" lại nhầm sau này.

**VIP:**

- **Fix (MAJOR)**: `RedeemedKeyLedger._writeChain` là field instance-level
  (không static) — mirror đúng bug pattern `VipManager._saveQueue` đã sửa
  ở round-10 nhưng KHÔNG áp dụng ở đây. `AdManager` không truyền lại ledger
  cũ khi `destroy()`+`initialize()` lại → 2 instance ghi đè Keychain lên
  nhau → 1 kid đã redeem có thể "biến mất" khỏi ledger bền vững, cho phép
  redeem lại sau reinstall trên iOS. Đổi sang static, mirror chính xác
  `_saveQueue`'s `_savesInFlight` pattern.
- **Ghi nhận (không sửa bằng checksum)**: high-water-mark chống tua đồng
  hồ và danh sách kid đã redeem trên Android đều là plain
  `SharedPreferences`, không mã hoá — nhưng KHÔNG thêm checksum: chính
  lịch sử audit của repo này (M6, `_vip_entries_store.dart`) đã chứng
  minh checksum không-khoá với salt nằm trong source code published lên
  pub.dev không phải bảo vệ thật trước đúng kẻ tấn công cần chặn. Ghi rõ
  đây là giới hạn chấp nhận được của kiến trúc "không backend", cùng tầng
  rủi ro (cần root/trích xuất vật lý) với các giới hạn khác đã biết.
- **Ghi nhận**: `_first_install_guard.dart`'s bypass-result matrix thiếu
  1 dòng — genuine first launch trên máy MỚI restore từ iCloud backup của
  máy cũ đã nhận grace bị false-positive block. Trade-off sản phẩm thật,
  không có accessibility value nào chặn được cả 2 hướng cùng lúc.

**Widget:**

- **Fix (MAJOR)**: `AdReadinessSplashController`'s buffer-dialog
  `onComplete` chỉ check `ctx.mounted`, không check `_navigated` — hard-cap
  timer có thể fire (điều hướng sang Home) TRONG LÚC buffer 1s vẫn đang
  đếm, route splash cũ vẫn `mounted` trong lúc exit-transition → App Open
  có thể show SAU KHI đã điều hướng. Thêm check `_navigated`.
- **Fix (MAJOR)**: `NativeAdWidget`'s retry-after-30s listener
  (`nativeHasError`) chỉ subscribe MỘT LẦN ở `initState` — sau bất kỳ chu
  kỳ dispose/revive nào (consent gate đóng-mở lại, rất phổ biến) bundle
  mới được tạo với notifier mới, listener cũ chết im lặng, quay lại đúng
  bug round-29 tưởng đã fix. Track + re-subscribe đúng notifier hiện tại
  mỗi lần `_initNative()` chạy.
- **Fix (MAJOR)**: banner/MREC chỉ dựa `RouteAware`, không phủ được
  bottom-nav dựng bằng `IndexedStack`/`Visibility(maintainState: true)`
  (không có Route change nào để RouteAware thấy) — ad ở tab ẩn tiếp tục
  refresh/request nền, đúng loại vi phạm policy "requesting ads that
  aren't visible". Thêm `TickerMode.of(context)` detection (bắt được
  `Visibility(maintainState: true)`/`CupertinoTabScaffold`, KHÔNG bắt
  được `IndexedStack` trần — ghi rõ giới hạn còn lại + workaround trong
  doc comment của cả 2 widget).
- **Fix (MINOR)**: `DebugAdOverlay`'s stream subscribe chỉ thử 1 lần ở
  `initState` — mount trước khi `enableFillRateBaselineMonitor()` chạy
  thì mất tín hiệu alert vĩnh viễn. Retry mỗi `build()` (rẻ, chỉ debug
  tool).

**Monetization (chỉ tài liệu hoá, không đổi hành vi):**

- `WaterfallTuner.recommendation()`/`SelfHealingObserver` không bao giờ
  có thể trả về non-null trên thiết bị thật, vì kiến trúc 1 install =
  1 provider cố định suốt vòng đời khiến `otherKey` luôn rỗng. Đã opt-in
  sẵn (off theo mặc định) — ghi rõ giới hạn thật vào doc comment của cả
  2 class + 2 method `enable*` trên `AdManager`, để host không kỳ vọng
  sai tính năng "flagship" này sẽ tự kích hoạt.

**Consent/GDPR/COPPA/CCPA:**

- **Fix (MAJOR)**: prompt ATT (iOS) không có mutex "on-screen" như UMP
  form — cùng loại dialog native ngoài Flutter route mà
  `AdScreenRouteLogger`/App-Open-resume-guard không thấy được. Tái dùng
  chính xác `markUmpFormOnScreen()` (ref-counted, backstop 15 phút) thay
  vì xây cơ chế song song; release gắn vào future GỐC (không timeout) để
  tránh đúng bug UMP form từng gặp (timeout Dart-side không đóng dialog
  native thật).
- **Fix (MAJOR)**: không có cảnh báo nào khi app khai `isAgeRestrictedUser:
  true` (COPPA) nhưng để `umpTagForUnderAgeOfConsent` ở mặc định `false`
  trong khi UMP flow vẫn chạy — form UMP chuẩn (206 đối tác) có thể hiện
  cho audience tự khai là trẻ em. Thêm `coppaUmpMismatchWarning()`
  (pure + static, cùng hợp đồng `consentFootgunWarning`).
- **Fix (MINOR)**: doc comment liệt UMP form + ATT prompt vào "NOT handled
  by SDK, dùng package `umpsdk`" — package đó không tồn tại, và cả 2 thực
  ra ĐÃ được SDK tự triển khai (`requestUmpConsent()`/`requestAtt()`).
- **Tính năng mới**: `CcpaOptOutToggle` — widget "Do Not Sell or Share My
  Personal Information" cho CCPA/CPRA (Cal. Civ. Code §1798.135), vốn yêu
  cầu là lựa chọn end-user thực thi được, không phải hằng số dev hardcode
  như `consent_dialog.dart`'s binary dialog vẫn đúng khi giữ nguyên cho
  COPPA/GDPR. Thêm `AdManager().setDoNotSell(bool)`/`.doNotSell` (máy móc
  đã có sẵn từ trước — `AdConsent.doNotSell` đã flow đúng tới cả 2
  provider + persistence; chỉ thiếu entry point tiện lợi + UI thật).

**Example app (`example/lib/main.dart`) — lần đầu có ai đọc riêng qua 31 round:**

- **Fix (MAJOR)**: `mrecId` dùng chung ad-unit-id Native Advanced với
  `nativeId` — MREC thực ra chỉ là banner ở size khác, phải dùng Banner
  test ID. Trang demo MREC không load được creative test khi build với
  `AD_PROVIDER_ADMOB=true` (chính path CI dùng).
- **Fix (MAJOR)**: `AdMobConfig` thiếu `rewardedInterstitialId` — trang
  demo riêng (round-27 làm để đóng coverage gap cho định dạng AdMob-only
  này) không bao giờ có thể show ad thật; test integration hiểu nhầm kết
  quả "chắc chắn fail" thành "flaky do fill/timing".
- **Fix (MAJOR)**: `AppOpenDemoPage` (StatelessWidget) dùng `context` sau
  callback bất đồng bộ (`loadAppOpenAd`) không check `context.mounted` —
  mọi chỗ khác trong cùng file đều có guard này, đây là code mẫu dễ bị
  app khác copy nguyên lỗi.

## [2.9.10] - 2026-09-02

Round 30 — lấp 2 khoảng trống round 29 chưa đọc: `lib/src/utils/` (nền
persistence) và `lib/src/config/` + `applovin_bridge.dart` (cấu hình +
lớp gọi native AppLovin thật). 2 agent đọc hết, không diff, tìm 4 MAJOR
thật. Mọi fix RED→GREEN mutation-verified.

- **Fix (MAJOR)**: AppLovin test-device registration (`setTestDeviceAdvertisingIds`)
  was called AFTER `_bridge.initialize()` — verified against the real
  `applovin_max` 4.6.4 native plugin source (Android/iOS) that the field is
  only ever read once, inside `initialize()` itself, then nilled. The
  developer/QA device was never actually registered as a test device on
  AppLovin. Reordered to match the consent-flags pattern right above it
  (MJ1).
- **Fix (MAJOR)**: `refreshRemoteSafetyParams()` merged remote overrides
  onto the raw `config.safety` instead of the ramp-adjusted
  `effectiveSafety`, silently reverting every field a `safetyRampSchedule`
  stage had adjusted back to day-0 config on every refresh. Factored out a
  shared `_rampAdjustedSafety()` used by both `initialize()` and refresh.
- **Fix (MAJOR)**: remote safety overrides had no upper bound — only
  `dryRun` was guarded against a safety-defeating payload. A remote config
  could set `minTimeBetweenFullscreenAds: 0` (kills the anti-fraud
  throttle) or any cap field to an arbitrarily large number (functionally
  unlimited ads). Added sane min/max bounds per field.
- **Fix (MINOR)**, same file: `posInt()` required `v is int` exactly,
  unlike `unitDouble()`'s more permissive `is num` — a remote-config
  backend emitting `8.0` for a whole-number field was silently dropped.
  Now accepts whole-valued doubles.
- **Fix (MAJOR)**: `AdPreferences.getInstance()` checked its cached
  singleton only before its internal `await`, never after — two concurrent
  callers before the singleton was first set each built a separate
  instance with independently-diverging mutable state (verified with a
  throwaway reproduction: a fill-rate baseline sample silently dropped).
  Switched to a `Completer`-based guard, mirroring what
  `SharedPreferences.getInstance()` itself already does.
- Doc-only: `async_epoch.dart`'s class comment claimed zero production
  usages; `AdLoadingDialog` has used it since T115.

1515/1515 tests pass, analyze clean. See
`doc/audit/audit_round30_deep_consolidated.md` for the full writeup,
including one agent-reported "dead code" nit that turned out to be a false
positive on re-verification (a grep that missed `test/`).

## [2.9.9] - 2026-09-02

Round-29 follow-up — closes the one gap 2.9.8 deferred: AppLovin's half of
the cross-cycle late-callback fix (AdMob's half shipped in 2.9.8).

- **Fix (MAJOR)**: AppLovin wires one persistent listener per ad type at
  `initialize()` (not a fresh closure per `show()` call like AdMob), so it
  had no way to tell a stale cycle's late native event apart from the
  current one. Added `_interstitialAd`/`_rewardedAd` ad-identity tracking —
  every show-lifecycle callback (`onAdDisplayedCallback`,
  `onAdDisplayFailedCallback`, `onAdHiddenCallback`,
  `onAdReceivedRewardCallback`) now `identical()`-checks the `MaxAd` it was
  handed before mutating the slot or resolving the caller. A stale/late
  event is discarded instead of stealing a newer cycle's caller or, worse,
  silently dropping an earned reward.
- 2.9.8 attempted this and reverted it — the identity check broke 14+
  existing tests in `test/applovin_adapter_test.dart` because its `_fakeAd()`
  helper created a fresh `MaxAd` per call instead of reusing one instance
  across load→show→hide (unlike the real AppLovin SDK, which keeps one ad
  object alive for that whole lifecycle). Fixed properly this time: updated
  every affected test to thread the loaded ad's actual reference through,
  which is also more realistic test modeling than before. Two new tests
  added (`round-29 audit follow-up`) mutation-verified the fix itself
  (RED→GREEN).
- 1505/1505 tests pass, analyze clean.

## [2.9.8] - 2026-09-01

Round-29 audit — user pushback that round 28 (and the 27 before it) were
"too rushed" and diffed only since the last round instead of re-reading
each subsystem from scratch. This round did that: 6 agents each read one
whole subsystem end-to-end with no baseline assumed, found 6x the real
issues round 28 did. All RED→GREEN mutation-verified; see
`doc/audit/audit_round29_deep_consolidated.md` for the full writeup.

**BLOCKER (availability — the SDK could wedge part or all of itself):**
- `showRewardedAd()`'s two native platform-channel calls
  (`_loadRewardedOnDemand`, `ad.showRewarded()`) had no try/catch — a throw
  left `_rewardedInFlight` stuck `true` forever, permanently blocking every
  future rewarded show (including the VIP watch-to-extend flow).
- `AdManager._disposeAdapter()`'s `await old.dispose()` had no `.timeout()`,
  unlike its two sibling awaits in the same teardown (round-27 fix) — a
  hung native `dispose()` call meant `destroy()` never returned and every
  later `initialize()` waited on it forever.
- AppLovin's fullscreen load callbacks (App Open/Interstitial/Rewarded)
  never got round-27's AdMob-only `_fullscreenDisposed` guard — a load
  landing after `dispose()` still mutated a slot on an abandoned adapter.

**MAJOR:**
- `ConsentManager.reset()` reset to `ConsentSettings.unset`, silently
  clobbering `isAgeRestrictedUser` (COPPA)/`doNotSell` (CCPA) — both
  app-level flags, not per-user answers — contradicting its own doc
  comment, which claimed no provider side-effect.
- The rapid-resume rate limiter `.clear()`ed its own rolling window on
  trip, so it only ever blocked the (N+1)th resume of a burst before
  resetting to zero instead of enforcing a real N/60s cap.
- AdMob's adaptive banner computed its width once at first mount;
  rotation/resize/foldable-unfold never re-triggered a reload at the new
  width.
- `AdaptiveAdSurface`'s resize debounce only checked `fullscreenBusy` when
  armed, not when it fired — a fullscreen ad starting mid-debounce still
  let the format swap underneath it, contradicting the class's own doc
  comment.
- AdMob banner/MREC route-away only hid the widget (no pause API exists on
  the Flutter plugin) — the cached native ad kept refreshing while
  invisible. Now torn down on route-away and reloaded on return, matching
  what "paused" actually means for AppLovin's side.
- Cross-cycle late-callback races (AdMob only this round — see below) in
  Interstitial/Rewarded/RewardedInterstitial: a stale cycle's late
  dismiss/fail could steal a newer cycle's caller or, worse, silently drop
  a genuinely-earned reward. App Open's existing guard was reviewed and
  left as `== null` (correct for its case — see the source comment for why
  a stricter check regressed a real test).
  - **AppLovin side not fixed this round** — it uses one persistent
    listener per ad type (wired at `initialize()`), not a fresh closure per
    `show()` call, so the fix needs ad-identity tracking rather than a
    local flag. Attempted, reverted: it broke 14+ existing tests whose
    `_fakeAd()` helper creates a fresh `MaxAd` per call rather than sharing
    one instance across load→show→hide, which a real device does. Tracked
    as a follow-up requiring that test-suite convention to change first.

**MINOR:**
- Custom consent dialog: `barrierDismissible: false` never blocked the
  Android back button/gesture (only the tap-outside barrier) — added
  `PopScope`.
- VIP redeem key field had no `maxLength` — a huge paste ran Ed25519/
  SHA-512 (pure-Dart) on the UI isolate unbounded. Capped at 512.
- `TopToast._animateOut`'s `await ctrl.reverse()` could hang forever if
  `dispose()` ran mid-reverse (a superseding toast) — `Ticker.dispose()`
  only completes `.orCancel`'s completer, not a plain await's. Switched to
  `.reverse().orCancel` + catch.
- `NativeAdWidget` never retried after a load failure (unlike Banner/Mrec,
  which get a fresh shot via consent/personalisation/initRevision events)
  — added a 30s backoff retry.
- `GmaShowCallbacks.onImpression` was wired at the bridge layer but no
  adapter call site ever passed it — finished the wiring, added the
  matching `AdImpressionEvent` (mirrors `AdClickEvent`).
- README never warned integrators about AdMob's ad-placement policy
  (banner/interstitial near tappable controls risks invalid-traffic
  enforcement) — the SDK can't enforce this itself, so it's now at least
  documented.
- Custom consent dialog: Reject button got `flex: 1` vs Allow's `flex: 2`
  (half the width) on top of its own ghost styling — equal width now.
  Cosmetic only; this dialog isn't the actual EEA-compliance surface
  (Google's own UMP form is, and it's unstyled by this SDK).

## [2.9.7] - 2026-09-01

Round-28 audit fix — the one new MAJOR found (only 1 of 3 independent
reviewers caught it; verified against source before fixing):

- **Fix (MAJOR)**: `showModalBottomSheet` defaults to
  `useRootNavigator: false`, unlike `showDialog`'s `true`. In an app with
  nested Navigators (bottom-nav tabs, a `go_router` `ShellRoute` branch), a
  plain `showModalBottomSheet` call pushes onto the nested Navigator, which
  `AdScreenRouteLogger` (registered on the root Navigator per the integration
  contract) never observes — `isDialogOnTop` stays `false`, so a resumed App
  Open ad could show on top of the bottom sheet. Added
  `showAdSafeModalBottomSheet` (`lib/src/core/ad_route_observer.dart`), a
  drop-in wrapper that always forces `useRootNavigator: true`. Documented in
  README's integration contract section and the App Open/modal caveat.
  Mutation-verified: `test/ad_route_observer_test.dart` builds a nested
  Navigator with only the root one observed, confirms a plain
  `showModalBottomSheet` call is invisible to `isDialogOnTop` (the bug) and
  `showAdSafeModalBottomSheet` is visible (the fix).

## [2.9.6] - 2026-09-01

Round-27 audit follow-through — the 2 MAJORs the round-26 audit deferred are
now fixed, plus the example app's ad-surface coverage gap it and `agy`
independently flagged is closed:

- **Fix (MAJOR, round 26 finding #1)**: `RedeemedKeyLedger.markRedeemed()`
  read-modify-wrote the iOS Keychain with no serialization — two
  near-simultaneous signed-VIP-key redemptions could both read the same
  pre-write snapshot, then race to write, silently dropping one `kid` from
  the durable one-time-use ledger. Now chains every write onto the previous
  one (same idiom as `AdEventLog._persistChain`). Mutation-verified: new
  test in `test/redeemed_key_ledger_test.dart` fires two concurrent
  redemptions against a mock storage that snapshots its pre-delay state, and
  asserts both kids land (revert → red, drops one kid; fix → green).
- **Fix (MAJOR, round 26 finding #2)**: `AdMobAdapter`'s `onFailed` branch
  for all 4 fullscreen ad types (app open, interstitial, rewarded, rewarded
  interstitial) had no `_discardIfDisposed`-equivalent guard, unlike
  `onLoaded`. A load failure delivered after `dispose()` still mutated slot
  state and emitted through `eventSink`. Added the same `_fullscreenDisposed`
  check to all 4, and `dispose()` now also nulls `eventSink` last as a
  second line of defense. Mutation-verified: new test group in
  `test/admob_adapter_test.dart` (one case per ad type) using a bridge that
  can defer its `onFailed` callback past `dispose()`.
- **Add**: `showRewardedInterstitialAd()` had zero example-app coverage at
  any level despite being a fully supported, README-documented ad surface —
  found independently by both `agy`'s round-27 audit and a direct grep
  (`0 matches` for `RewardedInterstitial` anywhere in `example/lib/`).
  Added `RewardedInterstitialDemoPage` (home-list tile, same pattern as the
  other demos), a widget test (`example/test/rewarded_interstitial_demo_page_test.dart`),
  and an on-device integration test
  (`example/integration_test/rewarded_interstitial_ad_test.dart`) verified
  passing on an Android emulator.
- **Refactor**: `example/lib/main.dart` — merged the 18 files T117 (2.7.0)
  split it into back into one file. Reason: pub.dev's "Example" tab renders
  only the example app's entry-point `.dart` file, not files it
  imports/exports, so post-T117 a pub.dev visitor evaluating the package
  before installing it only saw a ~90-line stub of import/export statements
  instead of any of the 18 real demos — confirmed by fetching the live
  pub.dev Example tab directly. The T117 split remains the right call for
  day-to-day editing in isolation; kept as one file anyway because pub.dev
  presentation was judged more important here. No behavior change — verified
  by `flutter analyze`/`flutter test` (both packages) passing unchanged
  before/after the merge.

## [2.9.5] - 2026-09-01

- **Fix (audit round 27, MAJOR)**: `AdManager.destroy()`'s `await
  _eventLog?.flush()` (added in 2.9.4 for T102) had no timeout, unlike every
  other bounded teardown wait in the same method (`_eventStream.close()`,
  the fullscreen-show drain). A stuck platform-channel `SharedPreferences`
  write would have hung `destroy()` forever and parked every subsequent
  `initialize()` behind it via `_destroyInFlight`. Now wrapped in the same
  2s timeout pattern as the adjacent waits — on timeout, teardown continues
  and logs a warning instead of hanging. Found independently by 3 reviewers
  (`codex`, `agy`, `claude`) in the same audit round; see
  `doc/audit/audit_round27_consolidated.md`. Mutation-verified: a new test
  in `test/destroy_awaits_event_log_flush_test.dart` (revert → 10s hang
  and red assertion, fix → green in <3s).
- **Fix (test-only)**: `example/test/home_page_test.dart` asserted 17
  `DemoTile`s; the 2.9.1 Adaptive Surface demo (T124) brought the count to
  18 and the test wasn't updated. Found by `agy` in the round-27 audit.

## [2.9.4] - 2026-09-01

- **Fix (T102, finally closed after 3 rounds)**: `AdManager.destroy()` now
  awaits the event log's flush before nulling it, closing a
  destroy()→initialize() race that could silently lose queued compliance
  events. The fix itself was correct on the first attempt; what took 3
  rounds was a `flutter test` hang the fix exposed — root cause was a *test*
  bug (`ad_manager_core_test.dart`'s remote-safety-provider timeout test
  mixed `fakeAsync` with real platform-channel work, leaving an orphaned
  tail running in real wall-clock time after the test's virtual zone
  closed; `unawaited(...)` used to hide it, `await` exposed it), not a
  production bug. Fixed the test to use real time instead of `fakeAsync` for
  that scenario. Mutation-verified with a new AdManager-level test
  (`test/destroy_awaits_event_log_flush_test.dart`).

## [2.9.3] - 2026-09-01

T115 (`doc/task/done/T115-standardize-async-cancellation-primitive.md`):
`AdLoadingDialog`'s ad-hoc `_generation` int counter (the stranded-dialog
guard) is now the first production use of the `AsyncEpoch` primitive built
in round-27 batch D. Internal representation change only — no observable
behaviour change, confirmed by the existing "stranded-dialog fix" test group
passing unmodified. The rest of the SDK's generation/bool-disposed/Timer
idioms (`ad_manager.dart`, both adapters, UMP, VIP, splash) are deliberately
NOT touched — those are individually risky migrations on files already
audited 26+ rounds, left for dedicated follow-up tickets.

## [2.9.2] - 2026-09-01

- **Fix**: `ComplianceReport.redacted()` only nulled out a redacted field's
  value, leaving the key present (`{'consentCountry': null, ...}`). A profile
  is meant to strip the field entirely — a null value still tells whoever
  reads the exported report that the SDK tracks that field at all. Now the
  key is removed. Caught by a real-device integration test
  (`example/integration_test/compliance_redaction_test.dart`, built while
  QA-hardening the round-27 features) that a unit test alone hadn't exercised
  against a real, device-generated `AdEventLog`.

## [2.9.1] - 2026-09-01

QA pass on the round-27 features added in 2.5.0-2.9.0: added example demos
for the ones with a UI surface, plus a widget test for a real gap that pass
turned up.

- **Fix**: `AdScreenState.buildBanner()`/`buildMrec()`/`buildNative()` — the
  helper the README documents as the standard `AdScreen` integration
  path — never accepted a `placement` parameter, even after T107 added
  `placement` to `BannerAdWidget`/`MrecAdWidget`/`NativeAdWidget` directly.
  Any host following the documented pattern instead of instantiating the
  widgets by hand had no way to reach it — every per-placement stat/cap
  silently stayed on `AdPlacement.unspecified`. All three helpers now take
  an optional `placement` (default unchanged) and forward it.
- Example app: added a live demo for `AdManager().stateSnapshot` (T109) to
  the Slot state panel, a "Preview outcome (no device call)" button using
  `simulateConsentOutcome()` (T120) to the Consent/GDPR demo, and a new
  Adaptive surface demo page (T124) with a width slider.


---

Older entries (v2.9.0 and earlier) moved to [CHANGELOG_ARCHIVE.md]
(CHANGELOG_ARCHIVE.md) — this file crossed pub.dev's 256KB upload
content-length limit on 2026-09-24. Full history is also always
available in `git log`.
