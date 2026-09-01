# Independent Audit Round 27 — Antigravity (agy)

**Date:** 2026-09-01  
**Audited Tree:** `HEAD` (`d25e43d`), SDK Version 2.9.4 (pub.dev sync confirmed)  
**Baseline:** `packages/ad_sdk/doc/audit/audit_round26_consolidated.md`  
**Reviewer:** `agy` (Gemini 3.7 Flash) — Independent Reviewer (Round 27)  
**Scope:** Monorepo `packages/ad_sdk/`, full git diff `de9c40a..HEAD`, CHANGELOG entries 2.4.0–2.9.4 (tickets T101–T130), spot-check of high-risk migrations, and verification of the 7 core product requirements.

---

## 1. Executive Summary & Production Readiness Verdict

- **Ready for production use in a real consuming app:** **YES WITH CONDITIONS**
- **Overall Quality Score:** **8.5 / 10**
- **Test Suite Health:** `flutter analyze` is **100% clean (0 issues)**; package test suite has **1,476 / 1,476 passing tests** (`flutter test`).
- **High-Risk Ticket Health:** The T101–T130 enhancement/fix batch is technically sound, highly disciplined, and maintains the stringent gate invariants established over the prior 26 audit rounds.
- **Conditions to Satisfy:**
  1. Confirm manual credential rotation/revocation for the leaked AppLovin SDK key and 8 ad-unit IDs on the AppLovin dashboard (unverifiable via code review).
  2. Keep repository private until credential rotation is confirmed.
  3. Resolve the 3 open MAJOR findings (1 new unbounded flush in T102, 2 deferred from Round 26) prior to high-concurrency VIP redemptions or rapid destroy/init cycles.

---

## 2. Status of Previous Findings (Round 26 Baseline Check)

### 2.1. BLOCKER: Historical AppLovin Secret Leak in Git History
- **Location:** Introduced in `11d7421` (`packages/ad_sdk/doc/archive/AD.MD`), deleted from working tree at `0f503ba`.
- **Working Tree Verification:** Confirmed absent from current `HEAD` working tree and pub.dev package artifact.
- **Git Log Scan (`de9c40a..HEAD`):** Grepped all additions since Round 26 (`ca-app-pub-`, SDK keys, AppLovin tokens). Zero new production credentials leaked; only standard Google test ad units (`3940256099942544/...`) and explicit placeholder strings are present.
- **Status:** **OPEN BLOCKER (Risk Accepted by User)** — Repository remains private (`royt93/FlutterBase2026`), but manual rotation on the AppLovin dashboard remains unconfirmed outside source control.

### 2.2. Deferred MAJOR #1: Unlocked Read-Modify-Write in iOS Redeemed-Key Ledger
- **Location:** [`packages/ad_sdk/lib/src/vip/_redeemed_key_ledger.dart:66-78`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/vip/_redeemed_key_ledger.dart#L66-L78)
- **Description:** `markRedeemed(String kid)` reads Keychain storage asynchronously (`_secure.read`), modifies the `Set<String>`, and writes back (`_secure.write`) without a mutex or chain. Concurrent redemptions on iOS can overwrite each other and drop a `kid` from the durable ledger.
- **Status:** **STILL OPEN** (explicitly deferred by user to a future release).

### 2.3. Deferred MAJOR #2: Missing `_discardIfDisposed` Guard in AdMob Fullscreen `onFailed`
- **Location:** [`packages/ad_sdk/lib/src/adapters/admob_adapter.dart:913-924`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/adapters/admob_adapter.dart#L913-L924) (AppOpen), [`:1215-1226`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/adapters/admob_adapter.dart#L1215-L1226) (Interstitial), [`:1399-1410`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/adapters/admob_adapter.dart#L1399-L1410) (Rewarded), [`:1614-1625`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/adapters/admob_adapter.dart#L1614-L1625) (RewardedInterstitial).
- **Description:** The `onLoaded` handlers check `if (_discardIfDisposed(ad, ...)) return;`, but the `onFailed` branches do not check `_fullscreenDisposed`. Furthermore, `AdMobAdapter.dispose()` does not null `eventSink`. A late load failure from an in-flight request after adapter disposal will mutate a disposed `AdSlot` and emit `AdLoadEvent(success: false)` through the retained sink.
- **Status:** **STILL OPEN** (explicitly deferred by user to a future release).

---

## 3. Audit of Ticket Batch T101–T130 & New Findings

### 3.1. High-Risk Spot Checks

#### A. T102: `AdManager.destroy()` Awaits Event Log Flush (`ad_manager.dart:5406-5418`)
- **Race Condition Verification:** **RESOLVED.** Changing `unawaited(_eventLog?.flush())` to `await _eventLog?.flush()` in [`lib/src/core/ad_manager.dart:5416`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/core/ad_manager.dart#L5416) ensures that queued debounced compliance events are fully committed to disk before `_eventLog` is set to `null` and before any subsequent `initialize()` constructs a new `AdEventLog` instance from disk. Mutation-verified in `test/destroy_awaits_event_log_flush_test.dart`.
- **NEW MAJOR Finding:** **Teardown Availability Dependency on Unbounded Platform Storage Write.**
  - **Location:** [`packages/ad_sdk/lib/src/core/ad_manager.dart:5416`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/core/ad_manager.dart#L5416)
  - **Issue:** `_eventLog?.flush()` is awaited without a `.timeout(...)`. In contrast, adjacent teardown paths (such as `_eventsController.close()` at line 5309 [2s timeout] and fullscreen show completion at line 5275 [5s timeout]) explicitly bound asynchronous waits. If `SharedPreferences.setString` platform-channel communication ever hangs or stalls, `destroy()` will hang indefinitely, permanently holding `_destroyInFlight` and deadlocking all subsequent `initialize()` callers.
  - **Severity:** **MAJOR** (Availability / Teardown deadlock risk).
  - **Recommendation:** Wrap `await _eventLog?.flush().timeout(const Duration(seconds: 2))` with a fallback log and continue teardown.

#### B. T115: `AsyncEpoch` Migration into `AdLoadingDialog` (`ad_loading_dialog.dart:55, 70, 147, 197-220`)
- **Parity Verification:** **PASS.** `AsyncEpoch` cleanly replaces the static `_generation` counter in [`lib/src/widget/ad_loading_dialog.dart`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/widget/ad_loading_dialog.dart#L55).
- `_epoch.invalidate()` is called on `resetState()`, `dismiss()`, and `showAdBuffer()`.
- `_epoch.isCurrent(myGen)` guarantees that any timer waking up after a dialog was dismissed or reset will skip route popping and invoke `onComplete()` safely without stranding routes.
- The static `_epoch` is intentionally not disposed, preserving lifecycle reusability across SDK sessions.

#### C. Batch T101–T130 Verification Summary
1. **T101 (Fill-rate race):** `AdPreferences.recordFillRateBaselineSample` chained via `_fillRateBaselineChain` ([`ad_preferences.dart:257`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/utils/ad_preferences.dart#L257)). Verified clean.
2. **T103 (Splash ValueNotifier):** Replaced with plain `bool` guard ([`splash_screen.dart:28`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/example/lib/bootstrap/splash_screen.dart#L28)). Clean.
3. **T104 (Native tombstones):** Bounded `_disposedNativeKeys` `LinkedHashSet` to max 200 ([`applovin_adapter.dart:184`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/adapters/applovin_adapter.dart#L184)). Clean.
4. **T105 (Click after dispose):** AdMob inline identity check ([`admob_adapter.dart:340, 420, 500`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/adapters/admob_adapter.dart#L340)); AppLovin nulled `eventSink` ([`applovin_adapter.dart:845`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/adapters/applovin_adapter.dart#L845)). Clean.
5. **T106 (`bootstrap`):** Sequences ATT → UMP → `initialize` in [`ad_bootstrap.dart:89-127`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/core/ad_bootstrap.dart#L89-L127). Clean.
6. **T107 & 2.9.1 (Placement forwarding):** Widget constructors and `AdScreenState` forward `placement` correctly ([`ad_screen.dart:32-60`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/core/ad_screen.dart#L32-L60)). Clean.
7. **T108 (`AdRetryPolicy`):** Jitter + custom error code filtering + reconnect clear ([`ad_retry_policy.dart:15-74`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/state/ad_retry_policy.dart#L15-L74), [`ad_slot.dart:160-191`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/state/ad_slot.dart#L160-L191)). Clean.
8. **T109 (`stateSnapshot`):** Reactive `ValueNotifier<AdSdkStateSnapshot>` coalesced on microtask ([`ad_manager.dart:1522-1547`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/core/ad_manager.dart#L1522-L1547)). Clean.
9. **T110 & 2.9.2 (`ComplianceReport.redacted`):** Explicit key removal rather than nulling ([`compliance_report.dart:141-149`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/compliance/compliance_report.dart#L141-L149)). Clean.
10. **T111 (`refreshRemoteSafetyParams`):** Safe on-demand refresh with 5s timeout and post-await teardown check ([`ad_manager.dart:3709-3736`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/core/ad_manager.dart#L3709-L3736)). Clean.
11. **T112 (`MonetizationArbitrator` veto):** Fill-rate regression alert integration ([`monetization_arbitrator.dart:130-150`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/monetization/monetization_arbitrator.dart#L130-L150)). Clean.
12. **T113 (`maxPerPlacementAdsPerDayById`):** String-keyed const parameter support ([`ad_safety_config.dart:128, 480-495`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/core/ad_safety_config.dart#L128)). Clean.
13. **T118 (`FakeAdProviderAdapter`):** Full offline mock adapter for tests/previews ([`fake_adapter.dart:1-410`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/adapters/fake_adapter.dart#L1-L410)). Clean.
14. **T119 (`explainLastSkip`):** Diagnostic explanation read-only API ([`ad_manager.dart:650-675`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/core/ad_manager.dart#L650-L675)). Clean.
15. **T120 (`simulateConsentOutcome`):** Pure preview sharing decision function with provider apply ([`ad_consent.dart:125-190`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/core/ad_consent.dart#L125-L190)). Clean.
16. **T121 (`safetyRampSchedule`):** Local install-age ramp schedule evaluated pre-init ([`ad_manager.dart:2440-2458`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/core/ad_manager.dart#L2440-L2458)). Clean.
17. **T122 (`WaterfallTuner`):** Opt-in rolling fill-rate × eCPM scorer with clean StreamSubscription disposal ([`waterfall_tuner.dart:50-132`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/monetization/waterfall_tuner.dart#L50-L132)). Clean.
18. **T123 (`JourneyPrefetcher`):** Opt-in journey prefetcher respecting `maxHoldDuration` with clean StreamSubscription disposal ([`journey_prefetcher.dart:29-102`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/monetization/journey_prefetcher.dart#L29-L102)). Clean.
19. **T124 (`AdaptiveAdSurface`):** Responsive width-based banner/MREC switching with debouncing and clean timer disposal ([`adaptive_ad_surface.dart:37-118`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/widget/adaptive_ad_surface.dart#L37-L118)). Clean.
20. **T125 (`IncidentRecorder` / `IncidentBundle`):** Bounded ring buffer (200 entries) with Ed25519 signing ([`incident_recorder.dart:66-180`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/compliance/incident_recorder.dart#L66-L180)). Clean.
21. **T126 (Creative Fatigue Guard):** `maxSameNetworkShowsPerWindow` / `networkFatigueWindowMs` ([`ad_safety_config.dart:503-520`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/core/ad_safety_config.dart#L503-L520)). Clean.
22. **T127 (`SelfHealingObserver`):** Observe-only prototype with clean StreamSubscription & tuner disposal ([`self_healing_observer.dart:21-57`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/monetization/self_healing_observer.dart#L21-L57)). Clean.
23. **T128 (`BypassAuditTrail`):** In-memory ring buffer (200 entries) recording and signing safety/VIP bypasses ([`bypass_audit_trail.dart:46-100`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/compliance/bypass_audit_trail.dart#L46-L100)). Clean.
24. **T129 (`MonetizationDigitalTwin`):** Deterministic read-only replay over `AdEventLog` history ([`digital_twin.dart:82-189`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/monetization/digital_twin.dart#L82-L189)). Clean.
25. **T130 (VIP Device Transfer):** Documented existing per-device validation mechanism in README without introducing forgeable on-device signing tokens ([`T130-...md`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/doc/task/done/T130-flagship-vip-device-transfer-token.md)). Clean.

### 3.2. Additional New Findings

- **NEW MINOR #1: Example Test Assertion Out of Sync**
  - **Location:** [`packages/ad_sdk/example/test/home_page_test.dart:24`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/example/test/home_page_test.dart#L24)
  - **Issue:** When version 2.9.1 added the `Adaptive surface (T124)` DemoTile to `HomePage` ([`example/lib/shared/home_page.dart:61`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/example/lib/shared/home_page.dart#L61)), the total tile count grew from 17 to 18. The widget test still asserts `findsNWidgets(17)`, causing `flutter test` in `example/` to fail on that single test.
  - **Severity:** **MINOR / NIT** (Test-only flaw in example harness).

---

## 4. Verification of the 7 Product Requirements

| # | Requirement | Status | Detailed Evidence & Line Citations |
|---|---|---|---|
| **1** | **Dual Provider (AppLovin MAX + AdMob) on Android & iOS** | **PASS** | `AdMobAdapter` ([`admob_adapter.dart:100-2400`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/adapters/admob_adapter.dart#L100-L2400)) and `AppLovinAdapter` ([`applovin_adapter.dart:90-1400`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/adapters/applovin_adapter.dart#L90-L1400)) implement common `AdProviderAdapter` interface ([`ad_provider_adapter.dart:35-180`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/core/ad_provider_adapter.dart#L35-L180)). Both cover all ad formats across iOS & Android, verified via shared contract test suite ([`test/adapter_contract_test.dart:1-269`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/test/adapter_contract_test.dart#L1-L269)). |
| **2** | **Online & Offline Resilience at Init & Mid-Session** | **PASS-WITH-CAVEAT** | Offline connectivity monitoring with 800ms debounce ([`ad_manager.dart:7315-7385`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/core/ad_manager.dart#L7315-L7385)), UMP fail-closed/open error handling, reconnect backstop retry, and slot cooldown clearing ([`ad_slot.dart:187-191`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/state/ad_slot.dart#L187-L191)). *Caveat:* T102 unbounded `_eventLog?.flush()` in `destroy()` can deadlock teardown if platform storage fails. |
| **3** | **4 Ad Types: Policy-Correct Lifecycle, No Leaks** | **PASS-WITH-CAVEAT** | Explicit `dispose()` and `cancel()` for all controllers/timers/streams across `AdManager` ([`ad_manager.dart:5330-5425`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/core/ad_manager.dart#L5330-L5425)), `AdMobAdapter` ([`admob_adapter.dart:556-692`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/adapters/admob_adapter.dart#L556-L692)), `AppLovinAdapter` ([`applovin_adapter.dart:780-845`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/adapters/applovin_adapter.dart#L780-L845)), `AdLoadingDialog` ([`ad_loading_dialog.dart:278-283`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/widget/ad_loading_dialog.dart#L278-L283)), `AdaptiveAdSurface` ([`adaptive_ad_surface.dart:90-93`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/widget/adaptive_ad_surface.dart#L90-L93)), and `TopToast` ([`top_toast.dart:60-75`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/widget/top_toast.dart#L60-L75)). *Caveat:* Deferred MAJOR #2 (missing `_discardIfDisposed` in AdMob `onFailed`) remains open. |
| **4** | **Trial Mode ~1 Day (First-Install Grace) & Anti-Bypass** | **PASS** | iOS Keychain persistence survives reinstall (`_first_install_guard.dart:8-25`), Android auto-backup support documented (`_first_install_guard.dart:27-56`), monotonic clock rollback high-water protection ([`_clock_rollback_guard.dart:15-80`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/vip/_clock_rollback_guard.dart#L15-L80)), and dual-clock expired grant purge logic ([`vip_manager.dart:180-240`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/vip/vip_manager.dart#L180-L240)). |
| **5** | **VIP Activation by Code (No Server / Backend)** | **PASS-WITH-CAVEAT** | Cryptographic offline verification using Ed25519 signatures on `AVP2` tokens ([`signed_vip_key.dart:86-180`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/vip/signed_vip_key.dart#L86-L180)), maintainer-signed CRL with latching `issuedAt` ([`_vip_revocation_list.dart:1-120`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/vip/_vip_revocation_list.dart#L1-L120)), and transitive grant tracking. *Caveat:* Deferred MAJOR #1 (unlocked Keychain RMW in `RedeemedKeyLedger`) remains open. |
| **6** | **Consent for Every Country (GDPR, COPPA, CCPA, ATT)** | **PASS** | `bootstrap()` sequences ATT → UMP → init ([`ad_bootstrap.dart:89-127`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/core/ad_bootstrap.dart#L89-L127)). Privacy options form entry points ([`ad_manager.dart:3900-3950`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/core/ad_manager.dart#L3900-L3950)). Stale ad discard upon consent narrowing ([`ad_slot.dart:125-148`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/state/ad_slot.dart#L125-L148)). Consent tightening gate `_consentProviderApplyInFlight` ([`ad_manager.dart:3830-3850`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/core/ad_manager.dart#L3830-L3850)). COPPA child flag re-checked during init ([`ad_manager.dart:2510-2530`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/core/ad_manager.dart#L2510-L2530)). CCPA `IABUSPrivacy_String` auto-sync ([`iab_storage.dart:1-100`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/core/iab_storage.dart#L1-L100)). |
| **7** | **AdMob & AppLovin Policy Compliance** | **PASS-WITH-CAVEAT** | 12 anti-fraud/safety enforcement layers: App Open prohibited on bare splash (`_splashBudgetTimer` / `markSplashActive`), inline ad blanking during fullscreen ([`admob_adapter.dart:225`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/adapters/admob_adapter.dart#L225)), interstitial frequency caps & minimum session age ([`ad_safety_config.dart:522-540`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/core/ad_safety_config.dart#L522-L540)), rewarded payout gated exclusively on native completion ([`admob_adapter.dart:1467-1548`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/adapters/admob_adapter.dart#L1467-L1548); [`applovin_adapter.dart:1579-1626`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/adapters/applovin_adapter.dart#L1579-L1626)), rewarded interstitial disclosure screen ([`ad_screen.dart:120-150`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/core/ad_screen.dart#L120-L150)), and bypass audit trail ([`bypass_audit_trail.dart:46-100`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/compliance/bypass_audit_trail.dart#L46-L100)). *Caveat:* Blocked by historical credential leak on git history until dashboard rotation is confirmed. |

---

## 5. Prioritized Action List

1. **Add Timeout to `_eventLog?.flush()` in `destroy()` (NEW MAJOR):** In [`packages/ad_sdk/lib/src/core/ad_manager.dart:5416`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/core/ad_manager.dart#L5416), wrap `await _eventLog?.flush()` with `.timeout(const Duration(seconds: 2))` to prevent platform-channel storage delays from permanently blocking `destroy()` and serialized future `initialize()` calls.
2. **Add Mutex / Chain to `RedeemedKeyLedger.markRedeemed()` (Deferred MAJOR #1):** In [`packages/ad_sdk/lib/src/vip/_redeemed_key_ledger.dart:66-78`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/vip/_redeemed_key_ledger.dart#L66-L78), serialize async Keychain operations via a `Future` chain or lock to prevent concurrent redemption write collisions on iOS.
3. **Add Disposed Check to AdMob `onFailed` Callbacks & Clear Sink (Deferred MAJOR #2):** In [`packages/ad_sdk/lib/src/adapters/admob_adapter.dart`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/adapters/admob_adapter.dart), guard the `onFailed` branches of `loadAppOpen`, `loadInterstitial`, `loadRewarded`, and `loadRewardedInterstitial` with `if (_fullscreenDisposed) return;`, and null `eventSink` in `dispose()`.
4. **Fix Example Widget Test Count (NEW MINOR #1):** In [`packages/ad_sdk/example/test/home_page_test.dart:24`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/example/test/home_page_test.dart#L24), update `findsNWidgets(17)` to `findsNWidgets(18)` to reflect the addition of the Adaptive Surface demo tile.
5. **Confirm AppLovin Dashboard Credential Rotation:** Manually verify on the AppLovin dashboard that the SDK key and 8 ad-unit IDs exposed in commit `11d7421` have been rotated and revoked before making the repository public or granting broader developer access.
6. **Maintain Documentation Integrity:** Ensure any companion integration prompts (such as `AD_PROMPT_FLUTTER.MD`) include clear integration instructions for MREC, Native, and Rewarded Interstitial formats, as well as COPPA pre-init restrictions.
