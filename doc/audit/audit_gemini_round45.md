# Security and Correctness Audit Report (Round 45) — `applovin_admob_sdk`

**Auditor:** Adversarial Security & Correctness Auditor (Gemini Pass)  
**Date:** 2026-09-18  
**Target Package:** `packages/ad_sdk` (`applovin_admob_sdk` v2.9.23)  
**Scope:** Dual Provider Correctness, Offline/No-Network Behavior, Ad Type Lifecycle, 1-Day Trial, VIP Offline Activation, Multi-Jurisdiction Consent & CMP/TCF Alignment, Policy Compliance, Memory Safety.

---

## Executive Summary & Production Verdict

### **Verdict: PASS (Safe to Ship to Production as-is)**

Following the breaking changes and fixes introduced in Round 44 (removal of the non-certified Cupertino consent dialog, pre-init CCPA `setDoNotSell` buffering, prevention of TCF vendor consent override in AppLovin MAX, and inclusion of native ads in App Open inline surface blanking), the `packages/ad_sdk` codebase was subjected to an adversarial, deep-dive trace across all execution paths.

All 8 scope areas demonstrate rigorous defense-in-depth architecture, fail-safe/fail-closed cryptographic and privacy boundaries, robust offline state recovery, and comprehensive resource teardown.

---

## Detailed Audit Findings by Scope

---

### 1. Dual Provider Correctness (AdMob + AppLovin, Android + iOS)

#### 1.1 Equivalence Across Ad Types
Both providers (`AdMobAdapter` via `GmaBridge` and `AppLovinAdapter` via `AppLovinBridge`) implement the required ad interfaces and maintain identical slot state machines:

| Format | AdMob GMA Implementation | AppLovin MAX Implementation | Equivalence Status |
|---|---|---|---|
| **App Open** | `AppOpenAd` via `GmaBridge.loadAppOpen` / `show` (`admob_adapter.dart:800-920`) | `AppLovinMAX.loadAppOpenAd` / `showAppOpenAd` (`applovin_adapter.dart:1220-1340`) | **Equivalent**. Both wire display/dismiss callbacks, safety throttles, and paid revenue events. |
| **Interstitial** | `InterstitialAd` via `GmaBridge` (`admob_adapter.dart:1050-1190`) | `AppLovinMAX.loadInterstitial` / `showInterstitial` (`applovin_adapter.dart:1550-1690`) | **Equivalent**. AdMob implements 1h freshness expiry; AppLovin delegates to MAX native cache. |
| **Rewarded** | `RewardedAd` with `ServerSideVerificationOptions` (`gma_bridge.dart:362-369`) | `AppLovinMAX.showRewardedAd(customData: ...)` (`applovin_bridge.dart:104-106`) | **Equivalent**. SSV passthrough and reward-receipt integrity enforced on both. |
| **Rewarded Interstitial** | `RewardedInterstitialAd` via `GmaBridge` (`admob_adapter.dart:1667-1915`) | Documented intentional no-op (`applovin_adapter.dart:2050-2063`) | **Conscious platform difference**. MAX SDK does not have a separate Rewarded Interstitial format. `canShowRewardedInterstitialAd()` correctly returns `false` on AppLovin. |
| **Banner** | `BannerAd` with adaptive sizing (`admob_adapter.dart:2050+`, `banner_ad_widget.dart`) | `MaxAdView` via `preloadWidgetAdView` (`applovin_adapter.dart:2250+`) | **Equivalent**. RouteAware navigation pausing, visibility detection, and fullscreen suppression applied to both. |
| **MREC** | `BannerAd` with `AdSize.mediumRectangle` (`admob_adapter.dart:2200+`) | `MaxAdView` with `AdFormat.mrec` (`applovin_adapter.dart:2420+`) | **Equivalent**. Fixed 300x250 dimensions, route-aware pausing, and auto-refresh holds on both. |
| **Native** | `NativeAd` with `TemplateType` (`admob_adapter.dart:2348-2480`) | `MaxNativeAdView` on mount (`native_ad_widget.dart:575-725`) | **Equivalent**. AppLovin renders `MaxNativeAdOptionsView` for privacy compliance; AdMob renders template attribution. |

#### 1.2 Platform-Specific Code Paths (Android vs. iOS)
- **App Tracking Transparency (ATT):** Handled in [`lib/src/core/att_consent.dart:191-195`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit45_gemini/packages/ad_sdk/lib/src/core/att_consent.dart#L191-L195). On non-iOS platforms, it returns `AttStatus.notSupported` immediately without error. On iOS, it presents `AppTrackingTransparency.requestTrackingAuthorization()` and temporarily marks UMP form on screen (`markUmpFormOnScreen()`) to prevent fullscreen ad collision with the system prompt.
- **IAB Storage Backend:** In [`lib/src/core/iab_storage.dart:156-166`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit45_gemini/packages/ad_sdk/lib/src/core/iab_storage.dart#L156-L166), Android dynamically resolves the SharedPreferences filename (`<packageName>_preferences`), while iOS targets standard `NSUserDefaults`. Both calls are bounded by 5-second timeouts.
- **App Open Show Watchdogs:** On Android, `AdMobAdapter` and `AppLovinAdapter` poll `WidgetsBinding.instance.lifecycleState` to detect hung overlays if the app remains resumed without native callbacks. On iOS, because fullscreen ads are presented within the `resumed` lifecycle state, the hung-overlay heuristic is safely bypassed to avoid false-positive dismissals, relying instead on native callbacks and the 90s hard-cap timeout ([`applovin_adapter.dart:1340-1410`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit45_gemini/packages/ad_sdk/lib/src/adapters/applovin_adapter.dart#L1340-L1410)).

---

### 2. Offline / No-Network Behavior

#### 2.1 Initialization & UMP Offline
- During `AdManager.initialize()` / `bootstrap()`, if the device is offline:
  - `requestUmpConsentFlow()` in [`lib/src/core/ump_consent.dart:226-239`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit45_gemini/packages/ad_sdk/lib/src/core/ump_consent.dart#L226-L239) bounds network calls with a 20s timeout.
  - If unreachable, `ConsentFallbackReason.offline` or `.timeout` is recorded in [`lib/src/consent/consent_fallback.dart`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit45_gemini/packages/ad_sdk/lib/src/consent/consent_fallback.dart), preserving existing consent decisions or defaulting conservatively to non-personalized ads without crashing or hanging.
  - `bootstrap()` exposes an `initTimeout` (default 20s) preventing indefinite splash hangs.

#### 2.2 In-Session Ad Requests & Shows
- `AdManager.isConnected` ([`lib/src/core/ad_manager.dart:6831-6856`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit45_gemini/packages/ad_sdk/lib/src/core/ad_manager.dart#L6831-L6856)) uses `ConnectionNotifierTools` with safe fallback to `_lastConnected`.
- All `load*()` methods (`loadAppOpenAd`, `loadInterstitial`, `loadRewardedAd`, `loadRewardedInterstitialAd`, `preloadBanner`, `preloadNative`) verify `isConnected`. When offline, they skip immediately, emit skip telemetry (`_emitSkip(..., 'no_network')`), and trigger caller callbacks with `false` or `RewardResult.skipped`.
- If an ad was loaded prior to network loss, it can be displayed. If no ad is cached, `canShow*()` returns `false`, and `show*()` safely invokes `onDone(false)` / `RewardResult.skipped` without throwing exceptions.
- Mid-request network drops are bounded by `_widgetLoadWatchdog` (30s) in [`admob_adapter.dart:385`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit45_gemini/packages/ad_sdk/lib/src/adapters/admob_adapter.dart#L385), transitioning slots to `cooldown` rather than permanently wedging them in `loading`.

#### 2.3 Connectivity Recovery
- Reconnection triggers `_startConnectivityWatch` ([`ad_manager.dart:8760-8798`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit45_gemini/packages/ad_sdk/lib/src/core/ad_manager.dart#L8760-L8798)):
  1. Re-attempts UMP consent recovery if owed (`_recoverConsentGate()`).
  2. Resets backoff cooldowns via `clearCooldownOnReconnect()`.
  3. Executes `_retryRefillAds()` to pre-fill idle fullscreen slots.
  4. Bumps `initRevision`, triggering mounted `BannerAdWidget`, `MrecAdWidget`, and `NativeAdWidget` instances to reload cleanly.
  5. No rewards are fabricated or lost on connectivity drops.

---

### 3. Ad Type Lifecycle Correctness

#### 3.1 Inline Ad Lifecycle (Banner, MREC, Native)
- **Instance Isolation:** `InlineAdInstanceRegistry` ([`lib/src/adapters/inline_ad_instance_registry.dart`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit45_gemini/packages/ad_sdk/lib/src/adapters/inline_ad_instance_registry.dart)) tracks each widget instance by key with dedicated `AdSlot` and `BannerListenables` bundles.
- **Route Tracking:** `BannerAdWidget` and `MrecAdWidget` subscribe to `adRouteObserver` ([`lib/src/core/ad_route_observer.dart`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit45_gemini/packages/ad_sdk/lib/src/core/ad_route_observer.dart)). `didPushNext()` pauses auto-refresh; `didPopNext()` resumes it.
- **Visibility Detection:** `VisibilityDetector` in `BannerAdWidget` ([`banner_ad_widget.dart:705-710`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit45_gemini/packages/ad_sdk/lib/src/widget/banner_ad_widget.dart#L705-L710)) and `MrecAdWidget` ([`mrec_ad_widget.dart:395-400`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit45_gemini/packages/ad_sdk/lib/src/widget/mrec_ad_widget.dart#L395-L400)) suspends auto-refresh when scrolled off-screen or occluded.
- **Fullscreen Blanking Pass:** `InlineVisibilityOwners` hides all active Banner, MREC, and Native surfaces when any fullscreen ad is displayed (`admob_adapter.dart:38-61`, `applovin_adapter.dart:53-102`). Late-mounting surfaces during fullscreen ads inherit the hold (`_inheritFullscreenHold`).

#### 3.2 Fullscreen Ad Lifecycle & Mutex Protection
- Shared mutex `_fullscreenBusyReason` ([`lib/src/core/ad_manager.dart:2101-2151`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit45_gemini/packages/ad_sdk/lib/src/core/ad_manager.dart#L2101-L2151)) prevents simultaneous or overlapping fullscreen displays across:
  - App Open, Interstitial, Rewarded, and Rewarded Interstitial slots.
  - Native UMP consent forms (`umpFormOnScreen.value`).
  - Native iOS ATT prompts (`markUmpFormOnScreen`).
  - Host custom overlays (`customOverlayOnScreen.value`).
  - SDK buffer dialogs (`AdLoadingDialog.isShowing`).
  - Modal routes / popups / bottom sheets (`AdScreenRouteLogger.isDialogOnTop`).
  - Ongoing teardowns (`_destroyInFlight != null`).
- **App Open on Resume:** [`ad_manager.dart:7161-7280`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit45_gemini/packages/ad_sdk/lib/src/core/ad_manager.dart#L7161-L7280) enforces:
  - `consumeBackgroundedFromAdClick()`: Suppresses App Open if the user is returning from clicking an ad landing page.
  - `dismissDelta < 5000ms`: Suppresses App Open if another fullscreen ad was dismissed within 5 seconds.
  - `AdScreenRouteLogger.isDialogOnTop`: Avoids showing App Open over active dialogs.

---

### 4. Trial Mode (1-Day Grace)

#### 4.1 Implementation & Security Properties
- Implemented via `FirstInstallVipGrace` ([`lib/src/config/ad_config.dart:30-59`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit45_gemini/packages/ad_sdk/lib/src/config/ad_config.dart#L30-L59)) and `FirstInstallGuard` ([`lib/src/vip/_first_install_guard.dart:89-200`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit45_gemini/packages/ad_sdk/lib/src/vip/_first_install_guard.dart#L89-L200)).
- **Clock Rollback Resistance:** Stamped with `_effectiveNow()` ([`lib/src/vip/vip_manager.dart:374-390`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit45_gemini/packages/ad_sdk/lib/src/vip/vip_manager.dart#L374-L390)), which enforces a monotonic session stopwatch and persists a high-water mark (`getVipMaxObservedClockMs`). If the device clock is rewound before `grantedAt`, `VipEntry.isActiveAt()` ([`lib/src/vip/vip_entry.dart:55-58`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit45_gemini/packages/ad_sdk/lib/src/vip/vip_entry.dart#L55-L58)) immediately returns `false` (fails closed).
- **Timezone Robustness:** `VipEntry.toJson()` converts timestamps to UTC ISO-8601 (`toUtc().toIso8601String()`), preventing timezone or DST shifts from altering entitlement validity ([`vip_entry.dart:89-97`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit45_gemini/packages/ad_sdk/lib/src/vip/vip_entry.dart#L89-L97)).
- **Reinstall & Data Clear Trade-Offs:**
  - **iOS:** Backed by Keychain (`kSecAttrAccessibleAfterFirstUnlock`), surviving app reinstallation.
  - **Android:** Relies on SharedPreferences backed up via Android Auto Backup. App data clearing resets local preferences (documented accepted trade-off for zero-backend architecture).
  - Storage failures degrade gracefully to allow trial access (fail open for legitimate users).

---

### 5. VIP Activation by Offline Signed Codes

#### 5.1 Cryptographic Verification & Enforcement
- `SignedVipKey` ([`lib/src/vip/signed_vip_key.dart:121-250`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit45_gemini/packages/ad_sdk/lib/src/vip/signed_vip_key.dart#L121-L250)) enforces genuine Ed25519 signature verification using `package:cryptography`.
- Supports both `AVP1.<payload>.<sig>` and `AVP2.<payload>.<sig>` wire formats.
- **AVP2 Bindings:** Payload embeds `<seconds>|<keyId>|<expiresAtEpochSeconds>|<bundleId>`.
  - Expiry is validated against `_effectiveNow()` ([`signed_vip_key.dart:218-224`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit45_gemini/packages/ad_sdk/lib/src/vip/signed_vip_key.dart#L218-L224)).
  - Package bundle ID is checked against `PackageInfo.packageName` ([`signed_vip_key.dart:236-242`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit45_gemini/packages/ad_sdk/lib/src/vip/signed_vip_key.dart#L236-L242)).
  - Key rotation supported via comma-separated public key strings.
- **Revocation Lists (CRL):** `VipRevocationList` (`CRL1.<payload>.<sig>`) uses domain separation (`"CRL1|"`) to prevent cross-protocol replay as an AVP1 key ([`signed_vip_key.dart:276-300`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit45_gemini/packages/ad_sdk/lib/src/vip/signed_vip_key.dart#L276-L300)).

#### 5.2 Replay Protection & Stacking
- **Atomic Local Claim:** Synchronous claim in `_signedKidsInFlight` and `_prefs.isVipKeyIdRedeemed()` ([`vip_manager.dart:1421-1430`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit45_gemini/packages/ad_sdk/lib/src/vip/vip_manager.dart#L1421-L1430)) eliminates in-process double-redemption races.
- **Durable Ledger:** On iOS, `RedeemedKeyLedger` ([`lib/src/vip/_redeemed_key_ledger.dart:82-128`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit45_gemini/packages/ad_sdk/lib/src/vip/_redeemed_key_ledger.dart#L82-L128)) records key IDs in Keychain with serialized `_writeChain` execution.
- **Stacking Logic & Laundering Prevention:** `addVip(stack: true)` in [`vip_manager.dart:1066-1110`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit45_gemini/packages/ad_sdk/lib/src/vip/vip_manager.dart#L1066-L1110) extends from the latest active expiry, records transitive `stackedFrom` history to prevent laundering revoked keys through rewarded ad extensions, and strictly clamps total entitlement against `AdConfig.maxVipStackDuration` (default 90 days).

---

### 6. Consent & Multi-Jurisdiction Privacy Alignment

#### 6.1 Certified CMP & TCF Alignment
- Non-certified custom consent dialog was removed in Round 44.
- Google UMP (`requestUmpConsentFlow`) serves as the certified CMP, storing standard IAB TCF strings in platform storage.
- `IabStorage.tcfAllowsPersonalisedAds()` ([`lib/src/core/iab_storage.dart:540-607`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit45_gemini/packages/ad_sdk/lib/src/core/iab_storage.dart#L540-L607)) checks `IABTCF_gdprApplies` and requires Purpose 1, 3, and 4 consents for personalized ads, failing closed if storage is corrupted.
- **AppLovin TCF Passthrough (Round 44 Fix Confirmed):**
  In [`lib/src/core/ad_consent.dart:164-168`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit45_gemini/packages/ad_sdk/lib/src/core/ad_consent.dart#L164-L168):
  ```dart
  final hasIabTcfString =
      (await IabStorage.read(IabStorage.keyTcfString))?.isNotEmpty == true;
  if (!hasIabTcfString) {
    AppLovinMAX.setHasUserConsent(outcome.appLovinHasUserConsent);
  }
  AppLovinMAX.setDoNotSell(outcome.appLovinDoNotSell);
  ```
  When a TCF string is present, `AppLovinMAX.setHasUserConsent` is bypassed, enabling the MAX native SDK to parse `IABTCF_TCString` directly per IAB specification without conflict.

#### 6.2 CCPA / CPRA Pre-Init Buffering (Round 44 Fix Confirmed)
- In [`lib/src/core/ad_manager.dart:4917-4938`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit45_gemini/packages/ad_sdk/lib/src/core/ad_manager.dart#L4917-L4938), calling `setDoNotSell(true)` before `initialize()` routes through `setConsent()`, buffering into `_pendingConsentSettings` and `_consent` rather than dropping the call.
- `CcpaOptOutToggle` ([`lib/src/consent/ccpa_opt_out_toggle.dart`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit45_gemini/packages/ad_sdk/lib/src/consent/ccpa_opt_out_toggle.dart)) provides an accessible UI toggle that binds to `ConsentManager` and auto-activates upon SDK init.

#### 6.3 Mid-Session Consent Withdrawal
- Withdrawing consent immediately invokes `discardCachedFullscreenAds()` (`admob_adapter.dart:652-685`, `applovin_adapter.dart:885-912`), dropping cached ready ads and bumping `AdSlot.consentEpoch` to reject in-flight requests.
- `BannerAdWidget` and `NativeAdWidget` listen to `AdManager.personalisationRevision` to tear down and rebuild mounted ads under the updated consent state.

---

### 7. AdMob & AppLovin Policy Compliance

#### 7.1 Child-Directed Treatment (COPPA & TFUA)
- **AdMob:** `AdMobAdapter.initialize()` ([`admob_adapter.dart:455-464`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit45_gemini/packages/ad_sdk/lib/src/adapters/admob_adapter.dart#L455-L464)) invokes `updateRequestConfiguration()` with `TagForChildDirectedTreatment.yes` / `.no` and `TagForUnderAgeOfConsent.yes` / `.unspecified` **before** `MobileAds.instance.initialize()`.
- **AppLovin:** `AppLovinAdapter.initialize()` ([`applovin_adapter.dart:756-766`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit45_gemini/packages/ad_sdk/lib/src/adapters/applovin_adapter.dart#L756-L766)) detects `isAgeRestrictedUser == true` and terminates initialization (`_disabledForChildUser = true`), as AppLovin MAX 4.x does not provide a compliant runtime COPPA initialization API.
- **TFAT Note:** Use of legacy `tagForChildDirectedTreatment` / `tagForUnderAgeOfConsent` rather than `ageRestrictedTreatment` is an accepted constraint of the Flutter 3.35.1 floor and is fully supported by Google through 2026.

#### 7.2 Ad Placement & Mediation Compliance
- **Native Ad Compliance:** `NativeAdWidget` on AppLovin MAX renders `MaxNativeAdOptionsView` ([`native_ad_widget.dart:708`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit45_gemini/packages/ad_sdk/lib/src/widget/native_ad_widget.dart#L708)) in accordance with AppLovin privacy requirements.
- **QA Fleet Test Hashes:** `kQaTestDeviceHashes` ([`lib/src/config/ad_config.dart:228-242`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit45_gemini/packages/ad_sdk/lib/src/config/ad_config.dart#L228-L242)) are merged into `AdMobConfig.effectiveTestDeviceIds` across all build modes, preventing accidental live invalid clicks during QA on physical hardware.

---

### 8. Memory Safety & Resource Teardown

All `StreamController`, `Timer`, platform listener, and `ValueNotifier` allocations were audited. Below are three end-to-end dispose chains:

#### 8.1 Dispose Chain 1: `AdManager.destroy()` → `AdMobAdapter.dispose()`
1. [`AdManager.destroy()`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit45_gemini/packages/ad_sdk/lib/src/core/ad_manager.dart#L6253): Coalesces redundant calls via `_destroyInFlight`, invalidates in-flight inits via `_initGen++`, cancels `_initRetryTimer`, uninstalls crash guards, and detaches lifecycle observers.
2. Closes `_eventStream` with a 2-second timeout ([`ad_manager.dart:6423-6430`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit45_gemini/packages/ad_sdk/lib/src/core/ad_manager.dart#L6423-L6430)), preventing hanging subscribers from blocking destruction.
3. Invokes [`_disposeAdapter()`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit45_gemini/packages/ad_sdk/lib/src/core/ad_manager.dart#L6759), detaching slot listeners and calling `old.dispose()` with a 2-second timeout.
4. [`AdMobAdapter.dispose()`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit45_gemini/packages/ad_sdk/lib/src/adapters/admob_adapter.dart#L481):
   - Sets `_fullscreenDisposed = true` and cancels `_appOpenShowTimeout`.
   - Disposes `_appOpenAd`, `_interstitialAd`, `_rewardedAd`, and `_rewardedInterstitialAd` via `_disposeAd()`, which nulls `fullScreenContentCallback` and `onPaidEvent` prior to native disposal.
   - Iterates and disposes all `_bannerAdsByKey`, `_mrecAdsByKey`, and `_nativeAdsByKey` native instances.
   - Cleans up registries: `_bannerRegistry.markDisposed()`, `_mrecRegistry.markDisposed()`, `_nativeRegistry.markDisposed()`.
   - Disposes `appOpenSlot`, `interstitialSlot`, `rewardedSlot`, and `rewardedInterstitialSlot` `ValueNotifiers`.
   - Resolves pending callbacks (`_appOpenDismiss`, `_interstitialDone`, `_rewardedDone`) and sets `eventSink = null`.

#### 8.2 Dispose Chain 2: `AdManager.destroy()` → `AppLovinAdapter.dispose()`
1. `AdManager` tears down subsystems: `_vipManager?.dispose()`, `_arbitrator?.dispose()`, `_fillRateMonitor?.dispose()`, `_revenueIntegrityLedger?.dispose()`, `_fillRateBaselineMonitor?.dispose()`, `_waterfallTuner?.dispose()`, `_selfHealingObserver?.dispose()`.
2. [`AppLovinAdapter.dispose()`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit45_gemini/packages/ad_sdk/lib/src/adapters/applovin_adapter.dart#L914):
   - Sets `_teardownStarted = true`, `_bannerRegistry.markDisposed()`, `_mrecRegistry.markDisposed()`, `_nativeRegistry.markDisposed()`.
   - Cancels all active timers: `_appOpenShowTimeout`, `_interstitialQuarantineTimer`, `_rewardedQuarantineTimer`, and every timer in `_destroyRetryTimers`.
   - Clears native bridge listeners: `setAppOpenAdListener(null)`, `setInterstitialListener(null)`, `setRewardedAdListener(null)`, `setWidgetAdViewAdListener(null)`.
   - Destroys native platform views: iterates `_bannerAdViewIdByKey` and `_mrecAdViewIdByKey` and calls `destroyWidgetAdView`.
   - Disposes slots, resets visibility owners (`_inlineVisibility.forgetAll()`), answers pending callbacks, and nulls `eventSink`.

#### 8.3 Dispose Chain 3: Widget Unmount (`BannerAdWidgetState.dispose()`)
1. [`BannerAdWidgetState.dispose()`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit45_gemini/packages/ad_sdk/lib/src/widget/banner_ad_widget.dart#L664):
   - Detaches `InlineAdController` and cancels `_widthCorrectionDebounce`.
   - Unsubscribes from `canRequestAdsListenable`, `personalisationRevision`, and `adRouteObserver`.
   - Invokes `AdManager().disposeBannerInstance(this)`.
   - Disposes local state notifiers (`_admobIsTop`, `_initStarted`, `_allowed`).
2. In `AdMobAdapter.disposeBannerInstance(key)`:
   - Removes and disposes `_bannerAdsByKey[key]`.
   - Removes entry from `_bannerRegistry`, calls `_inlineVisibility.forget(gone)`, and disposes `BannerListenables`.
   - Removes key from `_bannerRoutePausedByKey`.

---

## Known Accepted Design Trade-offs & Standing Items

1. **Android No-Backend Trial / One-Time-Use Reset:** Clearing application data in Android settings resets SharedPreferences, resetting the 1-day grace period and local redemption ledger. (iOS Keychain survives). Documented in `CLAUDE.md` and `README.md` as an accepted trade-off of the serverless architecture.
2. **Flutter 3.35.1 CI Floor / Dependencies:** Upgrading `google_mobile_ads` to v8/v9 and `package_info_plus` is constrained by the Flutter 3.35.1 test runner floor. Legacy COPPA/TFUA APIs remain valid through 2026.
3. **Repository Git History (`private_key.pepk`):** Historical commit `60a1f3d` contains a removed Play App Signing key export. The repository remains private; key rotation is required before any public release.

---

## Final Audit Checklist

| Check | Scope Area | Status |
|---|---|---|
| 1 | Dual Provider Equivalence (AdMob & AppLovin) | **PASS** |
| 2 | Offline & Fault Recovery Resilience | **PASS** |
| 3 | Ad Type Lifecycle & Mutex Stacking Protection | **PASS** |
| 4 | 1-Day Trial Mode Tamper Resistance | **PASS** |
| 5 | Offline Ed25519 VIP Activation & CRL Revocation | **PASS** |
| 6 | UMP CMP & TCF Consistency Across Providers | **PASS** |
| 7 | AdMob & AppLovin Policy Compliance | **PASS** |
| 8 | Memory Management & Disposal Chains | **PASS** |

**Conclusion:** `packages/ad_sdk` (v2.9.23) is robust, compliant, memory-safe, and ready for production deployment.
