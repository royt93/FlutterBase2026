# Audit Round 46 — Security & Correctness Assessment

**Package:** `applovin_admob_sdk` (`packages/ad_sdk`)  
**Version Audited:** `3.0.0` (with local unreleased round-45 fixes applied)  
**Date:** 2026-09-19  
**Auditor:** Independent Adversarial Security & Correctness Auditor (Gemini 3.7 Flash)  
**Scope:** Verification of round-45 fixes + 8-area adversarial audit (Dual-provider correctness, Offline resilience, Ad lifecycle & memory safety, 1-day trial tamper resistance, Offline VIP Ed25519 crypto & replay, Multi-jurisdiction consent, Ad policy compliance, Memory leaks).

---

## Executive Summary

The round-46 audit focused on rigorous, adversarial verification of the 4 fixes applied following round 45 (R45-01 MAJOR, R45-02 MINOR, R45-03 MINOR, R45-04 MINOR) and a full fresh audit across all 8 core architecture and compliance domains.

### Explicit Finding Counts
- **NEW BLOCKER Findings:** 0
- **NEW MAJOR Findings:** 0
- **NEW MINOR / NIT Findings:** 2 (R46-01 Banner/MREC click callback stale check symmetry; R46-02 CLI subprocess test stdout parsing in `vip_cli_security_test.dart`)

### Verification of Round-45 Fixes
All 4 round-45 fixes were traced through every calling path and verified **CORRECT and COMPLETE**:
1. **R45-01 (AppLovin pre-init TCF vendor consent override):** VERIFIED CORRECT & COMPLETE.
2. **R45-02 (Native ad click callback after dispose):** VERIFIED CORRECT & COMPLETE.
3. **R45-03 (Unsupported provider skip event for Rewarded Interstitial):** VERIFIED CORRECT & COMPLETE.
4. **R45-04 (Google test ad unit ID hard-block in release builds):** VERIFIED CORRECT & COMPLETE.

### Publish Gate Verdict
**CLEAN (PASS)** — Zero new BLOCKER or MAJOR findings were identified. The repository satisfies the project's explicit publish gate condition (two consecutive independent audit rounds with zero new MAJOR/BLOCKER findings) for release to `pub.dev`.

---

## Part 1: Verification of Round-45 Fixes

### 1. AppLovin Pre-Init TCF Consent Guard (`applovin_adapter.dart`)
- **Fix Verification:**
  In [`lib/src/adapters/applovin_adapter.dart`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit46_gemini/packages/ad_sdk/lib/src/adapters/applovin_adapter.dart#L834-L853), `initialize()` now reads [`IabStorage.read(IabStorage.keyTcfString)`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit46_gemini/packages/ad_sdk/lib/src/core/iab_storage.dart#L89) prior to initializing the native AppLovin bridge. If a non-empty IAB TC string exists on the device, `_bridge.setHasUserConsent(...)` is skipped, ensuring the native AppLovin MAX SDK reads the vendor-specific consent string directly from shared storage rather than having a coarse boolean override forced upon it.
- **Trace of All Other Call Sites:**
  - *Post-init / Mid-session:* [`applyConsentToProviders()`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit46_gemini/packages/ad_sdk/lib/src/core/ad_consent.dart#L164-L168) in `lib/src/core/ad_consent.dart` implements the exact same check against `IabStorage.keyTcfString`.
  - *COPPA flip / Re-init:* When COPPA status flips in [`AdManager.setConsent`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit46_gemini/packages/ad_sdk/lib/src/core/ad_manager.dart#L4840-L4860), it routes through `applyConsentToProviders()` and then triggers re-initialization via `AppLovinAdapter.initialize()`, both of which are properly guarded.
  - *CCPA `setDoNotSell`:* Remains unconditional in both pre-init and post-init flows as expected, since CCPA/CPRA has no TCF vendor equivalent.
  - *Comprehensive Grep:* No other call sites invoking `AppLovinMAX.setHasUserConsent` or `_bridge.setHasUserConsent` exist in the codebase.
- **Verdict:** **Verified Correct and Complete.**

---

### 2. Native Ad Click Callback After Dispose (`native_ad_widget.dart`)
- **Fix Verification:**
  In [`lib/src/widget/native_ad_widget.dart`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit46_gemini/packages/ad_sdk/lib/src/widget/native_ad_widget.dart#L639-L642), `onAdClickedCallback` now performs:
  ```dart
  if (adapter is AppLovinAdapter &&
      adapter.isNativeInstanceDisposed(instanceKey)) {
    return;
  }
  ```
  This prevents a race condition where a native click event delivered after widget disposal could modify shared state (`AdSafetyConfig.recordAdClick()` and `adapter.eventSink`).
- **Trace of Other Callbacks & Widgets:**
  - `NativeAdWidget.onAdLoadedCallback` & `onAdLoadFailedCallback`: These callbacks update `adapter.native(instanceKey)`, which safely resolves to `_disposedNativeListenables` if disposed, with errors caught by internal `try/catch` blocks.
  - `BannerAdWidget` & `MrecAdWidget`:
    - `onAdRevenuePaidCallback`: Protected by `isStaleAppLovinCallback(AdManager().bannerAdViewId(ownerKey).value, adViewId)`.
    - `onAdClickedCallback`: Lacks `isStaleAppLovinCallback` (noted as MINOR finding R46-01 below).
  - Fullscreen formats in `AppLovinAdapter`: `onAdHiddenCallback` guards against late callbacks via `_isStaleAd` comparison against creative ID.
- **Verdict:** **Verified Correct and Complete** for `NativeAdWidget`.

---

### 3. Unsupported Provider Skip Event on Rewarded Interstitial (`ad_manager.dart`)
- **Fix Verification:**
  In [`lib/src/core/ad_manager.dart`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit46_gemini/packages/ad_sdk/lib/src/core/ad_manager.dart#L8036-L8042) and [lines 8099-8106](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit46_gemini/packages/ad_sdk/lib/src/core/ad_manager.dart#L8099-L8106), `loadRewardedInterstitialAd` and `showRewardedInterstitialAd` check `if (ad is AppLovinAdapter)` and emit:
  ```dart
  _emitSkip(AdSlotType.rewardedInterstitial, 'load' / 'show', 'unsupported_provider');
  ```
- **Verification for AdMob:**
  On AdMob configurations, `_adapter` is an instance of `AdMobAdapter` (not `AppLovinAdapter`). The type check evaluates to `false`, allowing standard Google Mobile Ads `RewardedInterstitialAd` loading, showing, and event firing.
- **Verdict:** **Verified Correct and Complete.**

---

### 4. Release Build Hard-Block on Google Test AdMob Ad Unit IDs (`ad_manager.dart`)
- **Fix Verification:**
  In [`lib/src/core/ad_manager.dart`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit46_gemini/packages/ad_sdk/lib/src/core/ad_manager.dart#L2378-L2382) and [line 3234](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit46_gemini/packages/ad_sdk/lib/src/core/ad_manager.dart#L3234), `_applyTestIdFootgunGuard` invokes `usesGoogleTestAdUnitIds(config)`. If a release build contains any AdMob unit ID matching the Google test prefix `ca-app-pub-3940256099942544`, `_footgunBlocked` is set to `true`, preventing `$0`-earning test ad inventory in release builds.
- **Verification of Legitimacy & Other Footguns:**
  - *Legitimate Builds:* Production configurations with real publisher IDs do not match the test prefix and evaluate to `false` (unblocked).
  - *`firstInstallVipGrace`:* Disabling the first-install trial in release builds is an intentional publisher product option; remaining as warning-only is deliberate and correct.
  - *`umpDebugGeography`:* Test geography configurations remain warning-only as UMP still collects valid regional consent.
- **Verdict:** **Verified Correct and Complete.**

---

## Part 2: Fresh 8-Area Adversarial Audit

### Area 1: Dual Provider Correctness (AdMob + AppLovin, Android + iOS)
- **Parity & Formats:**
  - **Banner / MREC:** Route-aware pause and resume, adaptive sizing, and auto-refresh tickers behave consistently across AdMob and AppLovin.
  - **Fullscreen (App Open, Interstitial, Rewarded):** All formats dispatch corresponding `AdLoadEvent`, `AdImpressionEvent`, `AdRevenueEvent`, and `AdDismissEvent`.
  - **Rewarded Interstitial:** AdMob supports native `RewardedInterstitialAd`; AppLovin explicitly and cleanly emits `AdSkipEvent(reason: 'unsupported_provider')`.
  - **Server-Side Verification (SSV):** `customData` and `userId` are correctly passed to GMA `ServerSideVerificationOptions` and `AppLovinMAX.showRewardedAd(customData: ...)`.
- **Status:** **PASS** (Zero issues found).

---

### Area 2: Offline & No-Network Resilience
- **Initialization:** Network checks via `ConnectionNotifierTools.isConnected` are guarded with safe fallbacks and do not block `initialize()`.
- **Request Gating:** Ad load requests check `!isConnected` and cleanly emit `AdSkipEvent(..., 'no_network')` without crashing.
- **Reconnect Handling:** `_retryRefillAds()` triggers when network status shifts from offline to online, refilling eligible slots.
- **Status:** **PASS** (Zero issues found).

---

### Area 3: Ad Type Lifecycle Correctness & State Safety
- **Fullscreen Mutex:** [`_fullscreenBusyReason`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit46_gemini/packages/ad_sdk/lib/src/core/ad_manager.dart#L2109-L2159) ensures mutually exclusive presentation across App Open, Interstitial, Rewarded, Rewarded Interstitial, active loading dialogs, UMP consent dialogs, custom overlays, and route popup depths.
- **App Open Overlays:** Inline surfaces (Banner, MREC, Native) are blanked via `_fullscreenOverInline` during fullscreen ad presentation and restored on dismissal.
- **Status:** **PASS** (Zero issues found).

---

### Area 4: Trial Mode (1-Day) Tamper Resistance
- **Anti-Rollback Mechanism:** [`_effectiveNow()`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit46_gemini/packages/ad_sdk/lib/src/vip/vip_manager.dart#L374-L390) clamps against the highest recorded timestamp in persistent storage and cross-checks with monotonic `_sessionClockStopwatch` to resist in-session clock manipulation.
- **Start-Time Guard:** [`_isLive`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit46_gemini/packages/ad_sdk/lib/src/vip/vip_manager.dart#L820-L860) checks both the high-water mark and real clock to prevent future-dated grant abuse.
- **Platform Storage:** Documented and accepted trade-off between iOS Keychain persistence and Android Auto Backup/SharedPreferences.
- **Status:** **PASS** (Zero issues found).

---

### Area 5: Offline/No-Backend VIP Code Activation
- **Cryptographic Security:** Ed25519 offline verification for `AVP1` and `AVP2` codes via `cryptography` package. Private key never ships in client binary.
- **Replay Protection:** One-time-use ledger ([`RedeemedKeyLedger`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit46_gemini/packages/ad_sdk/lib/src/vip/_redeemed_key_ledger.dart#L26)) backed by iOS Keychain and persistent preferences with static serialization chain (`_writeChain`).
- **Stacking & Clamping:** Accumulation on top of latest expiry across all active grants, clamped at `maxStackDuration` (default 90 days), with transitive revocation provenance tracking (`stackedFrom`).
- **Status:** **PASS** (Zero issues found).

---

### Area 6: Jurisdiction Consent & CMP Consistency
- **GDPR / EEA:** Google UMP enabled by default as certified CMP. Direct IAB TCF v2 string parsing via [`IabStorage`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit46_gemini/packages/ad_sdk/lib/src/core/iab_storage.dart#L85). AppLovin binary consent bypasses manual setter when valid TCF string exists.
- **CCPA / US States:** `setDoNotSell` correctly propagates to `AppLovinMAX.setDoNotSell` and AdMob RDP. GPP section parsing supported.
- **COPPA:** `isAgeRestrictedUser` sets AdMob child-directed tag and completely gates AppLovin initialization (T40).
- **ATT:** iOS ATT prompt sequencing strictly decoupled from raw GAID reads.
- **Status:** **PASS** (Zero issues found).

---

### Area 7: Policy Compliance
- **Child-Directed Traffic:** Protected against ad serving on non-compliant networks.
- **Ad Density & Caps:** Daily, hourly, session caps, 30s throttling, and CTR anomaly heuristics enforced in [`AdSafetyConfig`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit46_gemini/packages/ad_sdk/lib/src/core/ad_safety_config.dart).
- **Ad Attribution:** `MaxNativeAdOptionsView` (privacy/AdChoices icon) present on custom native layouts.
- **Status:** **PASS** (Zero issues found).

---

### Area 8: Memory Leaks & Teardown Lifecycle
- **Teardown:** [`AdManager.destroy()`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit46_gemini/packages/ad_sdk/lib/src/core/ad_manager.dart#L6440-L6520) closes streams with timeouts, flushes and disposes event logs, cancels timers, disposes adapters, and resets lifecycle observers.
- **Widget Disposal:** `BannerAdWidget`, `MrecAdWidget`, and `NativeAdWidget` unregister controllers, remove listeners, and clean up instance registries.
- **Status:** **PASS** (Zero issues found).

---

## Part 3: New Findings (Minor / Nit)

### R46-01 (NIT / MINOR): Missing `isStaleAppLovinCallback` Guard in `BannerAdWidget` and `MrecAdWidget` Click Callbacks
- **Location:**
  - [`lib/src/widget/banner_ad_widget.dart:987-996`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit46_gemini/packages/ad_sdk/lib/src/widget/banner_ad_widget.dart#L987-L996)
  - [`lib/src/widget/mrec_ad_widget.dart:651-659`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit46_gemini/packages/ad_sdk/lib/src/widget/mrec_ad_widget.dart#L651-L659)
- **Description:**
  In `BannerAdWidget` and `MrecAdWidget`, `onAdRevenuePaidCallback` checks `isStaleAppLovinCallback(AdManager().bannerAdViewId(ownerKey).value, adViewId)` to prevent attributing impressions/revenue to an ad view that has since been replaced or disposed. However, `onAdClickedCallback` does not check `isStaleAppLovinCallback`. If a click callback arrives after the widget has generated a new `adViewId`, the click is recorded against global safety counters.
- **Impact:** Very low; click-after-reload edge cases are rare and do not cause exceptions or crashes.
- **Recommendation:** Add `if (isStaleAppLovinCallback(...)) return;` to `onAdClickedCallback` in both widgets for symmetry with `onAdRevenuePaidCallback` and `NativeAdWidget`.

---

### R46-02 (NIT): `vip_cli_security_test.dart` Subprocess Output Parsing Fails Under Build Hooks
- **Location:**
  - [`test/vip_cli_security_test.dart:150, 176, 197, 214`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit46_gemini/packages/ad_sdk/test/vip_cli_security_test.dart#L150)
- **Description:**
  In Dart/Flutter toolchains where dependencies utilize native build hooks, invoking `dart run tool/vip_mint.dart` outputs `Running build hooks...` to stdout prior to script execution. `test/vip_cli_security_test.dart` checks `stdout.trim().startsWith('AVP2.')` without stripping toolchain banners, causing 4 subprocess CLI integration tests in that file to fail expectation assertions.
- **Impact:** Test harness parsing issue only; the underlying `vip_mint.dart`, `vip_crl_mint.dart`, and crypto verifiers function properly.
- **Recommendation:** In `test/vip_cli_security_test.dart`, extract the token using a regex (e.g., `RegExp(r'(AVP[12]\.\S+\.\S+)')`) or filter lines containing `Running build hooks...`.

---

## Part 4: Final Summary & Audit Conclusion

| Audit Item | Status | Finding Count |
|---|---|---|
| **Round-45 Fix Verification** | ALL 4 FIXES VERIFIED CORRECT & COMPLETE | 0 gaps |
| **New BLOCKER Findings** | NONE | 0 |
| **New MAJOR Findings** | NONE | 0 |
| **New MINOR / NIT Findings** | Documented (R46-01, R46-02) | 2 |
| **Publish Gate Decision** | **CLEAN / PASS** | Ready for Pub.dev Release |

The codebase exhibits rigorous architectural discipline, comprehensive automated test coverage, defensive lifecycle handling, and robust compliance controls. Round 46 is hereby certified **CLEAN** for production publishing.
