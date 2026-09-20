# Changelog

All notable changes to `applovin_admob_sdk` are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

## [2.9.0] - 2026-08-31

Round-27 batch E (final batch of the round-27 backlog) — 4 done, 1
investigated and correctly not attempted.

- **New**: `AdSafetyParams.maxSameNetworkShowsPerWindow`/
  `networkFatigueWindowMs` — a creative/network fatigue guard. If one
  mediated network keeps winning the waterfall for a format inside a
  rolling window, that format cools down instead of continuing to serve a
  possibly-stale/low-quality network back to back. Fail-open by design: a
  format nothing has ever reported network metadata for is never blocked.
  Off by default (999 in the `debug` preset, same as every other cap).
- **New**: `SelfHealingObserver` (opt-in via
  `AdManager().enableSelfHealingObserver`) — flagship self-healing runtime,
  **observe-only** prototype. Reuses `WaterfallTuner`'s fill-rate×eCPM
  scoring to emit `AdSelfHealingObserveEvent` onto `events` the first time a
  format's trailing data recommends the other provider. Never switches
  anything itself — full auto-act needs both adapters alive in the same
  session, a real architecture change left for a dedicated follow-up.
- **New**: `AdManager().bypassAuditTrail` (always on) + `callSiteTag`
  parameter on `showAppOpenAd`/`showRewardedAd` — flagship
  proof-of-compliance. Every real `bypassSafety`/`bypassVipGuard` call is
  recorded and exportable as an Ed25519-signed bundle
  (`exportSignedBypassAuditTrail()`, verify with
  `tool/bypass_audit_replay.dart`), reusing the same on-device signing
  infrastructure as the compliance report (T96) and incident bundle (T125).
- **New**: `MonetizationDigitalTwin` (`AdManager().buildMonetizationDigitalTwin()`)
  — flagship Monetization Digital Twin, **v0, deliberately rescoped** to one
  policy axis (`maxFullscreenAdsPerDay`) instead of the full ticket's five.
  Deterministic, read-only replay over existing `AdEventLog` history —
  forecasts daily impressions/revenue under a hypothetical daily cap. The
  other four axes (retry, provider split, VIP duration, preload) would each
  require re-implementing `AdSafetyConfig`'s live decision logic as a
  second, pure, replayable copy — real XL risk, left as follow-up tickets.
- **Investigated, not implemented**: a VIP device-transfer token signed
  with the on-device compliance-signing key, as the backlog originally
  described it, is **forgeable** — that key is randomly generated per
  install with no shared root of trust between devices, so anyone could
  self-sign an arbitrary "days remaining" token that verifies against its
  own embedded public key. Also found that most of the underlying need
  already works today: `AVP2` signed VIP keys are redeemed against a
  purely local, per-device ledger, so a still-valid key STRING already
  redeems again on a fresh install with zero new code — the real gap is a
  missing UX affordance (an API to look up a still-valid VIP entry's
  original key string to copy before switching devices), not a new signing
  scheme. Left open with the full reasoning in
  `doc/task/todo/T130-flagship-vip-device-transfer-token.md` pending a
  decision on the correct (much smaller) fix.

## [2.8.0] - 2026-08-31

Round-27 batch D — 3 new opt-in features, 1 primitive built (not yet
migrated anywhere), 1 refactor investigated and correctly not attempted.

- **New**: `WaterfallTuner` (T122) — opt-in local fill-rate/eCPM scorer per
  (provider, format, placement), `AdManager().enableWaterfallTuner(...)`.
  Recommends a provider for the host's *next* session; never auto-switches,
  never loads a shadow ad.
- **New**: `JourneyPrefetcher` (T123) — opt-in smart prefetch,
  `AdManager().enableJourneyPrefetcher(...)`. Host calls `notifySignal(signal,
  type)` at journey points that typically precede a fullscreen ad; learns a
  rolling time-to-show average and stops preloading eagerly once a signal's
  average lead time exceeds `maxHoldDuration`. Bypasses no gate — calls the
  same public `loadX()` a host could call directly.
- **New**: `AdaptiveAdSurface` widget (T124) — picks between banner and MREC
  by available width (debounced, freezes while a fullscreen ad is busy).
  Native intentionally excluded from auto-selection — its content is
  host-authored, so width alone isn't a sufficient signal.
- **Internal**: `AsyncEpoch` primitive (T115) — the generation/dispose/
  invalidate primitive several subsystems could eventually share. Built and
  tested on its own; deliberately NOT wired into any existing call site yet
  (`ad_manager.dart`, both adapters, UMP, VIP manager, splash controller,
  loading dialog) — each migration is its own risky change on files audited
  26+ rounds, left for dedicated follow-up tickets.
- **Investigated, not done**: unifying banner/MREC/native lifecycle across
  the two adapters (T114) — read the actual duplication first: 30+ touch
  points per format, several wrapping identity-check guards inside the
  load/callback path itself (the exact logic 26 rounds of audit tuned). Not
  safely refactorable as a single indivisible pass; left open with a
  per-format migration path suggested for next time.

## [2.7.0] - 2026-08-31

Round-27 batch C — five more tickets from `doc/task/BACKLOG-sdk-2026-08-31.md`
(T116, T106, T108, T117, T125), each with new tests:

- **New**: shared adapter contract-test suite (T116) — `test/adapter_contract_test.dart`
  runs the same scenario matrix (consent epoch, show mutex, dispose, late
  callback after dispose, revenue, App Open watchdog, N-instance banner
  slots) against both `AdMobAdapter` and `AppLovinAdapter`. Test-only; no
  production code changed.
- **New**: `bootstrap(AdBootstrapOptions)` (T106) — sequences
  `requestAtt() → requestUmpConsent() → initialize()` in the one order the
  README already documented doing by hand, returning
  `AdBootstrapResult { att, ump, initSuccess, gaid }`. Non-breaking: the
  lower-level calls are unchanged, `bootstrap()` only wraps them.
- **New**: `AdRetryPolicy` (T108) — optional per-slot retry policy layered on
  `Backoff` (now exported): `isRetryable(errorCode)` to stop retrying
  dead-end errors, stable per-failure jitter, and
  `resetOnConnectivityRestored` so a network-outage failure doesn't wait out
  a backoff computed while offline. Defaults to `null` everywhere — no
  behavior change unless a host opts a slot in via
  `AdManager().adapter?.interstitialSlot.retryPolicy = ...`.
- **New**: `IncidentRecorder`/`IncidentBundle` (T125) — a small bounded ring
  buffer of state-transition snapshots (distinct from the existing 5000-entry
  `AdEventLog`), exportable as an Ed25519-signed bundle (reusing the same
  on-device key as `exportSignedComplianceReport()`) and replayable fully
  locally via `dart run tool/incident_replay.dart <path>`.
- **Chore**: `example/lib/main.dart` (T117) split from ~2729 lines into
  `config/`, `bootstrap/`, `shared/`, and one `demos/*.dart` file per format
  (16 files) — `main.dart` now only holds `main()` plus a barrel `export` of
  every split file, so nothing under `example/test/` or
  `example/integration_test/` needed changes.

## [2.6.0] - 2026-08-31

Round-27 batch B — five more enhancement/idea tickets from
`doc/task/BACKLOG-sdk-2026-08-31.md`, each with new tests:

- **New**: `AdManager().refreshRemoteSafetyParams()` (T111) — re-fetches and
  applies `RemoteAdSafetyProvider` params on demand, mirroring
  `refreshRevocationList()`'s already-established fail-open pattern, instead
  of requiring a full `destroy()`+`initialize()` cycle to pick up a remote
  config change.
- **New**: `AdConfig.safetyRampSchedule` (T121) — an optional, fully local
  (no network) `Map<Duration, AdSafetyParams>` keyed by install age (e.g.
  D0/D3/D7/D30), letting an app ramp caps up gradually without any
  backend. Applied before `remoteSafetyProvider`, so a remote override
  always wins if both are configured.
- **New**: `BannerAdWidget`/`MrecAdWidget`/`NativeAdWidget` (T107) now accept
  an optional `placement` constructor parameter (default
  `AdPlacement.unspecified`, not a breaking change) — the `AdClickEvent`
  each widget emits on an AppLovin click now carries it instead of always
  reporting `unspecified`.
- **New**: `AdManager().stateSnapshot` (T109) — one
  `ValueListenable<AdSdkStateSnapshot>` combining
  isInitialised/canRequestAds/isOffline/isVipActive/fullscreenBusy, coalesced
  onto a microtask, instead of hand-wiring five separate notifiers.
- **New**: `FakeAdProviderAdapter` (T118) — a fully offline
  `AdProviderAdapter` implementation (no network, no ad-unit ID) for
  CI/demo/App-Store-review builds, wired in via the existing
  `AdManager.debugAdapterFactory` seam. Renders an unmistakably-fake
  placeholder for banner/MREC/native instead of silently rendering nothing.

## [2.5.0] - 2026-08-31

Round-27 roadmap, batch A (`doc/task/BACKLOG-sdk-2026-08-31.md`) — five
enhancement/idea tickets, all purely additive (new optional params, new
methods, new classes), no breaking changes:

- **New**: `AdSafetyParams.maxPerPlacementAdsPerDayById` (T113) —
  `Map<String, int>?` keyed by `AdPlacement.id`, alongside the existing
  `maxPerPlacementAdsPerDay: Map<AdPlacement, int>?`. Unlike that field, this
  one can be used inside a `const AdSafetyParams(...)` declaration (`String`
  has primitive equality; `AdPlacement`, which overrides `==`, does not).
- **New**: `MonetizationArbitrator(fillRateBaselineMonitor: ...)` (T112) —
  opt-in; when passed, an active `FillRateBaselineMonitor` regression alert
  for a slot is an additional veto signal in `decide()`, still subject to the
  same `vetoRate` guardrail. `null` (the default) is byte-for-byte unchanged.
- **New**: `ReportRedactionProfile` + `ComplianceReport.redacted(profile)`
  (T110) — `fullLocal` (no-op) and `supportSafe` (strips `consentCountry` and
  `placement` from every event entry) built in, or construct a custom
  profile with any `Set<String>` of event fields. `ComplianceReport` also
  gained `schemaVersion` in `toJson()`.
- **New**: `AdManager().explainLastSkip(AdSlotType)` (T119) — human-readable
  answer to "why isn't this ad showing?", reading the same `AdSkipEvent` data
  already emitted on `AdManager().events` (T77). `null` if nothing has been
  skipped for that slot yet this session.
- **New**: `simulateConsentOutcome(AdConsent, {AdConfig?})` +
  `ConsentSimulationResult` (T120) — pure, side-effect-free preview of what
  `applyConsentToProviders` would send to AdMob/AppLovin for a hypothetical
  consent combination, with zero platform-channel calls. Both now share one
  internal decision function, so the simulation can't drift from the real
  apply path.

## [2.4.5] - 2026-08-31

Round-27 continued: T103, T104, T105 (`doc/task/BACKLOG-sdk-2026-08-31.md`,
bugs B8/B9/B10). Each mutation-verified.

- **Fix (T103)**: the example app's own splash screen (`example/lib/main.dart`)
  used a `ValueNotifier<bool>` purely as a guard flag — nothing ever listened
  to it. A native ad-load callback arriving after the splash widget's own
  `dispose()` still wrote to it, throwing "A ValueNotifier was used after
  being disposed." Replaced with a plain `bool`, set `true` as the very first
  line of `dispose()` — a plain field is always safe to read/write regardless
  of widget lifecycle, closing the whole bug class rather than one race
  window in it.
- **Fix (T104)**: `AppLovinAdapter._disposedNativeKeys` (a tombstone `Set`
  guarding against a late native-ad callback resurrecting a disposed
  instance) never shrank — a screen scrolling many native ads through a
  long-lived `ListView` leaked one entry per ad that scrolled away and was
  never revived. Now a `LinkedHashSet` bounded at 200 entries, evicting the
  oldest tombstone once exceeded.
- **Fix (T105)**: `onAdOpened`/`onAdClicked` (AdMob banner/MREC/native) had no
  identity guard at all, unlike `onAdLoaded`/`onAdFailedToLoad` (round-26 #2
  only fixed the latter). A click landing after `disposeXInstance()` still
  counted against CTR-fraud tracking and emitted an `AdClickEvent` for a
  placement that no longer existed. Also nulled `AppLovinAdapter.eventSink` in
  `dispose()` — its bridge listeners are nulled there too, but a callback
  already queued at that instant still runs on its old closure and still
  reaches `_emit`, which reads `eventSink` at call time.

## [2.4.4] - 2026-08-31

Round-27 continued: T101 (`doc/task/BACKLOG-sdk-2026-08-31.md`, bug B2).

- **Fix**: `AdPreferences.recordFillRateBaselineSample()` wrote without any
  ordering guarantee — two samples fired close together (e.g. a load event
  immediately followed by a revenue event) could both read the same on-disk
  snapshot, and whichever write landed last silently discarded the other's
  delta. `FillRateBaselineMonitor`'s 7-day regression detector (T97) could
  therefore under-report or mis-time an alert. Writes are now chained
  (`_fillRateBaselineChain`), the same idiom `AdEventLog._persistChain`
  already used for the identical class of bug. Mutation-verified.

T102 (bug B3, `_eventLog.flush()` not awaited before `destroy()` nulls it)
was investigated and a fix attempted: changing `unawaited(...)` to a bare
`await` closes the race but makes `flutter test` hang indefinitely on
`ad_manager_core_test.dart` — some existing test/scenario there leaves the
event log's persist chain waiting on a write that never resolves. Reverted;
the ticket stays open (`doc/task/todo/T102-...md`) with this finding recorded
so the next attempt doesn't re-discover it. A bare `await` is confirmed
unsafe; a version with a bounded timeout was deliberately not implemented
either, since a timeout would mask whichever real bug the hang is exposing
rather than fix it.

## [2.4.3] - 2026-08-31

Round-27: after round-26, three independent reviewers (codex, Gemini, Claude)
read the whole SDK again looking for BUGS, enhancements, tech debt and new
feature ideas beyond what round-26 covered — see `doc/task/BACKLOG-sdk-2026-08-31.md`.
Five of the newly-found bugs are fixed here, each mutation-verified (revert
the fix, watch the new test go red first) except B5 (example-app-only, no
unit test harness for it):

- **Fix (P0)**: `AdManager.pickProviderCohort()`/`experimentBucket()` collapsed
  every install into the SAME bucket when called in the exact order their own
  docstring requires — before `initialize()`. `AdPreferences` hadn't
  bootstrapped yet and the device GAID hadn't been fetched yet, so the
  install id used to hash the bucket silently fell back to an empty string
  for every device. The A/B provider-split feature (`pickProviderCohort`) was
  a no-op for any host following the documented call order. Now mints a
  random id in memory the first time it's needed pre-bootstrap (stable for
  the life of the process) and hands it to `AdPreferences` to persist once it
  bootstraps, so it's the SAME id — not a second random one — that becomes
  stable across future launches too. Both functions stay synchronous; no
  signature change.
- **Fix**: `installAdCrashGuard()` wasn't idempotent — a repeated
  `initialize()` in one process (provider switch, logout/login) stacked
  another closure layer around `FlutterError.onError`/
  `PlatformDispatcher.onError` on top of the last one every time, so a crash
  got handled N times and the old closure chain never got collected. Now
  tracks the identity of the handler it last installed and no-ops only when
  that handler is still in place.
- **Fix**: a scheduled consent-dialog `Timer` and its re-scheduling guard
  flag were only cleaned up inside `destroy()`. A host calling `initialize()`
  again WITHOUT `destroy()` first (a documented, supported "auto-disposing
  previous" path) reached none of that cleanup, leaving a stale Timer
  (capturing the OLD `AdConfig`/`ConsentManager`) alive into the new session.
  Moved into `_resetGuardState()`, the one function both entry points already
  share for exactly this class of bug.
- **Fix**: `TopToast` — an older toast's own delayed dismiss (fired late,
  right after a newer toast replaced it) could remove the newer toast instead
  of itself, since both shared one static dismiss callback. The delayed
  dismiss is now a cancellable `Timer` (cancelled on dispose) and dismissal
  is scoped by identity — a toast can only ever remove itself, never
  whichever one happens to be current.
- **Fix (example app)**: `example`'s `EventBuffer` subscribed to
  `AdManager().events` once at startup; `destroy()` closes and replaces that
  stream, so the "Event stream" and "Revenue dashboard" demo pages silently
  stopped updating after using the "Slot state panel" demo's own
  Destroy/Re-initialize buttons. Now re-subscribes on every
  `AdManager().initRevision` change.

No behaviour a host observes through documented, non-internal APIs changes;
nothing here is a breaking change.

## [2.4.2] - 2026-08-31

Round-26 audit, finding #5 — closed on a third attempt after the first two
(closing/reopening `_canRequestAds` directly, then mirroring the round-11
`_pessimisticGateClose`/epoch mechanism) each regressed the existing
consent-gate test suite and were reverted.

- **Fix**: `AdManager.setConsent()`'s tightening path (a GDPR withdrawal, a
  fresh CCPA opt-out) called `applyConsentToProviders()` with the ad gate
  wide open. That function applies to AppLovin synchronously but awaits
  AdMob's `updateRequestConfiguration` — a concurrent load firing in that
  window could go out under AdMob's OLD, more permissive global
  configuration. `canRequestAds` now also checks a new
  `_consentProviderApplyInFlight` flag, set only around that one `await` and
  only for a tightening change. It is deliberately independent of
  `_pessimisticGateClose`/`_consentIntentEpoch` — those solve a different
  problem (a queued apply's not-yet-known outcome) and are untouched by this
  fix, so it cannot interact with round 11-21's recovery machinery.
- Mutation-verified: `test/consent_provider_apply_in_flight_test.dart` (revert
  → red, fix → green), plus the full existing suite (1342 tests) confirmed
  clean, including the exact three tests the first fix attempt broke and the
  thirteen the second attempt broke.

## [2.4.1] - 2026-08-31

Round-26 audit: three independent reviewers (codex, Gemini, Claude) plus a
line-by-line pass of my own, re-verifying the seven production requirements
against the current source and the live pub.dev listing. Consolidated verdict
in `doc/audit/audit_round26_consolidated.md`. Three findings fixed, each
mutation-verified (proven by reverting the fix and watching the new test go
red first):

- **Fix**: `AdManager.destroy()` could tear an adapter's native listeners down
  while a rewarded (or rewarded-interstitial) ad was still on screen. For
  AppLovin specifically, a reward event already in flight from the native SDK
  at that moment landed on a listener that had just been nulled and was
  silently dropped — a user who finished watching a rewarded ad right as
  `destroy()` ran (provider switch, logout, SDK reset) was told they earned
  nothing despite watching the whole thing. `destroy()` now waits up to 5s for
  a showing fullscreen ad to resolve on its own before tearing the adapter
  down; the wait is bounded so a wedged native SDK can never hang `destroy()`.
- **Fix**: the SDK's own post-splash auto-show consent dialog scheduled itself
  via a bare `Future.delayed` with nothing keeping a handle on it. A
  `destroy()` followed by a fresh `initialize()` (a different `AdConfig`, e.g.
  a QA build vs. production) inside that delay window still let the stale
  closure fire and apply the OLD config — including `testDeviceIds` — on top
  of the new session. The delay is now a cancellable `Timer`, cancelled by
  `destroy()`.
- **Fix**: `AdReadinessSplashController.dispose()` didn't mark itself
  navigated. If the splash widget was disposed (app backgrounded and killed
  mid-splash, or the route popped) while an app-open-ad load was still in
  flight, the late callback still ran the host's `onReady` navigation
  callback against an already-deactivated `BuildContext` — "Looking up a
  deactivated widget's ancestor is unsafe."

No behaviour a host observes through documented, non-internal APIs changes;
nothing here is a breaking change.

One additional finding (a narrow timing gap between AdMob and AppLovin
receiving a tightened consent decision through the SDK's *built-in* consent
dialog — the UMP path was already hardened against this in round 21/22) was
investigated and a fix attempted twice; both attempts regressed the existing
consent-gate recovery test suite and were reverted. It remains open, tracked
in `doc/audit/audit_round26_consolidated.md`, and only matters if you enable
`autoShowConsentDialog` for an EEA audience at scale.

## [2.4.0] - 2026-08-29

Round-23 audit: a full pass over the SDK, the example app, every doc in the
package and the live pub.dev listing, against the seven production
requirements. Three independent reviewers plus a line-by-line pass of my own,
then a second review round on the changes themselves; every finding was
re-verified against the source before being accepted (several were downgraded
or refuted). Consolidated verdict in
`doc/audit/audit_round23_consolidated.md`.

### ⚠️ Behaviour changes — read before upgrading

Nothing here changes a signature, so this compiles as a drop-in upgrade. Two
values that a host can *read* now mean something different, which is why this
is a minor bump and not a patch:

- **`RewardResult.shown` now means "the native SDK confirmed the ad reached the
  screen"**, and defaults to `false`. It used to default to `true` on every
  path, including the ones where no ad was ever displayed. If your app reads
  the `shown` argument of `showRewardedInterstitialAd(onDone: (shown, earned))`,
  re-check what you do with it: it is now the display signal, not a
  "the show attempt happened" signal, and it is `true` for a real display the
  user closed before the reward point.
- **`AdShowEvent.success` for `rewarded` and `rewardedInterstitial` now reports
  the DISPLAY, not the reward.** It used to carry `earned`. If you were
  counting rewards off the event stream, count `AdRewardEvent` instead — that
  is what it is for, and it is unchanged. `AdShowEvent.success` for banner,
  interstitial and app-open is unchanged.

- **`showRewardedInterstitialAd()` now shows a disclosure screen before the ad.**
  Google's policy for the format requires it: the user must be told an ad is
  coming and what the reward is, and be given a way out. `AdScreenState`
  renders one by default — pass `showDisclosure: false` only if your app
  already presents its own, and override `disclosureTitle` /
  `disclosureButtonLabel` to localise it. Declining costs nothing: no ad, no
  impression, no budget spent.

- **`AdRevenueEvent.placement` now reports where the ad was actually shown.**
  Before this release every revenue event arrived as
  `AdPlacement.unspecified`, and App Open always claimed `AdPlacement.splash`
  even on a resume. If you were grouping revenue by placement, the buckets
  change shape — they start being correct. Banner, MREC and native still report
  `unspecified`: nothing "shows" them, so there is no placement to take.

### Fixed

- **A wrong device clock could permanently ERASE a paid VIP grant.** The SDK
  keeps a high-water mark of the furthest instant the clock has ever read, so
  that winding the date backwards cannot resurrect an expired grant. If that
  mark ever got poisoned — a phone with a flat battery boots years in the
  future, the user opens the app once, NTP corrects it later — the expiry sweep
  compared every VIP row against the poisoned mark, decided they were all over,
  and deleted them from disk. Unrecoverable: there is no backend, and the key
  id is already burned in the one-time-use ledger, so re-entering the key the
  customer paid for answered "already used". A row is now deleted only once the
  clamped clock **and** the raw device clock both say its window has *ended* —
  a window that has not STARTED yet (a grant taken while the clock was running
  ahead) is kept too, which matters on iOS where the VIP row is Keychain-backed
  and survives a reinstall while the clock mark does not. A poisoned mark can
  still suppress an entitlement; it can no longer destroy one.

- **One tap on "watch an ad" laundered a revoked key's window past the
  revocation list.** VIP grants stack globally by design, so redeeming a signed
  30-day key and then watching one rewarded ad for "+1 day" moved the whole 30
  days into the `WATCH_AD` entry — where the revocation clamp, which matches on
  `SIGNED_<kid>`, could no longer reach it. Publishing a CRL for a leaked,
  refunded or resold key did nothing. Stacked grants now carry, transitively,
  what they absorbed, and the clamp matches on that too.

- **A cached revocation list verified itself, and a future-dated one could
  switch revocation off forever.** At startup the cached CRL was verified
  against a public key stored beside it in the same plaintext record — self-
  attesting. Anyone able to write app preferences could mint their own key
  pair, sign an empty CRL dated far in the future, write both, and permanently
  wedge the "only accept a newer list" rule against every CRL the publisher
  will ever issue. The cache's `issuedAt` is now latched only once the host's
  own key has confirmed it. The revoked set from an untrusted cache is still
  applied — it can only ever narrow a grant.

- **A child-directed flag set during init never reached AppLovin MAX.** MAX
  reads the flag once, at native SDK init, and that init is awaited for up to
  20 seconds. A host that starts `initialize()` and presents its age gate at
  the same time — the ordinary splash shape — could call
  `setConsent(AdConsent(isAgeRestrictedUser: true))` inside that window and
  have it silently dropped: the adapter had already been told `false`, and
  `setConsent()`'s own re-init branch could not run on a first init. MAX served
  ads to a user the host had declared child-directed. Init now re-checks the
  flag on the way out and discards the adapter if it changed.

- **App Open ads were drawn on top of live banners and MRECs.** Google's App
  Open guidance names this placement as prohibited. The resume path walked
  straight into it: inline surfaces are made visible again on resume, and only
  then does the App Open decide to present. Banners and MRECs are now blanked
  for the duration of the fullscreen ad and restored on dismiss (and after a
  failure). A surface hidden for another reason — route-paused, backgrounded —
  stays hidden. Nothing to call; a custom adapter that does not implement the
  new `InlineAdVisibility` capability keeps the old behaviour.

- **The monetization arbitrator priced every ad format out of one pool.** A
  content feed emitting cheap banner impressions dragged the trailing average
  below the *rewarded* threshold, so the next rewarded opportunity — worth many
  times a banner — was vetoed in favour of a VIP nudge, and the emitted
  `ArbitratorNudgeEvent` quoted an eCPM belonging to a different format. The
  same bug compared non-USD revenue against a threshold documented in dollars.
  Each format is now priced from its own history, in its own currency.

- **A rewarded interstitial that was displayed but dismissed early did not
  consume an impression.** The count sat inside `if (result.earned)`, so
  repeating the pattern handed out materially more fullscreen inventory than
  the anti-invalid-traffic caps allow — the publisher's AdMob account carries
  that risk, not the SDK's. It now counts display, like every other fullscreen
  format, and the matching `AdShowEvent` no longer reports `success: false` for
  an ad that was on screen.

- **An iOS Keychain timeout consumed the 1-day trial the user never got.** The
  first-install guard reads the Keychain to decide whether the grace has
  already been given. If that read never answered, the SDK still marked the
  grace as applied — a one-way flag — so the trial was burned without ever
  being granted. The mark now happens only when the guard actually answers; a
  timeout simply tries again next launch.

- **A whitelisted test device lost VIP after ~90 days and could not get it
  back.** `AdConfig.vipDeviceGaids` grants a long window that the stacking cap
  clamps to ~90 days, then set a one-way "already applied" flag — so when the
  clamped window ran out the device silently went back to seeing ads, with no
  way to re-grant short of clearing app data. The grant is re-applied when the
  whitelist still matches and no VIP is active.

- **Banners stayed blank at the exact moment VIP expired.** Gaining VIP hid
  them immediately; losing it did not bring them back until something else
  happened to rebuild the widget. The VIP transition now signals the banner to
  reload.

- **A CCPA / US-state sale opt-out written by a CMP now actually reaches both
  ad providers.** The SDK has parsed `IABUSPrivacy_String` since 2.3.0 and
  reported it through `AdManager().usPrivacyOptedOut`, but `AdConsent.doNotSell`
  was writable by the host and by nothing else — so a user who opted out through
  a CMP still had AppLovin `setDoNotSell(false)` and AdMob
  `restricted_data_processing` unset unless the host separately noticed the
  string and called `setConsent` itself. The opt-out is now reconciled at SDK
  init and on every app resume (so one made while the app was backgrounded lands
  too), and applied to both providers. Tighten-only: a string that says the user
  did NOT opt out, and the absence of any string, never clear a `doNotSell` the
  host set deliberately. `IABGPP_HDR_GppString` is still deliberately not
  decoded — see the new README section "CCPA / US state privacy".
- **A VIP reward earned while the SDK is re-initialising is no longer lost.** The
  watch-ad-for-VIP flow held the VIP manager it read before showing the ad; a
  provider switch or re-init during the ad discarded that manager, so the grant
  was dropped while the screen still reported success. The grant now goes to
  whichever manager is live when the ad finishes.
- **An SDK teardown can no longer roll back the VIP revocation list.** A
  revocation-list fetch still in flight when the SDK was destroyed used to write
  its (older) result over the newer list the re-initialised SDK had already
  cached, making a revoked key redeemable again on the next launch. The fetch is
  now discarded if the manager that started it has been torn down — including a
  teardown that lands while the fetched list is being applied to existing
  grants.
- **A VIP redeem interrupted by an SDK teardown no longer consumes the key.**
  The one-time-use ledgers were written even when the entitlement itself was
  dropped (a discarded manager must not write over the live one's store), which
  left a paying customer with a burned key and no VIP window — durably on iOS,
  where the replay record survives a reinstall. The key is now marked used only
  once the grant has actually been persisted.
- **A refused native AdView destroy could arm a retry timer that outlived
  `destroy()`.** `destroy()` cancels the retry timers it can see, but a destroy
  still in flight fails afterwards and used to schedule a fresh one, which then
  called into a bridge whose listeners were already cleared. It now stops
  retrying once the teardown has begun; the retry chain is unchanged on a live
  adapter.
- **An AppLovin banner/MREC preload landing during `destroy()` aborted the rest
  of the teardown.** The AdView-destroy loops awaited the native bridge while
  iterating a map that the in-flight preload then inserted into, throwing
  `Concurrent modification during iteration`. The exception was swallowed one
  layer up, so the host saw a successful teardown while MREC views were left
  alive, pending `loadAppOpen`/interstitial/rewarded callbacks were never
  answered, and the old adapter kept its config. Repeated destroy/re-init cycles
  accumulated native views.
- **An AdMob ad delivered after `destroy()` leaked its native ad object.** GMA
  can hand over a fill at any time, including after teardown; the four
  fullscreen load handlers stored that late ad into an adapter that had already
  released everything it held, and since the next `initialize()` builds a fresh
  adapter, nothing ever disposed it. Late fills are now released on arrival.
  Banner/MREC/native were already covered by their per-key identity guard.
- **A valid VIP key was rejected as "invalid or expired" when redeemed in the
  first second after app launch.** The connectivity plugin's first snapshot
  after process start can report offline on a device that is online (seen in 3
  of 36 launches on a real phone), and the redeem gate trusted that single
  read. It now polls for up to 2s and lets the first positive answer through.
  A genuinely offline redemption also stops lying about the cause:
  `SignedVipRedeemResult.isOffline` is set (the `status` stays
  `VipRedeemStatus.invalid`, so no exhaustive `switch` in a host app breaks),
  and the shipped `VipRedeemScreen` shows a new `VipRedeemStrings.offlineMessage`
  ("No internet connection. Connect and try again — your key is still valid.")
  instead of the invalid-key message.
- **An ad load could start during `destroy()`, and its callback could crash the app.**
  The four `loadX` methods now refuse while a teardown is in flight, and an
  `AdSlot`'s state notifier drops (and counts) writes that arrive after it was
  disposed. Before this, a native load callback landing after teardown wrote a
  disposed `ValueNotifier` and threw `A _SlotStateNotifier was used after being
  disposed` — reachable by any app that called `destroy()` while an ad was
  loading. Requests fired during a teardown are also pure waste: never shown,
  but counted by the ad network as a request with no impression.
- **A VIP rewarded ad could play, and pay out, over an SDK being torn down.**
  The teardown check sat at the head of each show method, but the VIP
  "watch an ad to extend your window" path then waits up to 15s for an
  on-demand load, and the re-check after that wait did not know a `destroy()`
  had started meanwhile. The teardown is now part of the shared fullscreen
  busy gate, so every ad type and every post-wait re-check inherits it. The
  public `fullscreenBusy` notifier is recomputed on both edges of a teardown.
- **`AdManager().adapter` returns `null` while a teardown is in flight.**
  The adapter's own `show…` methods are public and answer to none of the
  safety layers in `AdManager`, so a host holding the adapter could drive the
  native layer straight past consent, caps and the fullscreen mutex during a
  teardown. Fetching it mid-teardown now yields nothing to call. (Banner /
  MREC / native widgets read this getter and correctly stop building.)
- **A resume that started just before `destroy()` could still show an ad.**
  Detaching the lifecycle observer stops a *new* resume, not one whose 500ms ad
  buffer was already running — its completion callback found the adapter still
  live and showed an App Open ad on top of an SDK being torn down. No fullscreen
  ad (App Open, interstitial, rewarded, rewarded interstitial) can now start
  while a teardown is in flight; the attempt is reported as a
  `teardown_in_flight` skip event instead.

- **One paused `events` subscriber could hang `destroy()` — and brick the SDK.**
  The teardown awaited the event-stream close with no bound. A host subscription
  may legally be paused (route transition, backpressure), and a paused subscriber
  buffers the done event, so the close never completed — while every later
  `initialize()` parked behind the in-flight teardown and `isInitialised` still
  answered `true`. The wait is now capped at 2s with a warning log.

- **An App Open ad could be shown on top of an SDK being torn down.** The app
  lifecycle observer was detached at the very end of `destroy()`, and the resume
  fallback timer cancelled later still, both after the teardown's awaits — across
  which the adapter and config are untouched, so every guard on the resume path
  still passed. A user returning to the app mid-teardown could be shown an ad,
  with the native call landing on an adapter about to be disposed. Both are now
  disarmed before the teardown's first await.

- **The 5-minute ad-refill poll can no longer fire inside a teardown.** The poll
  guards itself on `isInitialised`, which is `_config != null && _adapter != null`
  — and both fields stay non-null until well past the teardown's first `await`. So
  a tick landing in that window passed every guard and refilled ads into an adapter
  about to be disposed. The poll and the connectivity watch are now both stopped
  before the first await, matching what re-`initialize()` already did.

- **A pending init retry can no longer bring the SDK back after `destroy()`.**
  The retry timer was cancelled at the end of the teardown, so it stayed armed
  across the event-stream close and the adapter dispose. A retry firing in that
  window waited the teardown out and then built a whole new session — adapter,
  timers, connectivity watch and ad requests — moments after the host's
  `await destroy()` returned. The retry is now cancelled before the teardown's
  first await.
- **Two `destroy()` calls at once no longer tear the SDK down twice.** The
  second caller waited for the first teardown and then ran a whole extra one:
  every widget subscribed to `initRevision` rebuilt twice, and if the app had
  already restarted the SDK in between, the redundant teardown disposed the
  *new* session's adapter — ads silently dead for the rest of the process.
- **A cancelled init retry no longer strands the caller it was holding.** When
  native init fails the SDK arms a backed-off retry that owns the caller's
  `onComplete`. Cancelling that retry — which both a fresh `initialize()` and
  `destroy()` do — threw the callback away with the timer, so that caller was
  never answered at all. A splash that tapped its own "Retry" button mid-backoff
  therefore waited out its hard-cap timer even though the SDK had come up. The
  callback is now handed to the replacing attempt (and hears its real result),
  or answered `false` by the teardown.
- **A reported init failure no longer leaves the SDK claiming it is
  initialised.** If a step *after* the ad provider came up threw — applying
  consent to the providers, or reading the stored IAB consent string — the host
  was told initialisation failed while `AdManager().isInitialised` still
  answered `true`, with a live native adapter and its listeners still attached.
  An app that does not re-initialise on failure leaked that adapter for the rest
  of the process, and it kept serving ads. The SDK now tears the adapter down
  before reporting the failure, so the two answers agree — and it does so even
  when the ad provider's own teardown throws, which used to abandon the state
  reset half-way and bring the same contradiction back.
- **`destroy()` now really stops an `initialize()` that is still running.**
  Native SDK init can take up to 20 seconds, and an app that gave up and tore
  the SDK down in the meantime used to have it come back to life afterwards:
  the finishing attempt installed its ad provider, timers and connectivity
  watch into the torn-down SDK and reported success, so `isInitialised` went
  `true` again moments after the app had been told the SDK was gone. Such an
  attempt now releases what it built and reports failure instead. Same for the
  narrower window while consent is being applied to the providers.
- **A parked caller can no longer be stranded** by another parked callback that
  calls `initialize()` again, or by one that throws. A callback that re-enters
  `initialize()` while the queue is being answered is handed the result being
  delivered on the spot instead of parking behind it. The queue is also capped
  at 32 waiting callers (the 33rd is told `false` at once rather than parked),
  and a caller that parks during `destroy()`'s own teardown — a window that had
  already drained the queue — is answered by the abandoned attempt rather than
  waiting for a callback that would never fire.
- **A consent answer from a torn-down session can no longer open the live
  session's ad gate.** The UMP consent flow is not awaited (it presents a native
  form and can take minutes), so its result could land after the app had torn
  the SDK down and initialised it again — and it was written to the ad gate
  regardless. A session that is deliberately holding ads back until its own
  consent flow answers, or that runs a stricter config (an under-age-tagged one,
  say), could therefore be overruled by an answer gathered for a session that no
  longer exists. UMP results and the fail-open error path are now bound to the
  session that started them, matching the privacy-options form.
- **`destroy()` no longer takes a session that started during its teardown apart
  with it.** Tearing the SDK down involves waiting on the ad provider, and an
  `initialize()` arriving in that window used to be built and then dismantled by
  the rest of the teardown — most visibly it lost the app-lifecycle observer, so
  App Open on resume and the ad pause/resume hooks silently stopped working for
  the rest of the process. `initialize()` now waits for an in-flight `destroy()`
  to finish, so a destroy-then-initialise pair does what the app asked, in the
  order it asked.
- **An abandoned `initialize()` can no longer damage the session that replaced
  it.** Two failure paths did not know they had been superseded. One: an attempt
  whose provider init came back `false` after `destroy()` still armed its
  5-second retry timer, so the torn-down SDK re-initialised itself, and still
  fired the init-completion event with `false` — and because the event bus
  replays its most recent event, a splash that subscribed late was told init had
  failed even when a later attempt had succeeded. Two: an attempt that *threw*
  after another attempt had already won decided what to tear down by reading the
  shared state, so it disposed the winner's live provider and flipped
  `isInitialised` back to `false` for a session that never failed. Both now bow
  out and report only to their own caller. Same check added after the VIP load
  and the consent bootstrap, so a `destroy()` during either can no longer leave
  a torn-down SDK holding live VIP or consent state.
- **`SafeLogger.critical` can no longer be hidden by `logTagFilter`.** It
  already ignored `AdLogLevel.none`; it now ignores the tag filter too. The two
  events that use it — a release build forcing `dryRun` back off, and a config
  that can never gather consent — mean your own configuration is wrong, and the
  consent one is the difference between showing an EEA/UK user a consent form
  and not. An app filtering logs down to its own tags used to lose it silently.
  Ordinary `d()`/`w()`/`e()` still respect the filter exactly as before.
- **A second `initialize()` call made while the first is still running is no
  longer answered with silence.** It used to log "skipping duplicate" and
  return without ever calling that caller's `onComplete` or firing an event, so
  an app whose splash awaited the second call waited forever. Such callers are
  now parked and told the real result of the in-flight attempt (and told
  `false` if `destroy()` happens first). They still never start a second ad
  provider.
- **The iOS "you called `initialize()` before `requestAtt()`" warning now
  actually fires under test**, which is how it was found to be untestable in the
  first place: it asked `dart:io` whether the platform is iOS, and now asks
  Flutter. Same answer on a real device.
- **A host `onLog` callback that throws can no longer strand the SDK.** Every
  log now goes through one guarded emitter, so an exception out of your own log
  sink is caught and reported instead of unwinding whatever the SDK was doing —
  which, for logs written from inside a teardown's `catch`, meant the state
  reset stopped half-way.
- **An app that calls `initialize()` again from its own failure callback is no
  longer ignored.** The in-progress guard was still held while `onComplete(false)`
  ran, so a host retrying with a fallback configuration from inside that callback
  was dropped silently: it had been told initialisation failed and its own
  recovery then did nothing.
- **A developer warning no longer silently disables ad loading for the whole
  session (debug/profile builds).** The two `assert`s described below ran ahead
  of the App Open + banner preload, the ad retry timer and the connectivity
  watch. In a non-release build the assert threw and all of those were skipped,
  so ads simply never loaded — a symptom that looks nothing like the warning
  that caused it. Both `assert`s are now **gone**: an assert inside a `try` that
  catches everything can never crash anything, it only produced a stack trace
  the SDK then logged as if init itself had failed. The warnings are now
  `SafeLogger.critical` instead, which reaches your own `onLog` sink and is not
  silenced by `AdLogLevel.none`. The release-mode consent block, and the rule
  that no ad is requested while no consent flow is configured, are unchanged.
- **A splash screen no longer hangs waiting for an init-completion event that
  never comes (debug/profile builds).** The SDK's two developer warnings — no
  consent flow configured, and `requestAtt()` never called on iOS — are
  `assert`s, and they ran *before* `initialize()` told the host it had finished.
  In any non-release build the assert threw, the init body swallowed it, and the
  host callback plus the completion event were skipped even though native init
  had actually succeeded: a splash built on the documented contract (subscribe
  to the init event) sat there until its own hard-cap timer rescued it. The
  warnings now fire after completion is reported, and a host `onComplete` that
  throws can no longer swallow the event either.
- **A failure after native init no longer re-initialises the SDK every 5
  seconds forever.** The auto-retry budget is reset once the adapter comes up,
  so anything throwing after that point — including a host `onComplete`
  callback that throws — got an unbounded retry: rebuild the adapter, throw
  again, reset the budget, retry again. Such a failure is now terminal and
  reported once; a genuinely failed native init keeps the bounded retry it
  always had.
- **Ad impressions are now counted from whether the ad reached the screen, not
  from how the show ended.** Three separate symptoms turned out to be one
  mistake: a rewarded ad the user closed after two seconds, a
  rewarded-interstitial that never displayed, and an app-open ad resolved by
  the 90-second hard cap were all mis-accounted. A real display that earned no
  reward counted as nothing (so the daily/hourly caps that protect the AdMob
  account stopped seeing those impressions), while a show that never reached
  the screen was reported to the host as `shown: true`. There is now one
  authoritative signal, `AdSlot.displayConfirmed`, set when the native SDK
  confirms the ad is on screen, and both adapters plus `AdManager` read it.
- **`RewardResult.shown` now defaults to `false` and means "the native SDK
  confirmed this ad reached the screen"** — independent of `earned`. It used
  to default `true`, so every never-displayed path reported a display.
  Hosts reading `onDone(shown, earned)` get the truth now; a host that treated
  `shown` as "the user watched something" should re-check that assumption.
- **AdMob's app-open slot never called `markDisplayed()`** — the only
  fullscreen slot that didn't, which is why its hard-cap path could not tell a
  real display from a lost callback.
- **A device clock parked in the future can no longer mint a permanent VIP**
  (MJ9, carried as a documented limitation for three rounds). Setting the clock
  a year forward, redeeming any grant, then correcting the clock used to leave
  an entry that never expired, because the anti-rollback high-water mark was
  the only clock consulted and it agreed the entry was mid-window. An entry now
  additionally has to have *started* according to the raw device clock, while
  expiry keeps using the mark — so the 30-day-rollback defence is unchanged.
  A suppressed entry is never deleted, only suppressed, so a customer whose
  device clock was genuinely fast when they paid keeps their grant.
- **VIP grants are persisted as UTC.** They were written as local ISO-8601
  with no timezone marker, so the same text read back on a device that had
  changed zone (a flight west, a region's UTC-offset change) resolved to a
  different instant — up to a day earlier. `VipManager` then read the grant as
  expired and `_purgeExpired()` deleted it, with no server to restore from.
  Entries are stamped UTC on write and converted back to local on read, so
  every existing consumer (display, countdowns, `difference`) is unchanged.
  Entries written by 2.3.4 and earlier still decode.
- **The VIP grace nudge no longer fires at grant time.** Its default threshold
  (24h) is exactly the default first-install trial length (24h), so a
  brand-new user saw "your VIP is about to run out" on their first launch. The
  threshold is now capped at half the granted window, in both the check and
  the timer that schedules it.
- **A revoked VIP key id (`kid`) is now matched case-insensitively at
  redemption.** Clamping an already-granted window matched through
  `normaliseKey` (upper-cased) while the redemption gate compared exact case,
  so a CRL whose kid case differed from the key's clamped the old grant but
  still handed out a fresh one for the same revoked key. Both mint tools
  (`tool/vip_mint.dart`, `tool/vip_crl_mint.dart`) now upper-case kids, and
  keys minted before that still match.
- **`compliance_signing.dart` returned a `Future` without awaiting it inside a
  `try`**, so a corrupt stored seed threw past the fallback instead of minting
  a fresh key pair. (Also the 20 pana points that warning was costing.)
- **`pubspec.yaml` pointed at a repository that 404s** (`FlutterBase2025` →
  `FlutterBase2026`), which broke the source links and the License link on the
  live pub.dev page.

### Documentation

- README: the `buildAdmobNativeView(key)` sample now compiles, the `logLevel`
  default is documented as build-mode-gated (debug `.verbose`, release
  `.warning`), the Step 5 splash sample no longer leaks its `SimpleEventBus`
  listener and now calls `requestAtt()` before `initialize()`, the `AdConfig`
  configuration reference lists the four params it was missing
  (`maxVipStackDuration`, `onPrivacyPolicyTap`, `disableAppLovinCmpFlow`,
  `enableCrashGuard`), and the quick-start floor is current.
- `doc/AD_PROMPT_FLUTTER.MD`: the flagship splash snippet compiles again
  (`adMob:` → `admob:`).
- Stale version pointers and test counts refreshed in `CLAUDE.md`,
  `doc/README_TESTING.md`, `doc/feature.md` and `doc/architecture.md`.
- The offline VIP redemption path and the always-on QA test-device hashes are
  now commented at the source as deliberate product decisions, so reviewers
  stop re-filing them as defects.

### Changed

- `flutter_secure_storage` widened to `>=10.0.0 <12.0.0`. This package still
  resolves 10.x (11 needs win32 ^6, which `package_info_plus 9` blocks, and
  `package_info_plus 10` needs Flutter >= 3.38.1) — the wide bound lets a
  consuming app that is already there pull 11.

## [2.3.4] - 2026-08-25

Nine further QC rounds (13-22) on the consent path alone, all of them driven by
on-device verification rather than by the unit suite. Both final reviewers
scored the result 10/10 with zero findings. Verified on a Samsung A50 and a
Samsung A11 (the consent resume backstop, 5/5 on each).

### Fixed

- **A rewarded ad can now be watched more than once per session (AdMob).**
  Found by an on-device smoke test with real AdMob test ads, not by the suite:
  AdMob delivers `onUserEarnedReward` *before* `onAdDismissed`, and the reload
  hung off the reward callback — so it ran while the spent ad was still cached
  and did nothing, and no second reload ever came. After one completed rewarded
  ad the slot stayed empty for the rest of the session, so the next "watch an
  ad for a reward" tap silently did nothing until the app was restarted. The
  refill now happens on dismissal, where the spent ad is already cleared, and
  still goes through AdManager's own gate (VIP / daily cap / consent / network).
  Rewarded Interstitial had the identical shape and is fixed with it. The
  AppLovin adapter was never affected — it reloads inside its own
  `onAdHiddenCallback`.

- **Withdrawing consent through the Privacy Options form now applies even when
  the form is open for a long time.** Found by on-device verification (Pixel 7
  Pro, EEA debug geography — see `doc/audit/audit_round13_device.md`), not by a
  test: the flow gave up waiting after 20 seconds, read the consent status
  *while the native form was still on screen*, and never read it again. A user
  who spent longer than that in the form and then withdrew consent kept getting
  personalised ads for the rest of the session, with their own withdrawal on
  record. The wait is now the same human-reading bound as the initial consent
  form (`kFormDismissTimeout`), a late dismiss re-reads and re-applies the real
  choice, and every app resume re-applies consent when the device's IAB TCF
  state disagrees with what the providers were told — so a withdrawal cannot be
  lost even if the dismiss callback never arrives at all.
- **A consent withdrawal now applies with no network at all.** The re-apply that
  carries a withdrawal used to re-read the device's TCF state a second time, and
  used to wait on UMP unbounded. Offline, or during a UMP outage, that second
  read could throw or come back empty — and "no TCF data" means "assume
  allowed", so a re-apply that was meant to carry a refusal came back out of the
  pipeline as a grant, leaving both providers personalised under a user's
  refusal. The withdrawal is now settled by the refusal the caller already read:
  the UMP read is bounded to 2 s and optional, the ad gate is closed for the
  duration of the write and reopened by an owed-recovery debt that a reconnect
  also pays, and a newer host `setConsent` landing mid-check always wins.

## [2.3.3] - 2026-08-23

Six more independent QC rounds (7-12) over the whole package, against the seven
product requirements. Every claim below is backed by a test verified red against
its own reverted fix — nothing else. Full write-ups in `doc/audit/`.

### Security

- **A withdrawn consent no longer leaves a personalised load in flight.** Only
  one of the three consent axes was tracked, so withdrawing while a request was
  already out let that request complete and serve under the old string. Every
  slot loaded under a superseded consent epoch is now refused at show time and
  reloaded.
- **UMP `obtained` is no longer read as consent to personalised ads.** It only
  means the user answered the form; the actual TCF purposes are now parsed
  before anything personalised is requested.
- **A missing UMP platform channel fails closed in release too.** It used to
  fail open, which on a device where the channel was unavailable meant serving
  ads to an EEA user who was never asked.
- **No ad can be drawn over an open consent form.** Presenting the privacy
  options / re-consent form now blocks full-screen ads for as long as the form
  is up (ref-counted, with a logged 15-minute backstop so a dropped dismiss
  callback cannot block ads for the rest of the process).
- **A plaintext-fallback VIP grant is only trusted when the Keystore is
  broken.** That fallback exists for devices whose secure storage does not work;
  a fallback entry on a device whose Keystore is healthy has no legitimate way
  to exist, so it is now clamped instead of accepted outright.
- **A revocation list now clamps grants the revoked key already made,** and the
  cached list is applied on every startup, not only when a fresh one is
  fetched.
- **A host re-init no longer forgives an invalid-traffic escalation,** and
  `bypassSafety: true` (the splash App Open ad) no longer skips the
  invalid-traffic pause.

### Fixed

- **Blank banner/MREC that never recovered.** The rate limiter reported a
  throttled load as an error, which the recovery loop treated as a broken slot,
  which re-entered the limiter — a grey box for the rest of the session.
  Display errors and "needs recovery" are now separate states, and the recovery
  bypass is itself rate-limited.
- **A full-screen slot could wedge for the session.** A swallowed show on
  either provider left the slot in `showing` forever; both providers now
  release it.
- **AppLovin banner/MREC could stick in `loading` forever** (watchdog added) and
  could resurrect a key disposed mid-preload, leaking the native ad view.
- **A transient secure-storage read no longer costs a paying customer their
  VIP.** A failed read is now told apart from "no VIP data" and retried inside
  the session instead of running the whole session as non-VIP.
- **VIP writes are strictly ordered process-wide.** A discarded manager's
  in-flight write could land on top of its replacement's and resurrect an
  entitlement that had just been revoked. Startup stays bounded: the load's
  drain gives up rather than hanging on a wedged platform write.
- **A redeem on a disposed manager no longer burns the customer's one-time
  key.**
- **The ad-click latch is spent by the resume that saw it,** so returning from
  an ad click cannot trigger an App Open ad.
- **The M6 fallback clamp is anchored to the grant timestamp,** so a failed save
  no longer rolls the clamp forward on every launch.


### Fixed — lifecycle & cache-expiry round (audit MINOR m15/m16/m18/m22/m24/m36)

Each item below is backed by a test that was verified red against its own
reverted fix, and nothing else.

- **A cached ad could read as "fresh" for the rest of the session after a
  clock change.** The freshness check compared wall-clock `now` against the
  wall-clock load stamp with no lower bound, so a backwards clock change
  (manual, or an NTP correction) put the stamp in the future, made the computed
  age negative, and kept the ad inside its validity window forever. Both the
  reuse-on-load and the refuse-to-show-a-stale-ad guards stopped working. A
  negative age now counts as stale.
- **Discarding an expired ad blocked its own replacement.** All four AdMob
  full-screen formats recorded a cache expiry as a *load failure*, which starts
  the exponential-backoff cooldown. The refill fires from the very callback the
  discard invokes, so it landed inside a cooldown window the discard had just
  created and the slot stayed empty until the next periodic retry — no ad for
  the next several show attempts. An expiry now just empties the slot; the load
  path never failed.
- **`canShowInterstitial()` / `canShowRewardedAd()` could report `true` for an
  ad that would not be shown.** Both only asked whether the slot was ready, so
  a cached AdMob ad that aged past its 1h content validity while the host was
  polling still reported showable — and the show call then discarded it. A host
  gating a button on these got a button that did nothing.
- **Revenue could be reported for a disposed full-screen ad.** Every
  `google_mobile_ads` wrapper cleared its full-screen content callback on
  dispose but left the paid-event listener wired, so a paid event arriving after
  disposal still emitted revenue through the old event sink.
- **AppLovin: destroy retries outlived the adapter.** The retry that makes
  `destroyWidgetAdView` succeed once the native view has finished detaching
  slept on an untracked timer, so a chain started by the last widget unmount
  before teardown kept calling into the bridge for up to ~1.7s after
  `dispose()` had already cleared every native listener. The retries are now
  cancelled by `dispose()`.
- **Per-widget notifiers were leaked when a key never got a slot.** Both
  adapters' `dispose()` walked only the slot maps, but the per-key listenable
  bundles (and AppLovin's per-key ad-view-id notifiers) are created
  independently of the slot, so any key that only ever had those kept its
  `ValueNotifier`s alive for good.

## [2.3.2]

### Fixed — independent review, round 3

Two independent QC passes over the round-5 work found these. As above, each
claim is backed by a test verified red against its own reverted fix.

- **AppLovin native ads never came back after a consent change.** Withdrawing
  personalisation consent (or closing and reopening the consent gate) makes the
  widget drop its live native instance and immediately re-load — reusing the
  same instance key, because that key *is* the widget's `State`. A tombstone
  added to stop late callbacks from resurrecting a dead key was permanent, so
  the reload got a disposed slot and disposed `ValueNotifier`s instead: the ad
  never returned for the rest of that widget's life, and callbacks wrote to
  disposed notifiers. The tombstone is now lifted when a live widget re-loads
  the key, while a late callback for a key nobody revived still gets the shared
  disposed sentinel — so the leak the tombstone exists to prevent still cannot
  happen. AdMob was unaffected (it guards by slot identity, not by key).
- **A throwing event-bus subscriber could take down the splash screen.**
  `SimpleEventBus.fire` guarded every listener so one failure couldn't block
  the others, but the later-added replay in `listen` did not — so a subscriber
  that threw escaped straight out of `listen()` into its caller. Per the
  integration contract that caller is a `listen()` line in the consuming app's
  splash. Guarded, matching `fire`.

### Fixed — independent review, round 2

A second independent reviewer went over the round-5 diff after it shipped
(same discipline as the first: every claim below is backed by a test that
fails against the reverted fix, not taken on trust).

- **An abandoned consent form could mute the UMP gate for the rest of the
  session.** The round-1 fix for "the backstop could present a second form on
  top of one our own timeout couldn't close" simply stopped retrying entirely
  once that happened — worse than not having the fix at all: a user who
  answered the still-open native form 10 seconds later got zero ads until an
  app restart, whereas the un-patched backstop at least kept retrying and
  could reopen the gate. Both the periodic backstop and the reconnect retry
  (which never checked this state at all) now recheck Google's local,
  already-cached consent decision — no form, no network call — so they can
  self-heal without risking a second dialog.
- **The App Open hard-cap watchdog compared a field to itself.** It read
  `_appOpenAd` fresh when the timer fired and checked that value against
  itself, which is always true and guards nothing. Not reachable through any
  load/show path today (other guards happen to cover it), but a maintenance
  hazard for the next change here — fixed to capture the specific ad at arm
  time, same as every other call site in the file already does.
- **A test canary asserted its own hand-rolled copy of a config object,
  never production's.** Deleting the field it exists to guard from the real
  code left the test green. The production build is now exposed for the test
  to call directly.

### Fixed — 8 of 12 round-5 fixes that shipped with no regression test

Same review found a large fraction of round-5's diff was revertible in bulk
with the suite staying green — the fix existed but nothing exercised it. Each
one below now has a test verified red against its own reverted fix:

adapter-orphan-on-failed-init disposal, the new banner/MREC/native load
watchdog (plus its dead-cache cleanup and a dispose-during-await race in the
banner path), the AppLovin COPPA re-init reachability fix, the UMP mutex's
240 s self-heal timeout, `AdLoadingDialog.show()`'s flag-ordering fix, and
the banner widget's consent-withdrawal listener (the fix already existed;
only a counter was asserted, not the widget behaviour it drives). Two related
fixes — the identical one for MREC/native widgets, and a rewarded-dialog
ownership check that turned out to be unreachable through any current call
path — remain unverified; see `doc/audit/audit_claude.md`'s handover section.

Round-5 audit, commits 2–3: the rest of the consent surface, then the
fullscreen-lifecycle failures that could kill a surface for a whole session.

### Fixed — issues found by an independent review of the fixes above

An independent reviewer was pointed at the round-5 diff before it shipped. It
found that three of the flagship fixes did not work on their own main path, and
that one of them made a transient hang permanent. All of it was confirmed by
reading the code, not taken on trust — and one of the reviewer's own
recommendations was rejected after reading the test that documents the opposite
invariant (see below).

- **The "withdrawing personalisation discards cached ads" fix was dead code.**
  It compared `_consent` against the incoming consent inside the listener, but
  `setConsent()` assigns `_consent` *first* and only then calls
  `ConsentManager.set()`, whose `ValueNotifier` notifies synchronously — so the
  listener always saw the new value on both sides and the guard could never
  fire. Every withdrawal route (`showPrivacyOptions()`, `requestUmpConsent()`,
  a host's own `setConsent`) goes through exactly that sequence, so personalised
  fullscreen ads already in the cache were still shown. Now compares against
  what was last actually applied to the adapter, which no assignment order can
  break. Regression test included, and verified to fail against the old code.
- **Its inline-ad half was a no-op too.** Bumping `initRevision` cannot rebuild
  a banner that is already showing: each widget's listener only re-inits when it
  has no ad, and withdrawing personalisation does not close the `canRequestAds`
  gate that would clear that state. A dedicated `personalisationRevision`
  signal now tells banner/MREC/native to drop their live instance and reload.
- **The COPPA-on-AppLovin recovery could not be reached.** `setConsent()`
  returned early when the SDK was not initialised, *above* the block that
  rebuilds the adapter — but the child-directed abort is exactly what leaves it
  uninitialised, so the host's later "not a child after all" call returned
  before the recovery ran. The block now runs first, and the last known-good
  config survives adapter teardown so there is something to rebuild from.
- **The new banner/MREC/native load watchdog relabelled the slot without
  clearing the dead ad.** `loadBanner` early-returns while the key is still in
  `_bannerAdsByKey`, so the cached-but-dead ad blocked every later load for
  that widget instance; only a remount (which produces a new key) appeared to
  recover. The watchdog now drops the ad object as `onAdFailedToLoad` does.
- **The UMP in-flight mutex had no deadline** — the one guard added this round
  without one. `setConsent` → `_persist()` → `updateRequestConfiguration` are
  all unbounded, so a single wedged channel meant every later
  `requestUmpConsent()` joined a future that could never complete: the gate
  would stay shut with no self-heal, strictly worse than the lockout this round
  set out to fix. Now capped at 240 s, and the lock is only released by the
  call that owns it.
- **After the 180 s form timeout the periodic backstop could present a second
  consent form** on top of the first, which `Future.timeout` does not close.
  The backstop now recognises that state and rechecks Google's already-cached
  consent decision (no form, no network call) instead of presenting another
  one — see "Fixed — independent review, round 2" below for why the first cut
  of this (standing down entirely) was itself a regression.
- Smaller ones from the same review: the IAB read's deadline now covers
  `PackageInfo` (an unbounded channel it was skipping), `AdLoadingDialog.show()`
  got the same flag-ordering fix its sibling already had, the rewarded path no
  longer claims ownership of a dialog it did not open, and the App Open hard cap
  clears the field by identity like the callbacks do.

### Changed — after the review

- `AdConfig.autoShowConsentDialog` now documents that it has **no effect** with
  the default `autoRequestUmpConsent: true`. The behaviour was introduced above
  on purpose — the built-in dialog is not a certified CMP and produces no TCF
  string — but shipping a default-true flag that silently does nothing, with no
  word in its own doc, is its own kind of trap.
- `shared_preferences_android` is declared without an upper bound. A `<3.0.0`
  cap would become a new pinning wall for every consuming app the moment
  `shared_preferences` requires 3.x. A compile-time canary test guards the
  platform API this package leans on instead.

### Fixed — lifecycle (commit 3)

- **App Open could die for the rest of the session, and leak two native ads
  doing it.** After the 90 s hard cap force-dismissed a show, AdManager
  reloaded and a new ad took the field — and then the abandoned ad's native
  callback arrived and cleared that field unconditionally, destroying the
  replacement. `appOpenSlot` still reported ready, so `showAppOpen` returned
  false against a null ad forever, and `_retryRefillAds` only refills
  idle/cooldown slots so nothing repaired it. Callbacks now clear the field
  only while it still points at their own ad, and the watchdog disposes the ad
  it gives up on instead of just forgetting it.
- **The App Open watchdog was armed after `await ad.show(...)`.** If the
  platform call itself never resolved — the exact hang the watchdog exists for
  — it was never armed at all. Armed before the await now.
- **`AdLoadingDialog.showAdBuffer` could block every fullscreen ad for the
  session.** It set `_isShowing = true` before `Navigator.of()` and the route
  push, neither guarded, and every caller is fire-and-forget: a throw left the
  flag stuck true, so `_fullscreenBusyReason` reported "ad loading buffer
  showing" forever, and `onComplete` never ran — hanging a splash that awaited
  it. The flag is now raised only once the route exists, and a failure still
  calls `onComplete` as the docstring promises.
- **`AdLoadingDialog.dismiss()` could strand a later dialog with no way to
  close it.** Unlike `resetState()` it did not bump the generation, so a
  sleeping `showAdBuffer` timer woke up, believed it was still current, and
  cleared state belonging to a NEWER dialog — which then had
  `barrierDismissible: false`, `PopScope(canPop: false)` and a `dismiss()`
  that early-returns: a frozen UI. The rewarded on-demand path also stopped
  dismissing dialogs it never opened.
- **A failed `initialize()` left the adapter alive.** AppLovin wires its four
  native listeners before awaiting SDK init, so on the 20 s timeout branch the
  native side could still come up and keep calling into slots this manager had
  abandoned — up to four orphans across the retry chain, each holding ~15 live
  `ValueNotifier`s.
- **Banner / MREC / native could sit "loading" forever.** They had no load
  watchdog (all four fullscreen formats do), so a GMA listener that never fired
  left the slot refusing every later `beginLoad()` and the widget showing its
  shimmer placeholder with `hasError` false. Now bounded at 30 s, which lands
  the slot in `cooldown` — a state a remount retries.
- **The crash guard's slot recovery skipped rewarded-interstitial, MREC and
  native.** That pass is the *only* recovery for a slot stuck `showing`, since
  those formats deliberately have no show-watchdog; if the callback that would
  have advanced the slot was the thing that crashed, it stayed stuck.
- **Four `show*` catch blocks dropped the ad without disposing it**, leaking
  the native object. Reachable: `gma_bridge` awaits `setServerSideOptions()`
  before showing, and a platform call can throw.

### Fixed — consent (commit 2)

- **The consent-footgun guard was fail-open on AdMob.** It treated
  `disableAppLovinCmpFlow: false` as proof that a consent flow existed, but
  that flag is only ever read by `AppLovinAdapter.initialize`, so on AdMob it
  means nothing. The combination `provider: admob` +
  `autoRequestUmpConsent: false` + `disableAppLovinCmpFlow: false` — a config
  the SDK accepts silently — produced no warning and left `canRequestAds` at
  its default `true`: EEA/UK users served ads with no consent flow at all.
  AppLovin's CMP now only counts when AppLovin is the active provider.
- **AppLovin received its privacy flags after `AppLovinMAX.initialize`, not
  before.** On an ordinary cold start (host never called `setConsent`, so
  nothing was buffered) the post-init `applyToProviders` was the first time
  AppLovin heard about consent — MAX documents these as init-time settings.
  `AdProviderAdapter.initialize` now takes the consent state so each adapter
  can apply it in the order its own SDK requires.
- **`tagForUnderAgeOfConsent` never reached AdMob.**
  `AdConfig.umpTagForUnderAgeOfConsent` only fed UMP's consent form, so an app
  declaring an under-age audience got the right form and then sent every ad
  request out with no under-age signal. Now set on `RequestConfiguration` —
  only ever as `yes`; absent an explicit declaration it stays `unspecified`
  rather than asserting `no`.
- **A UMP re-run could silently wipe a CCPA opt-out or the COPPA flag.**
  `AdManager._consent` was a second source of truth that
  `ConsentManager.set()`/`reset()` never updated, so anything rebuilding an
  `AdConsent` from it (a UMP backstop retry, `showPrivacyOptions()`) wrote
  `doNotSell: false` back to disk, to AdMob's `rdp` extra and to AppLovin's
  `setDoNotSell`. The two are now kept in sync at the single point every
  consent change already flows through.
- **Withdrawing personalisation mid-session did not invalidate already-loaded
  ads.** `applyConsent` only affects future requests, so the personalised
  app-open/interstitial/rewarded ads already in the cache were still shown and
  banners kept refreshing; ad age was the only thing that could discard them.
  New `AdProviderAdapter.discardCachedFullscreenAds()` runs on a
  `true → false` transition, alongside an `initRevision` bump for inline ads.
  Never touches an ad that is on screen.
- **COPPA on AppLovin was a one-way door.** Setting `isAgeRestrictedUser: true`
  correctly hard-stops ad requests (MAX 4.x has no runtime API for it), but
  correcting the flag back to `false` left every AppLovin surface dead for the
  rest of the process with nothing in the log to say why. The adapter is now
  re-initialised when the flag changes in either direction.
- **`tcfConsentString` always returned `null` on real devices.** It read
  through the legacy `SharedPreferences` API, which on Android reads its own
  private file (UMP writes to the app's *default* store) and on iOS prefixes
  every key with `flutter.` (UMP writes none). Its unit test passed against
  `setMockInitialValues`, so the API looked wired for four audit rounds while
  answering `null` to every caller. Now reads the platform's own store —
  verified on Android hardware, returning a real TCF v2 string.
- **iOS: a failed ATT status read could trigger Apple's tracking prompt from
  inside `initialize()`.** An unreadable status fell through to "do not defer",
  which then called `AdvertisingId.id(true)` — and that `true` asks the plugin
  to raise the ATT prompt, outside the host's control. Unknown is now treated
  like `notDetermined`, as is a `notDetermined` that survives a timed-out
  `requestAtt()`. The status read itself is now bounded at 5 s, matching what
  the self-check already did to the same call.
- **The built-in consent dialog could ask an EEA user on UMP's behalf.** It is
  a two-button sheet, not a certified CMP, and produces no TCF string — yet a
  "yes" from it was written through to AppLovin. It is now skipped whenever UMP
  owns consent, including when UMP came back inconclusive (the path that made
  this reachable).
- **A one-time connectivity-watch failure disabled the fast path for the whole
  session.** `_startConnectivityWatch()` was called exactly once and is
  best-effort, so a plugin init that threw left `isConnected` pinned to its
  optimistic seed: every offline load just failed into backoff and
  refill-on-reconnect never happened. The poll tick now re-attempts it.
- The consent-footgun check no longer races the un-awaited auto-UMP flow, the
  first-install Keychain read is bounded at 5 s (failing safe: skip the grant),
  and `_attRequested` is reset by `destroy()` like the other guard flags.

### Added

- `AdManager.usPrivacyOptedOut` and `AdManager.gppConsentString` — the IAB US
  Privacy and GPP signals a CMP leaves in platform storage.
  `usPrivacyOptedOut` returns `null` when no string exists, deliberately
  distinct from `false`: `AdConsent.doNotSell` is host-set only, so
  `exportComplianceReport` reported `doNotSell: false` for a California user
  who had opted out through a CMP. GPP is exposed raw rather than decoded —
  mis-parsing a privacy signal is worse than not parsing one.
- `debugFormDismissTimeoutOverride` — lets an on-device harness cap the
  consent-form wait, since no harness can tap a native dialog and would
  otherwise sit out the full 180 s.

### Changed

- `AdProviderAdapter` gains `consent:` on `initialize` and a new
  `discardCachedFullscreenAds()`; `GmaBridge.updateRequestConfiguration` now
  takes the COPPA/TFUA tags (`RequestConfiguration` replaces rather than merges,
  so passing only test-device ids wiped them). Breaking only for a custom
  adapter or bridge implementation.
- Declares `shared_preferences_android` directly. It is already in every
  Android build as the implementation of `shared_preferences`; the direct
  dependency exists solely because `SharedPreferencesAsyncAndroidOptions` —
  the only way to point a read at the app's default preference file, where UMP
  writes — is not re-exported by `shared_preferences`.

## [2.3.1] - 2026-08-22

Consent-path hotfix. Every item below was found by the round-5 audit and the
first two were reproduced on real hardware (Pixel 7 Pro, `debugGeography:
debugGeographyEea`, real UMP forms) before and after the fix.

### Fixed

- **Audit round 5 — the consent form was re-shown on every launch to an
  EEA/UK user who had already answered it.** The flow gated on
  `isConsentFormAvailable()`, which reports whether a form *exists*, not
  whether consent is *required* — and a form stays available after consent,
  because that is what backs the Privacy Options entry point. Confirmed on a
  real device (Pixel 7 Pro, `debugGeography: debugGeographyEea`): a cold
  restart with consent already granted logged `status=obtained
  formShown=true` and put the form back on screen. Now uses Google's own
  `ConsentForm.loadAndShowConsentFormIfRequired` behind a
  `status == required` guard, so an already-answered user is never asked
  again and the common (non-EEA) case skips the platform call entirely.
- **Audit round 5 — the consent gate could stay shut for a whole session
  with no way to recover.** `_umpAttemptFailed` was `result.error != null`
  alone, but UMP returns `error == null` with `canRequestAds == false`
  whenever it resolves from cache without being able to serve a form — the
  ordinary "flaky network on first launch in the EEA" case. Both retry paths
  gate on that flag, so the gate stayed closed for the rest of the process:
  **zero ads, no self-heal short of an app restart**, even once the network
  came back. It now also covers an inconclusive result and a still-closed
  gate.
- **Audit round 5 — the consent form gave the user only 20 s to answer.**
  The dismiss timeout was shared with the network steps, so a person reading
  a real GDPR form (206 partners, an expandable "Learn more") had the flow
  abandoned out from under them, resolving the ad gate before they had
  chosen. Split out to 180 s for the human step; the no-network case is
  still bounded by the 20 s guard on `requestConsentInfoUpdate`, and a cap
  still exists so an unattended simulator cannot hang the flow forever.
- **Audit round 5 — the UMP retry paths could run several consent flows at
  once, and dropped `tagForUnderAgeOfConsent` when they did.** Concurrent
  callers now join the in-flight request instead of presenting a second
  form and racing each other's writes to the gate; retries replay the
  params of the original call, so a child-directed app no longer collects
  consent through the wrong form (which would not have been valid for an
  under-age audience) and an EEA-debug run stays reproducible.
- **Audit round 5 — the periodic UMP backstop was unbounded.** With the
  widened failure flag above, an EEA user who legitimately chose "reject"
  also reads as "gate closed", so the backstop would have re-run the consent
  flow every 5 minutes for the rest of the session. It is now capped, and
  never re-runs for a user UMP already got an answer from.

### Added

- `example`: `--dart-define=UMP_EEA_DEBUG=true --dart-define=UMP_TEST_ID=<hash>`
  drives the real EEA consent path on a test device. Without it a tester
  outside the EEA can never reach UMP's `required` branch, so every EEA-only
  code path stays unexercised — that blind spot is what let the two consent
  bugs above ship. `UMP_TEST_ID` is the hashed device id UMP prints to the
  log on first run.

## [2.3.0] - 2026-08-21

### Added

- `AdMobConfig.effectiveTestDeviceIds` / `kQaTestDeviceHashes` — this team's
  own QA device fleet's AdMob test-device hashes are now always merged into
  `RequestConfiguration.testDeviceIds` on every `initialize()`/consent
  re-apply, regardless of what a host app configures in `testDeviceIds`.
  Keeps manual QA on real hardware from ever counting as real
  impressions/clicks (and the invalid-activity rate-limit risk that comes
  with it), without the host app having to know or maintain the list.

### Fixed

- **Audit fix — `initialize()`'s `autoRequestUmpConsent` branch could fail
  open on a real consent-fetch error, not just an unwired UMP channel.**
  Any exception used to fail the gate open; now only `MissingPluginException`
  (channel genuinely not wired) fails open — every other exception (a real
  UMP fetch failure) fails closed, so a network hiccup can no longer
  silently ship ads with no verified consent decision.
- **Audit fix — `destroy()`/`_resetGuardState()` left the previous session's
  device GAID behind.** A stale GAID surviving past teardown into the next
  `initialize()` is a privacy leak; it's now cleared as part of guard-state
  reset.
- **Audit fix — reopening the `canRequestAdsListenable` gate mid-session
  never triggered a frame in `BannerAdWidget`/`MrecAdWidget`/
  `NativeAdWidget`.** `_onCanRequestAdsChanged()`'s reload path relied on
  `addPostFrameCallback`, which does not itself schedule a frame — the
  reload silently no-opped until some unrelated frame happened to fire.
  Fixed by calling `WidgetsBinding.instance.scheduleFrame()` alongside it.
- **Audit fix — `MonetizationArbitrator`'s with-estimator branch could veto
  ads at zero eCPM.** The no-estimator branch already guarded on
  `ecpm > 0`; the with-estimator branch was missing the same guard, so a
  session with no revenue events yet (`ecpm == 0`) could still have ads
  vetoed whenever the host's likelihood estimator reported > 0.5. Both
  branches now require `ecpm > 0` before vetoing.

## [2.2.0] - 2026-08-20

### Added

- `AdManager().currentDeviceGaid` and `AdManager().adMobTestDeviceHashHint()` —
  the latter returns instructions (device's current GAID included, clearly
  labeled) for finding this device's AdMob test-device hash via logcat tag
  `Ads`, since Google has no public API/formula for that hash. Intended for
  a host app's own debug UI; distinct from the GAID, which is not valid for
  AdMob's `RequestConfiguration.setTestDeviceIds()`.

## [2.1.0] - 2026-08-19

### Fixed

- **2026-08-19 audit: App Open (and interstitial/rewarded/rewarded-interstitial)
  could be shown stale past their expiry window.** The 4h/1h `isAdFresh`
  check was only ever consulted when *loading* (reuse-if-fresh) — `show*()`
  never checked it, so a ready ad that sat unused past expiry (app
  backgrounded a long time, then resumed) could still be shown. For App
  Open specifically this violates Google's documented policy of discarding
  and reloading rather than showing a stale ad. Fixed for all 4 AdMob
  fullscreen types: a stale ready slot is now discarded (native ad
  disposed, slot marked failed → cooldown, eligible for reload) instead of
  shown.
- **2026-08-19 audit: `showAppOpenAdOnResume()` bypassed the daily/session
  safety cap outside the one case (splash) this SDK's own contract
  allows.** It always called `showAppOpenAd(bypassSafety: true, ...)`, so a
  resume-triggered App Open skipped the daily/hourly/session cap and
  CTR-fraud pause entirely while still counting toward the cap via
  `recordFullscreenAdShown()` — an asymmetric bypass. Fixed to
  `bypassSafety: false`; the resume-specific timing gates
  (`canShowAppOpenOnResume`) are unchanged and still apply.
- **2026-08-19 audit: AppLovin banner/MREC widgets leaked their native
  `MaxAdView` on normal disposal.** `disposeBannerInstance`/
  `disposeMrecInstance` released only the Dart-side `AdSlot`/
  `BannerListenables`/`ValueNotifier` — they never called
  `destroyWidgetAdView`, so every `BannerAdWidget`/`MrecAdWidget` that
  permanently unmounts leaked the native ad view. AdMob's equivalent path
  was already correct. Fixed to release the native `AdViewId` on dispose.
- **2026-08-19 audit: `requestAtt()`-before-UMP ordering had no
  release-build footgun.** Forgetting to call `requestAtt()` before
  `initialize()`/`requestUmpConsent()` on iOS was only ever a
  `SafeLogger.w` inside `requestUmpConsent()` itself — easy to miss.
  Added `attOrderFootgunWarning`, wired into `initialize()` alongside the
  existing consent footgun check (loud in every build, not release-gated
  to a hard block since this is a revenue/attribution risk, not a
  legal-compliance one like the consent footgun).

- **Fork-review of the 2026-08-16 audit fixes (2026-08-17): stale load-watchdog
  timer race in `AdSlot.armLoadWatchdog()`.** The watchdog `Timer` created by
  the previous fix kept no handle, so re-arming it (the adapter's own
  internal reload-after-show-failure path does this) left the earlier
  timer alive. If a fast reload started well inside the first timer's
  window, the stale timer could still fire and call `markFailed()` against
  the *new* loading attempt, cutting its real timeout short. `AdSlot` now
  cancels any previously-armed watchdog before arming a new one, and
  `dispose()` cancels a still-pending watchdog too (it previously could fire
  `markFailed()` — a `state.value` write — against an already-disposed
  `ValueNotifier`). 2 new tests in `test/ad_slot_test.dart`. Also tightened
  2 existing tests from the same audit round that didn't actually regress
  if their fix were reverted (`test/vip_revocation_test.dart`'s CRL→AVP1
  relabeling test — documented why that direction is inherently protected
  by Ed25519 rather than by the fix; `test/connectivity_refill_test.dart`'s
  overlapping-call race test — strengthened to assert on the log line the
  discard branch emits, since `_connectivityReady` alone reads identically
  with or without the fix in this unit-test environment).

- **P2 audit cleanup (2026-08-16), two minor findings.**
  - `destroy()` only cleared the banner load-cooldown map, missing
    mrec/native (all 3 added together at T65) — a `destroy()` + fresh
    `initialize()` within the cooldown window (without unmounting the
    widget) left MREC/Native inconsistently "still on cooldown" vs Banner.
    1 new test in `test/ad_manager_test.dart`.
  - Re-entering `initialize()` a second time without an intervening
    `destroy()` (the "auto-disposing previous" branch) didn't remove the
    consent listener before re-adding it — since `ConsentManager` is itself
    a persistent static singleton (survives this branch same as the
    adapter is torn down and recreated), N such re-inits left N copies of
    the listener stacked on it, each firing `applyConsent` redundantly per
    consent change. Fixed by removing it first, mirroring `destroy()`'s own
    cleanup. Not independently unit-tested: reaching the listener
    registration requires a real native adapter `initialize()` call to
    succeed first, which isn't reachable in this repo's plain
    `flutter test` environment (native plugin channels are unavailable) —
    verified correct by code inspection (exact mirror of `destroy()`'s
    already-tested `removeListener` call) rather than by a new test.
- **`_startConnectivityWatch` could leak a `StreamSubscription` across two
  overlapping `initialize()` calls — caught by internal audit, 2026-08-16.**
  It's called `unawaited` from `initialize()`, which can itself finish (and
  reset its own re-entry guard) well before this method's up-to-20s
  connectivity-plugin-init await resolves. A second `initialize()` call
  starting before the first's watch resolved could overlap two invocations
  of this method; whichever resolved last silently overwrote
  `_connectivitySub`, leaking the other's subscription forever. Added a
  generation token (same pattern as `enableFillRateBaselineMonitor`'s fix
  above) so a call that loses the race bails out before ever subscribing,
  instead of clobbering (or being clobbered by) a newer one;
  `_stopConnectivityWatch` also bumps it so a still-pending start can't
  resurrect state after a stop. 2 new tests in
  `test/connectivity_refill_test.dart`.
- **Rewarded Interstitial (T89) was missing from the 5-minute connectivity
  backstop refill entirely — caught by internal audit, 2026-08-16.**
  `_retryRefillAds` only checked `appOpenSlot`/`interstitialSlot`/
  `rewardedSlot` — if a rewardedInterstitial's first load ever failed
  (no network / no-fill) and it was never shown, nothing would ever refill
  it again. Added the same idle/cooldown check for
  `rewardedInterstitialSlot`. 1 new assertion in
  `test/connectivity_refill_test.dart`. (Also updated 4 test fake adapters
  — `banner`/`mrec`/`native_ad_widget_test.dart`,
  `connectivity_resilience_test.dart` — to implement
  `rewardedInterstitialSlot`/`loadRewardedInterstitial` for real instead of
  relying on `noSuchMethod`, since this change made them reachable for the
  first time.)
- **`NativeAdWidget` on AppLovin leaked a live `BannerListenables` bundle
  per scrolled-past native ad in a `ListView` — caught by internal audit,
  2026-08-16.** `MaxNativeAdView`'s listener callbacks re-resolve
  `adapter.native(instanceKey)` on EVERY invocation (unlike
  `BannerAdWidget`/`MrecAdWidget`, which capture their listenables ONCE at
  load start), so a callback that arrived after `disposeNativeInstance(key)`
  already removed the map entry would silently `putIfAbsent` a brand new,
  never-disposed bundle for that permanently-gone (per-widget-instance) key
  — unbounded, one leak per native ad scrolled past (T73's in-feed use
  case). `AdMobAdapter` was unaffected (captures its listenables/slot
  locals once, doesn't re-resolve per callback). Fixed by tracking disposed
  keys in `AppLovinAdapter` and returning the shared already-disposed
  placeholder for any of them instead of auto-vivifying a fresh one. 1 new
  test in `test/applovin_adapter_test.dart`.
- **AppLovin's internal reload-after-show-failure could leave a slot stuck
  `loading` forever — caught by internal audit, 2026-08-16.** After a show
  fails/dismisses, `AppLovinAdapter` reloads by calling the native bridge
  DIRECTLY (`_bridge.loadAppOpenAd`/`loadInterstitial`/`loadRewardedAd`),
  bypassing `AdManager.loadX()` entirely — which is the only place a load
  watchdog otherwise gets armed (`_armLoadWatchdog`/T76). If AppLovin's
  native SDK never calls back for one of these specific reloads (the exact
  callback flakiness T76's watchdog exists to guard against), the slot had
  no recovery path and stayed `loading` forever — every later load call is
  a no-op while already loading. `AdMobAdapter` was unaffected (its load
  path only has one call site, always AdManager-orchestrated). Fixed by
  adding `AdSlot.armLoadWatchdog(label, timeout)` (the same logic
  `AdManager._armLoadWatchdog` already had, now shared) and arming it
  directly at all 6 adapter-internal reload sites (2 per ad type — one from
  `onAdDisplayFailedCallback`, one from `onAdHiddenCallback`). 3 new tests
  in `test/applovin_adapter_test.dart`.
- **`canShowInterstitial`/`canShowRewardedAd`/`canShowRewardedInterstitialAd`
  could permanently escalate a CTR-anomaly lockout just from being polled —
  caught by internal audit, 2026-08-16.** All 3 are read-only "should I
  enable my ad button" queries, but internally called
  `AdSafetyConfig.canShowFullscreenAd()` — the SAME function the actual show
  flow uses, which has a side effect: on a CTR anomaly it re-arms an
  escalating suspicious-pause window. Since a blocked ad never adds an
  impression, CTR can never recover on its own, so every poll after each
  pause window naturally expired re-triggered and escalated the exact same
  violation forever, from nothing but a UI-enable-state check (e.g. a
  "Watch Ad" button rebuilding on a timer) — zero new clicks required. Fixed
  by adding `AdSafetyConfig.canShowFullscreenAdPeek()` (identical checks,
  zero side effects — mirrors `dailyCapReached()`'s existing "safe to poll"
  contract) and switching all 3 query methods to use it;
  `AdManager`'s actual `showInterstitial`/`showRewardedAd`/
  `showRewardedInterstitialAd` show flows are unchanged (still use the
  side-effecting variant, correctly, since those represent a genuine show
  attempt). 2 new tests in `test/ad_safety_config_test.dart`.
- **[Security] VIP-key revocation list (CRL, T95) missing domain separation
  from VIP keys — caught by internal audit, 2026-08-16.** `verifySignedCrl`
  and `verifySignedVipKey` both verified an Ed25519 signature over the raw
  payload bytes with no format tag mixed in. A CRL's payload shape
  (`<issuedAtEpoch>|<kids>`) is identical to an AVP1 VIP key's shape
  (`<seconds>|<kid>`) — since a CRL is *designed* to be broadcast publicly
  (no secrecy requirement), anyone who observed a real signed CRL could
  relabel its prefix from `CRL1` to `AVP1` and redeem it as a real VIP key
  valid for however many "seconds" the CRL's `issuedAt` epoch happened to
  equal (tens of years). Fixed by signing/verifying `"CRL1|" + payload`
  instead of the payload alone for CRLs specifically — AVP1/AVP2 signing is
  deliberately left untouched (changing it would break every VIP key a host
  app has already minted and distributed; CRL had not shipped yet, so no
  migration is needed for it either). `tool/vip_crl_mint.dart` updated to
  match, and now also sanitizes `|` out of `--kids` like `vip_mint.dart`
  already does for `--kid`. 2 new regression tests in
  `test/vip_revocation_test.dart` lock in both directions (CRL→AVP1 and
  AVP1→CRL1 relabeling both now rejected).
- **`AdManager.enableFillRateBaselineMonitor` race leaked the loser of two
  overlapping calls — caught by internal audit, 2026-08-16.** The method
  awaits `AdPreferences.getInstance()` before constructing its monitor;
  calling it twice without awaiting the first left whichever call resolved
  first's instance orphaned (its `AdManager().events` subscription never
  cancelled, silently persisting to `SharedPreferences` forever) once the
  second call's assignment overwrote the field. Fixed with a generation
  token so only the call that resolves *last* wins, and any loser disposes
  its own instance instead of leaking it; `disableFillRateBaselineMonitor`
  and `destroy()` also bump the token so an in-flight `enable` call can't
  resurrect a monitor after either wins. 3 new tests in the new
  `test/ad_manager_fill_rate_baseline_test.dart`.
- **`AdManager`'s ATT doctor check (T98) had no upper bound on a hung
  platform channel — caught by internal audit, 2026-08-16.** `_selfCheckAtt`
  now wraps the read in `.timeout(const Duration(seconds: 5))` — every
  `runIntegrationSelfCheck` item is awaited sequentially, so a channel that
  never completes would otherwise hang the entire doctor run indefinitely
  instead of failing just this one item.

### Added

- **`NativeAdWidget` gate-recheck behavior locked in by regression tests
  (T100).** Verified: a consent revoke or later rebuild after the gate has
  already passed (but before the native ad finishes loading) does not
  retroactively cancel an in-flight load — consistent with
  `BannerAdWidget`/`MrecAdWidget`, which gate `canRequestAds` only at
  request time too, never reactively in `build()`. No code change; closed
  as "current behavior consistent + acceptable" with 2 new tests
  documenting it, per the ticket's own escape hatch.
- **`monetization_arbitrator_test.dart` gains `showRewardedInterstitialAd`
  veto coverage (T99).** The `onLowValueAdVetoed`-style hook the ticket asked
  for already existed (`ArbitratorNudgeEvent` on `AdManager().events`, wired
  at all 3 fullscreen show call sites since T89 added the rewarded-
  interstitial slot) — this closes the one real gap, a missing test for the
  rewarded-interstitial veto path, and documents `showRewardedInterstitialAd`
  explicitly in the README's arbitrator section.
- **Runtime integration doctor — `AdManager.runIntegrationSelfCheck` extended
  (T98).** Flagship: 3 new read-only checks — "Navigator key wired" (fails if
  `setNavigatorKey` was never called), "Route observer wired" (real evidence
  via `AdScreenRouteLogger`'s new navigation-event counter, not just "was it
  constructed"), and "ATT status readable (iOS)" (catches a broken
  `app_tracking_transparency` native embed without ever showing the real
  system prompt). Results now render directly in the built-in
  `DebugAdOverlay` via a manual "🩺 Run integration doctor" tap (not
  auto-run — the existing per-ad-type checks attempt real ad loads).
  Deliberately does NOT add SKAdNetwork/`Info.plist`/`AndroidManifest.xml`/
  pod-graph checks — those need new native platform-channel code (or, for
  the pod graph, aren't a runtime concept at all); see README for the exact
  reasoning.
- **`FillRateBaselineMonitor` — 7-day on-device fill-rate/eCPM regression
  detector (T97).** Flagship: `AdManager().enableFillRateBaselineMonitor(...)`
  compares THIS SESSION's fill rate and average revenue-per-ad
  (`AdRevenueEvent.valueMicros`) against a rolling 7-calendar-day baseline
  persisted locally — fully on-device, no backend, no shadow ad requests.
  Fires an alert once per slot the first time it regresses by at least
  `regressionThreshold` (default 20%) below the device's own baseline, needs
  `minSamples` on both sides before trusting a comparison, and excludes
  today's own in-progress day from its own baseline. Wired into
  `AdDiagnostics.fillRateRegressionBySlot` and rendered directly in the
  built-in `DebugAdOverlay`.
- **Cryptographically-signed compliance report export — `AdManager.exportSignedComplianceReport` (T96).**
  Flagship: wraps the existing `exportComplianceReport` bundle with an
  on-device Ed25519 signature (key minted once per install, persisted via
  `flutter_secure_storage`) so an edit made to the exported JSON AFTER export
  is detectable — tamper-evidence for an ad-network dispute appeal. Verify
  with `verifySignedComplianceReportJson` or the new standalone
  `tool/verify_compliance_report.dart` CLI. See README's "Cryptographically-
  signed compliance report export" for the precise (deliberately limited)
  threat model this does and doesn't cover.
- **VIP key revocation list (CRL) — `VipManager.refreshRevocationList` (T95).**
  Flagship: an offline-signed revocation list closing the SDK's known
  leaked-key gap (a redeemable-forever `kid` once shared) without a backend.
  Mint with `tool/vip_crl_mint.dart` using the SAME Ed25519 private key as
  `tool/vip_mint.dart` — no new key material. Host fetches the raw signed CRL
  via a new `VipRevocationProvider` interface (mirrors `RemoteAdSafetyProvider`'s
  shape) and calls `refreshRevocationList` periodically (once/day suggested);
  verified CRLs are cached to disk and re-verified on every read, and a
  revoked `kid` is rejected by `redeemSignedKey` going forward. Fails open on
  every error (no provider, fetch throw, `null`, bad signature, replayed/older
  CRL) — never blocks a legitimate redemption. Does not claw back a grant
  already made before the revocation landed. See README's "Revoking a leaked
  key (CRL)".
- **`AdReadinessSplashController` (T94).** Officializes the splash-screen
  orchestration boilerplate the README documented by hand — subscribe-
  before-init, the hard-cap timer, `markSplashActive`/`incrementSplashCount`/
  `markSplashInactive`, the re-entrant-splash guard, the buffered App Open
  ad with `bypassSafety: true`. One `start()`/`onReady` call; your splash
  screen still renders 100% its own UI. `dispose()` also clears the SDK's
  splash-active state if the widget is torn down before `onReady` ever fires.
  Also fixes two stale spots in the README found while writing this: a
  broken code fence that had been splitting the `_SplashScreenState` example
  in two (the "Per-platform ad-unit ids" section was accidentally inserted
  mid-class, leaving the rest unfenced), and outdated wording claiming
  `SimpleEventBus` never replays events to late subscribers — it does now
  (see the "F1" comment in `event_bus.dart`).
- **`AdSafetyParams.maxPerPlacementAdsPerDay` (T92).** Optional additional
  daily cap keyed by `AdPlacement`, checked alongside (never instead of) the
  existing global daily cap at show time. `null` by default — fully
  backward-compatible. Emits an `AdSkipEvent` with `reason: 'placement_cap'`
  when it blocks. Note: can't be set via a `const AdSafetyParams(...)` call
  (`AdPlacement`'s custom `==` isn't const-map-key-safe) — use a regular
  constructor call or `.copyWith(...)`.
- **`BannerAdWidget` collapse/expand animation (T91).** New
  `collapseAnimationDuration` param (default 250ms) wraps the banner in
  `AnimatedSize`, so no-fill/cooldown/VIP collapsing (and a real ad becoming
  ready) animates the height change instead of an abrupt
  `SizedBox.shrink()` layout jump. Pass `Duration.zero` for the old
  instant-jump behavior.
- **`AdManager().pickProviderCohort()` (T90).** Deterministic 50/50 AdMob vs
  AppLovin MAX A/B split, built on `experimentBucket`. Pick before building
  `AdConfig` (provider is fixed for the session). No new compliance-report
  plumbing for comparing cohorts — every event already carries `providerTag`.
- **`AdManager().experimentBucket(key, buckets: n)` (T93).** Deterministic,
  local-only A/B bucket assignment — hashes GAID (or a lazily-generated
  pseudonymous install id when GAID is empty/all-zeros) with `key`. No
  network, no new dependency; lighter-weight than `RemoteAdSafetyProvider`
  for hosts that just want to compare two local `AdSafetyParams`/arbitrator
  configs.
- **Rewarded Interstitial ad type — AdMob only (T89).**
  `AdMobConfig(rewardedInterstitialId: ...)` +
  `AdManager().loadRewardedInterstitialAd()` /
  `showRewardedInterstitialAd(onDone: (shown, earned) => ...)` /
  `canShowRewardedInterstitialAd()`. Google's format shown at a natural
  transition point rather than behind an explicit "watch ad" tap. AppLovin
  MAX has no equivalent ad unit type — that adapter's implementation is a
  documented no-op. No VIP-bypass-to-extend-VIP flow and no SSV params for
  this ad type, unlike `showRewardedAd` (see the doc comments for why).
- **`RemoteAdSafetyProvider` (T88).** Optional `AdManager().initialize(...,
  remoteSafetyProvider: ...)` hook so a host can adjust `AdSafetyParams`
  (daily/hourly caps, throttle, CTR threshold, ...) from a backend (Firebase
  Remote Config, a self-hosted API, ...) without an app store release.
  Provider-agnostic — no new dependency added. A slow (>5s), throwing, or
  `null`-returning provider falls back to the local `config.safety`
  unchanged; each override key is independently validated. Ad-unit-ID
  remote override was considered but is out of scope for this first pass —
  see the ticket for why.

### Removed

- `Backoff` (from `src/state/backoff.dart`) is no longer exported from the
  package barrel (T78). It was always an internal detail of
  `AdSlot.beginLoad()`'s default cooldown parameter — not referenced by
  any documented public API. If you constructed one directly, import
  `package:applovin_admob_sdk/src/state/backoff.dart` instead.

## [2.0.4] - 2026-08-09

Docs-only. No code changes. Prompted by an independent multi-agent audit
(Claude/Codex/Gemini, `doc/audit/audit_*.md`) flagging that the pubspec
description overclaimed "Offline VIP redeem".

### Changed

- pubspec `description` — "Offline VIP redeem" → "Offline-verified VIP
  codes". The Ed25519 signature check is fully offline, but
  `redeemSignedKey` has rejected the redeem *attempt* while offline since
  2.0.1 (deliberate anti-abuse gate) — the old wording implied the whole
  flow works offline, which it hasn't since that release.
- README — added a "Known limitation — redeem attempt requires
  connectivity" callout next to the signed-VIP-keys section, spelling out
  the same distinction.

## [2.0.3] - 2026-08-09

Docs-only. No code changes.

### Added

- `example/README.md` — a Quickstart section with the minimal
  `setNavigatorKey`/`navigatorObservers`/`requestUmpConsent`/`initialize`/
  `buildBanner` snippet, so the pub.dev "Example" tab is self-contained
  instead of only linking out to the package README.

## [2.0.2] - 2026-08-09

Docs-only. No code changes.

### Added

- `example/README.md` — an index of the 16 demo pages in `example/lib/main.dart`
  (one row per page: what it demonstrates), so the pub.dev "Example" tab has
  something to navigate besides a 2,500+ line raw file.

## [2.0.1] - 2026-08-09

Non-breaking bug fixes, cross-checked by three independent agents (Codex,
agy, a second Claude instance) with every finding verified against the
source. 698/698 tests pass; manually verified on a real Android device.

### Fixed

- **`AdManager.initialize()` bounded auto-retry.** A failed adapter init
  (bad ad unit ids, missing native config, transient SDK error) now retries
  up to 3 times with backoff (5s/15s/30s) before giving up for the session,
  instead of leaving the host permanently uninitialized until the next app
  launch or an explicit re-`initialize()` call.
- **`onComplete` now fires exactly once per host-initiated `initialize()`
  call.** Previously it could fire on every failed attempt in addition to
  the terminal outcome (up to 4 times across the retry budget), violating
  the 1.x callback contract of firing once with the final result.
- **Stale internal-retry flag could leak into a later legitimate call.** A
  retry timer firing while another `initialize()` call already held the
  busy guard left `_isInternalInitRetryCall` stuck `true`, causing the next
  real host-initiated call to be misclassified as an internal retry.
- **`VipManager` clock-rollback guard applied consistently.** The
  clock-rollback-resistant "now" getter (`_effectiveNow`, clamped against a
  persisted high-water mark) was already used for expiry/stacking
  calculations but was missed in `_refreshGraceNudge` and
  `_scheduleNextExpiry`, which still read the raw device clock — a backward
  clock jump could desync the grace-nudge and next-expiry timers from the
  rest of the VIP state.

### Changed

- **`VipManager.redeemSignedKey` now rejects redemption attempts while the
  device is offline**, returning `VipRedeemStatus.invalid` with a
  "no network connection" message, before running Ed25519 signature
  verification. Deliberate anti-abuse tightening — a host at 2.0.0 that
  allowed a signed key to be redeemed while offline will see those attempts
  rejected at 2.0.1. Ed25519 verification itself is still fully offline
  (no server call, no shared secret); only the redemption *attempt* now
  requires connectivity.

### Known limitations (unchanged, not new in this release)

- `VipManager.redeemVip`'s separate host-supplied-validator path is not
  gated by the offline check above — only `redeemSignedKey` is. Consumers
  using `redeemVip` with their own validator should apply their own
  connectivity check if desired.
- `AdManager.isConnected` optimistically returns `true` if read before the
  connectivity watcher is ready, or if the platform check throws — a small
  fail-open window on cold start.

## [2.0.0] - 2026-08-02

Breaking. Comes out of a full audit against seven production requirements
(`doc/audit/audit_claude_20260802.md`), cross-checked by three independent
agents, with every finding verified against the source.

### Breaking

- **`autoRequestUmpConsent` now defaults to `true`.** With the old defaults
  (`false`, plus `disableAppLovinCmpFlow: true` and
  `autoShowConsentDialog: true`) a host that changed nothing tripped the
  consent-coverage footgun, which hard-blocks every ad request in a release
  build — and the built-in dialog could not clear the block, because it applies
  consent directly to the providers and never routes through `setConsent()`.
  The result was a release that requested **zero ads, silently**: the `assert`
  next to the block is stripped in release, leaving one log line. Hosts that
  already call `requestUmpConsent()` themselves are detected and the automatic
  call skips, so UMP still runs exactly once.
- **`maxVipStackDuration` now defaults to 90 days** instead of `null`
  (uncapped). Pass `null` explicitly for the old behaviour, knowing the only
  remaining ceiling is the ~100-year sanity bound in the key parser.
- **Signed VIP keys default to a new `AVP2` format** carrying an expiry and an
  app binding inside the signed payload. `AVP1` keys already issued still
  verify; `tool/vip_mint.dart` mints AVP2 unless `--v1` is passed.
- New dependency: `package_info_plus`, used to read the bundle id that AVP2
  keys are checked against.

### Fixed

- **Interstitial and rewarded ads could stack on each other.**
  `showAppOpenAdOnResume` checked the other two fullscreen slots and the dialog
  stack, but `showInterstitial` and `showRewarded` each checked only
  themselves, so a call while another fullscreen ad was showing put one ad on
  top of another — an AdMob and AppLovin policy violation.
  `AdSafetyConfig.canShowFullscreenAd()` does not cover this: it is a
  time-based frequency gate, not a state mutex. All three paths now share one
  predicate.
- **Banner/MREC/native loads ignored the consent, VIP, cap and connectivity
  gate — in both adapters.** None of the ten load entry points consulted
  `canReload`, so a resume after a banner error (or any other caller) could
  fire an ad request while `canRequestAds` was false, while the user was VIP,
  or past the daily cap. Requesting an ad with `canRequestAds == false` is a
  UMP policy violation, and it was invisible from the UI because the widget
  layer hides banners for VIP users anyway. The `canReload` seam existed on
  `AdMobAdapter` but was dead code — only AppLovin ever called it.
- **A failed UMP attempt was never retried.** On reconnect the SDK refilled ad
  slots but not consent, so an EEA user whose first launch had no network never
  saw a consent form for the rest of the process. Now retried on the
  offline→online transition, and only when the previous attempt actually
  failed, so a user who already answered is not asked again.
- **A UMP status of `unknown` silently downgraded a stored consent.** `unknown`
  means UMP could not determine anything, not that the user refused, but it
  mapped to `hasUserConsent: false` and overwrote a choice the user had already
  made — visible in the logs as `load → consent=true` followed by
  `set → consent=false`. Inconclusive results now leave the persisted value
  alone. `required` still maps to `false`: there the form is genuinely needed
  and was not completed.
- **The consent SDK could abort `initialize()`.**
  `requestConsentInfoUpdate` is a callback API returning `void`; when the UMP
  channel is not registered it throws from a future nobody awaits, so the error
  escaped as an unhandled zone error that a `try`/`catch` around the call could
  not catch. Unreachable while the default was `false`; now contained.

### Documentation

- `maxVipStackDuration`'s docstring claimed the non-stacking path was never
  clamped. It was wrong — `VipManager.addVip` has clamped both paths since the
  single-entry cap was added. (The year-2099 legacy-GAID migration grant really
  is exempt, but because it constructs its `VipEntry` directly.)
- README now states plainly that VIP anti-bypass is Keychain-durable on iOS and
  weak on Android, where clearing app data resets both the trial and key reuse,
  and that offline keys cannot be revoked.
- The example's demo keypair is now marked as public knowledge and unsafe to
  ship.


## [1.2.4] - 2026-08-01

Metadata only — no code, API or behaviour change from 1.2.3.

### Changed
- Shortened the package `description` and all three `screenshots:`
  descriptions to under 160 characters. pub.dev enforces two different limits
  and neither is reported by `pub publish --dry-run`: the upload API rejects
  anything over 200 characters, while pana's scoring wants under 160 or it
  drops 10 points from "Provide a valid pubspec.yaml" and another 10 from
  "Package has an example and has no issues with screenshots". 1.2.3 uploaded
  fine at 187-197 characters but scored 130/160 for that reason.

## [1.2.3] - 2026-08-01

### Fixed
- `autoRequestUmpConsent` was never honoured during `initialize()` — a host
  that opted into automatic UMP now actually gets the consent request before
  ad requests start (R10-A).
- A COPPA flag set mid-session now hard-stops AppLovin ad requests instead of
  only applying to the next SDK init (R10-B).
- `_retryRefillAds()` returns immediately while the device is offline, instead
  of burning retry budget on requests that cannot succeed (R10-C).
- `ConnectionNotifierTools.initialize()` is bounded by a 20s timeout, so a
  hung connectivity plugin can no longer stall SDK init indefinitely (R10-D).
- `_footgunBlocked` leaked across re-init: one release-mode `initialize()`
  could permanently block ads for every later init in the same process. The
  same bug class then recurred for `_umpRequested` / `_consentExplicitlySet`,
  so `destroy()` and the re-init branch now share one `_resetGuardState()`
  instead of two hand-maintained reset lists.
- `applyDryRunReleaseGuard()`'s `isRelease` is threaded into the last two call
  sites (the `ad_manager.dart` consent-footgun guard and the `VipManager`
  constructor) that still fell back to raw `kReleaseMode` under `flutter test`.

### Changed
- Example app now mirrors the host's Android Auto Backup configuration, so the
  VIP-reinstall-replay path behaves the same in the example as in production.
- `SafeLogger`: `critical()` and `e(bypassLevel: true)` consolidated onto one
  internal `_e()`; `_shouldLog`'s `bypassLevel` branches merged.
- `VipManager`'s `isRelease` parameter is no longer `@visibleForTesting`
  (mirrors `ad_safety_config.dart` — the safety comes from
  `isActuallyRelease()`, not from a compile-time restriction).
- Added `repository` / `homepage` / `issue_tracker` / `topics` and an explicit
  `platforms: android, ios` to the pubspec; whole package reformatted with
  `dart format`. No API or runtime change.

### Documentation
- Explained why interstitial and rewarded ads intentionally have no watchdog,
  unlike App Open (R10-E).

## [1.2.2] - 2026-07-20

### Changed
- `SafeLogger`'s default log level is now `kDebugMode`-based (verbose in
  debug, warning-and-above in release) instead of always-verbose — a host
  that never calls `AdManager.setLogLevel()` no longer leaks raw GAID and
  other diagnostic detail into release logs by default.
- The consent-coverage footgun (AppLovin CMP disabled + `autoRequestUmpConsent`
  false + `requestUmpConsent()` never called before `initialize()`) now hard-
  blocks ad requests in release builds (`kReleaseMode`), not just a dev-time
  `assert()` (which strips in release and was previously log-only in
  production). The block clears automatically the moment `setConsent()` is
  called — directly by a host's own consent UI or internally by
  `requestUmpConsent()` — and triggers a refill of any ad slots held back
  while it was active.

### Fixed
- `NativeAdWidget`'s `MaxNativeAdView` listener callbacks now check
  `adapter.isInitialised` before writing to its `ValueNotifier`s or firing a
  click event, closing the same disposed-adapter race already guarded on the
  AppLovin banner/mrec views.

## [1.2.1] - 2026-07-19

### Added
- `VipManager.firstInstallGrantDueListenable` — fires once when the
  first-install VIP grace window is granted (previously silent/log-only),
  paired with `lastFirstInstallGrantDuration` and
  `acknowledgeFirstInstallGrant()`. Mirrors the existing
  `graceNudgeDueListenable` pattern. `AdManager.initialize()` now calls
  `notifyFirstInstallGrant()` right after granting the window.

## [1.2.0] - 2026-07-19

### Added
- `RevenuePanel` gained an optional `debugModeOverride` constructor param
  (test-only seam, `@visibleForTesting`) so the widget's `kDebugMode` gate
  can be exercised from `flutter test`.

### Changed
- `SimpleEventBus` now replays the last-fired event to a listener that
  subscribes *after* the event already fired, closing a gap where late
  subscribers silently missed init-completion signals. `clearAll()` (called
  from `AdManager.destroy()`) resets the replay buffer.
- `RevenuePanel` now fully gates on `kDebugMode` (or the override above): no
  event subscription and `SizedBox.shrink()` render in release builds,
  instead of only skipping the visual chrome.

### Fixed
- `ad_manager.dart` escalates the existing silent log warning for a
  misconfigured consent flow (AppLovin CMP disabled, `autoRequestUmpConsent`
  false, `requestUmpConsent()` never called before `initialize()`) to a
  dev-time `assert()` — asserts strip in release, so production behavior is
  unchanged, but dev/test builds now fail loudly instead of silently
  shipping with no consent flow.
- `requestUmpConsent()` now logs a warning if called before `requestAtt()`
  on iOS (ATT must run first per platform policy) — log-only, non-blocking.

### Docs
- Clarified in the README: the AdMob-per-request-tag vs. AppLovin-full-abort
  COPPA asymmetry is intentional (each provider's native API surface
  differs), not an inconsistency; `enableFillRateMonitor`/`enableArbitrator`
  are production-safe opt-in tools with no `kDebugMode` distinction; UMP→
  AppLovin consent sync is boolean-only by design since AppLovin MAX SDK
  12.0.0+ auto-reads the IAB TC-String directly; pointers to the existing
  CCPA `CupertinoSwitch` pattern and `consent_dialog.dart`'s binary-only
  rationale for hosts that need more UI; noted the Android VIP-key
  reinstall-replay limitation.
- `example/ios/Runner/Info.plist` synced from 50 → 152 `SKAdNetworkItems`
  entries to match the host app.

## [1.1.1] - 2026-07-18

### Changed
- Bumped `confetti` `^0.7.0` → `^0.8.0` and `connection_notifier` `^2.0.1` →
  `^4.1.0` (dependency freshness, closes Pub Points "up-to-date dependencies"
  gap). No API surface used by this package (`ConnectionNotifierTools
  .initialize()`/`.isConnected`/`.onStatusChange`) changed across
  `connection_notifier`'s 3.x/4.x majors — those breaking changes only
  affected its widget/UI layer, which this SDK doesn't use.


Older entries (1.1.0 and earlier) moved to [CHANGELOG_ARCHIVE.md](CHANGELOG_ARCHIVE.md)
because pub.dev rejects a CHANGELOG.md over 256 KB.
