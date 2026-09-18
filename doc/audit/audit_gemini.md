# Independent Security & Quality Audit Report: `applovin_admob_sdk`

**Audit Round:** Round 44 (Independent Fresh-Eye Review)  
**Package Name:** `applovin_admob_sdk`  
**Package Version:** `2.9.23` (Verified identical to latest on [pub.dev/packages/applovin_admob_sdk](https://pub.dev/packages/applovin_admob_sdk))  
**Target Platforms:** Android & iOS (Flutter `>=3.27.0`, Dart SDK `>=3.6.0 <4.0.0`)  
**Auditor:** Adversarial Senior Mobile Ad SDK Auditor & Security Specialist  
**Report Destination:** `REPORT_audit_gemini.md`  

---

## Executive Summary & Production Verdict

### Production Verdict: **YES (Production-Ready As-Is)**

The `applovin_admob_sdk` package is **approved for production use**. It exhibits an exceptionally high caliber of defensive software engineering, architectural discipline, lifecycle robustness, and regulatory compliance. Across all seven audited subsystems, edge cases—including race conditions, stale callbacks, clock tampering, network degradation, and cross-provider privacy propagation—are thoroughly guarded and hardened.

The few observed limitations (e.g., Android first-install grace reset upon manual local app storage deletion, and multi-device sharing of offline VIP keys) are inherent trade-offs of an **offline-first, zero-backend architecture** rather than software bugs. These constraints are transparently documented and mitigated with multi-layered client-side controls.

---

## High-Level Subsystem Scorecard

| # | Subsystem | Status | Risk Level | Key Strengths / Observations |
|---|---|---|---|---|
| 1 | **Cross-Platform Abstraction** | PASS | Low | Clean unified adapter contract behind `AdProviderAdapter`. Fully abstracts AdMob (GMA) and AppLovin MAX across iOS and Android with zero platform channel leaks. |
| 2 | **Offline / No-Network Behavior** | PASS | Low | Bounded async timeouts (20s UMP update, 20s init, 30s load watchdogs). Safe fail-closed / fail-soft behaviors. Automatic reconnection recovery via `ConnectionNotifierTools`. |
| 3 | **Ad Type Lifecycle & Memory** | PASS | Low | Strict state machine (`AdSlot`) transitions. Dedicated watchdogs for unconfirmed shows. Inline ads blanked/paused during fullscreen shows. Zero BuildContext leaks in `AdLoadingDialog`. |
| 4 | **Trial Mode (1-Day Grace)** | PASS | Low / Accepted Trade-off | Dual-clock verification (`_isLive` checks high-water mark for expiry and raw clock for start). iOS Keychain anti-reinstall persistence. Android uses SharedPreferences + Auto Backup. |
| 5 | **VIP Activation (Serverless)** | PASS | Low / Accepted Trade-off | Ed25519 asymmetric cryptography. AVP2 format enforces app bundle ID binding and absolute expiration timestamps. Durable per-device replay prevention via Keychain ledger. |
| 6 | **Consent & Privacy (GDPR/CCPA/COPPA)** | PASS | Low | Reads TCF v2.2, CCPA (US Privacy), and GPP (MSPA Section 7) strings directly from platform default storage via `SharedPreferencesAsync`. Correctly maps flags to AdMob (RDP, NPA, COPPA, TFUA) and AppLovin MAX. |
| 7 | **AdMob / AppLovin Policy Compliance** | PASS | Low | Enforces strict reward completion semantics (`RewardResult.earned`), mandatory Rewarded Interstitial announcements, fullscreen mutex blocking overlays on CMPs, and ad density caps. |

---

## In-Depth Subsystem Audits

### 1. Cross-Platform Provider Abstraction (AdMob + AppLovin on Android & iOS)

#### Architectural Design
The SDK achieves full provider independence through the [`AdProviderAdapter`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit44_gemini/packages/ad_sdk/lib/src/core/ad_provider_adapter.dart#L149-L432) interface. The orchestrator [`AdManager`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit44_gemini/packages/ad_sdk/lib/src/core/ad_manager.dart) holds no direct references to Google Mobile Ads or AppLovin MAX plugins; all operations are routed through either [`AdMobAdapter`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit44_gemini/packages/ad_sdk/lib/src/adapters/admob_adapter.dart) or [`AppLovinAdapter`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit44_gemini/packages/ad_sdk/lib/src/adapters/applovin_adapter.dart).

```
                      ┌────────────────────────┐
                      │       AdManager        │
                      └───────────┬────────────┘
                                  │
                                  ▼
                      ┌────────────────────────┐
                      │   AdProviderAdapter    │
                      └─────┬────────────┬─────┘
                            │            │
             ┌──────────────┘            └──────────────┐
             ▼                                          ▼
   ┌───────────────────┐                      ┌───────────────────┐
   │   AdMobAdapter    │                      │  AppLovinAdapter  │
   │   (GmaBridge)     │                      │ (AppLovinBridge)  │
   └─────────┬─────────┘                      └─────────┬─────────┘
             │                                          │
    ┌────────┴────────┐                        ┌────────┴────────┐
    ▼                 ▼                        ▼                 ▼
 Android             iOS                    Android             iOS
```

#### Verification Highlights:
- **Platform-Specific Ad Unit IDs**: Both [`AdMobConfig`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit44_gemini/packages/ad_sdk/lib/src/config/ad_config.dart#L154-L215) and [`AppLovinConfig`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit44_gemini/packages/ad_sdk/lib/src/config/ad_config.dart#L312-L379) cleanly resolve Android vs. iOS IDs dynamically using `Platform.isIOS` without leaking OS-specific logic to the caller.
- **Provider Parity**:
  - **App Open**: Uses `AppOpenAd` (AdMob) vs. `AppLovinMAX.loadAppOpenAd` / `showAppOpenAd`.
  - **Interstitial**: Uses `InterstitialAd` (AdMob) vs. `AppLovinMAX.loadInterstitial` / `showInterstitial`.
  - **Rewarded**: Uses `RewardedAd` (AdMob) vs. `AppLovinMAX.loadRewardedAd` / `showRewardedAd` with Server-Side Verification (SSV) passthrough (`ServerSideVerificationOptions` for AdMob, `customData` for AppLovin).
  - **Rewarded Interstitial**: Native to Google Mobile Ads. Handled as a documented no-op in `AppLovinAdapter` without throwing or stalling callers.
  - **Banner & MREC**: AdMob mounts native platform views via `AdWidget`; AppLovin utilizes `MaxAdView` initialized via `preloadWidgetAdView(adUnitId, adFormat)` with individual instance tracking.
  - **Native Ads**: AdMob uses `NativeAd` with standard `NativeTemplateStyle` (`TemplateType.medium` / `TemplateType.small`); AppLovin uses `MaxNativeAdView`.
- **Test Devices**: AdMob registers hashed device IDs with `updateRequestConfiguration(testDeviceIds)`. AppLovin registers GAID/IDFA via `setTestDeviceAdvertisingIds` strictly **before** `_bridge.initialize()` (satisfying the native AppLovin MAX SDK init-time configuration requirement).

---

### 2. Offline / No-Network Behavior

#### Resilience & Failure Modes:
- **Init Time Offline**:
  - `AdBootstrap.bootstrap()` wraps the initial setup with an `initTimeout` (default 20s).
  - `requestUmpConsentFlow()` wraps `ConsentInformation.instance.requestConsentInfoUpdate()` with a 20s timeout. If no network is available, it completes immediately or on timeout, setting `canRequestAds = false` (or returning cached status) without crashing.
  - If UMP fails due to no network, `_umpAttemptFailed` is flagged.
- **Reconnection Self-Healing**:
  - `AdManager` subscribes to `ConnectionNotifierTools.onStatusChange` via `_connectivitySub`.
  - When transitioning from offline to online (`_onConnectivityChanged`), a debounced timer (`_reconnectDebounce`) re-triggers UMP consent if previous attempts failed, and automatically refills all empty ad slots (`loadAppOpenAd`, `loadInterstitial`, `loadRewardedAd`, and refreshes mounted `BannerAdWidget`/`MrecAdWidget`/`NativeAdWidget`).
- **Mid-Load Disconnection**:
  - AdMob and AppLovin failure callbacks (`onAdFailedToLoad`, `onAdLoadFailedCallback`) trigger `slot.markFailed()` which engages exponential backoff (`AdRetryPolicy`).
  - To protect against hanging native platform channels, every load is guarded by `armLoadWatchdog(duration: 30s)` which forces the slot out of `loading` state if the platform bridge drops the callback.
- **Mid-Show Disconnection**:
  - If a cached video ad fails to stream/display when presented, native callbacks `onFailedToShow` (AdMob) or `onAdDisplayFailedCallback` (AppLovin) immediately trigger `slot.markShowFailed()`, unlock `_fullscreenBusyReason` and `_rewardedInFlight`, and safely call `onDone(RewardResult.skipped)` / `onDone(false)`.
  - Both adapters wrap `ad.show()` in `try / catch` blocks to ensure unhandled platform exceptions never wedge the SDK mutex.

---

### 3. Ad Type Lifecycle Correctness & Memory Integrity

#### State Machine & Mutex Architecture
All ad formats utilize the reactive [`AdSlot`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit44_gemini/packages/ad_sdk/lib/src/state/ad_slot.dart) state machine:

```
                  ┌──────────────┐
                  │     Idle     │
                  └──────┬───────┘
                         │ beginLoad()
                         ▼
                  ┌──────────────┐   markFailed()    ┌──────────────┐
                  │   Loading    ├──────────────────►│   Cooldown   │
                  └──────┬───────┘                   └──────┬───────┘
                         │ markReady()                      │ (retry timer)
                         ▼                                  │
                  ┌──────────────┐                          │
                  │    Ready     │                          │
                  └──────┬───────┘                          │
                         │ beginShow()                      │
                         ▼                                  │
                  ┌──────────────┐                          │
                  │   Showing    │                          │
                  └──────┬───────┘                          │
                         │ markDismissed() / markShowFailed()
                         ▼                                  │
                  ┌──────────────┐                          │
                  │  Dismissed   │◄─────────────────────────┘
                  └──────────────┘
```

#### Lifecycle & Resource Verification:
1. **Multi-Instance Inline Tracking**:
   - Both `BannerAdWidget`, `MrecAdWidget`, and `NativeAdWidget` register independent slot states keyed by widget instance (`_bannerRegistry`, `_mrecRegistry`, `_nativeRegistry`).
   - When a widget unmounts (e.g., scrolled out of a `ListView`), its `State.dispose()` invokes `disposeBannerInstance(this)`, `disposeMrecInstance(this)`, or `disposeNativeInstance(this)`, cleanly destroying native `BannerAd` / `NativeAd` objects and freeing `AdViewId`s on AppLovin MAX.
2. **Rewarded Ads Completion Integrity**:
   - In [`AdMobAdapter.showRewarded`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit44_gemini/packages/ad_sdk/lib/src/adapters/admob_adapter.dart#L1460-L1650), `earned` is set to `true` **only** upon execution of the native `onUserEarnedReward` callback. Early closure via `onDismissed` yields `earned: false`.
   - In [`AppLovinAdapter.showRewarded`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit44_gemini/packages/ad_sdk/lib/src/adapters/applovin_adapter.dart#L1960-L2025), `earned` is set to `true` **only** upon `onAdReceivedRewardCallback`. Early dismissal via `onAdHiddenCallback` reports `earned: false`.
   - The impression signal (`shown: true`) is strictly decoupled from `earned: true` through `AdSlot.displayConfirmed`.
3. **UI & BuildContext Safety**:
   - [`AdLoadingDialog`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit44_gemini/packages/ad_sdk/lib/src/widget/ad_loading_dialog.dart) pushes a custom `DialogRoute` and dismisses it strictly by route instance identity (`nav.removeRoute(route)`), preventing popping arbitrary user routes if a route change occurs while an ad buffer is active.
   - An invalidation epoch (`AsyncEpoch`) cancels pending delay timers upon reset.

---

### 4. Trial Mode (1-Day First-Install VIP Grace)

#### Security & Clock Tampering Analysis
The 1-day grace period is implemented in [`AdConfig.firstInstallVipGrace`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit44_gemini/packages/ad_sdk/lib/src/config/ad_config.dart#L405) and managed by [`VipManager`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit44_gemini/packages/ad_sdk/lib/src/vip/vip_manager.dart).

1. **Clock Rollback Defenses**:
   - `VipManager._effectiveNow()` maintains a persistent high-water mark timestamp on disk (`_prefs.getVipMaxObservedClockMs()`). If the system clock is set back, `_effectiveNow()` returns the highest observed timestamp, preventing expired trials from returning to active status.
   - Forward clock jumping is guarded by in-session monotonic anchoring (`_sessionClockStopwatch`).
   - `_isLive(e, now)` requires that an entry is valid against **both** the high-water mark (expiry check) and the real raw device clock (start check: `!DateTime.now().add(futureGrantSlack).isBefore(e.grantedAt)`). This defeats the "set clock 5 years ahead -> claim -> set clock back" exploit.
2. **Reinstallation & Storage Clearing**:
   - **iOS**: Uses `FlutterSecureStorage` with `KeychainAccessibility.first_unlock` (`_first_install_guard.dart`). Keychain items persist across app uninstallation and reinstallation, preventing repeated trial claiming.
   - **Android**: As documented in `_first_install_guard.dart:27-88`, client-only Android apps cannot persist identifiers across app uninstalls without root or backend device attestation. The SDK leverages Android Auto Backup (`FlutterSharedPreferences.xml`). A manual storage wipe in Android Settings resets the grace period. This is an **explicit, documented product trade-off**.

---

### 5. VIP Activation by Offline Code (No Backend / Server)

#### Cryptographic Architecture
VIP code redemption is implemented in [`SignedVipKey`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit44_gemini/packages/ad_sdk/lib/src/vip/signed_vip_key.dart).

```
   ┌─────────────────────────────────────────────────────────────┐
   │                        AVP2 Code                            │
   │  "AVP2.<base64url(payload)>.<base64url(ed25519_signature)>"  │
   └──────────────────────────────┬──────────────────────────────┘
                                  │
                                  ▼
   ┌─────────────────────────────────────────────────────────────┐
   │                      Signed Payload                         │
   │    "<seconds>|<keyId>|<expiresAtEpochSeconds>|<bundleId>"    │
   └──────────────────────────────┬──────────────────────────────┘
                                  │
         ┌────────────────────────┴────────────────────────┐
         ▼                                                 ▼
   1. Ed25519 Verify                              2. Context Checks
   (via Developer Public Key)                     - currentBundleId match
                                                  - now <= expiresAtEpochSeconds
                                                  - keyId not in RedeemedKeyLedger
```

#### Verification & Threat Assessment:
- **Forgery Resistance**: Uses Ed25519 asymmetric cryptography. The private minting key is never packaged in the mobile app (minted offline via `tool/vip_mint.dart`). Decompiling the APK/IPA reveals only the verification public key (`AdConfig.vipPublicKey`), which mathematically cannot be used to generate valid signatures.
- **Replay & Sharing Protections**:
  - **Local Device Replay**: Blocked by [`RedeemedKeyLedger`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit44_gemini/packages/ad_sdk/lib/src/vip/_redeemed_key_ledger.dart) (persisted to iOS Keychain / Android SharedPreferences).
  - **Cross-App Replay**: AVP2 embeds `bundleId` inside the signed payload; mismatched bundle IDs are rejected.
  - **Time-Bounded Validity**: AVP2 embeds `expiresAtEpochSeconds`, limiting the window in which a leaked code can be activated.
  - **Revocation Support**: Supports signed Certificate Revocation Lists ([`VipRevocationProvider`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit44_gemini/packages/ad_sdk/lib/src/vip/vip_revocation_provider.dart) / `verifySignedCrl`).
  - **Cross-Device Sharing**: Because there is no backend server, an unexpired code can be redeemed on multiple physical devices. This is an accepted constraint of zero-server architecture.

---

### 6. Consent Management & Privacy Compliance (GDPR, CCPA, GPP, COPPA, ATT)

#### Implementation Review
Consent is managed across [`IabStorage`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit44_gemini/packages/ad_sdk/lib/src/core/iab_storage.dart), [`UmpConsent`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit44_gemini/packages/ad_sdk/lib/src/core/ump_consent.dart), [`AdConsent`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit44_gemini/packages/ad_sdk/lib/src/core/ad_consent.dart), and [`AttConsent`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit44_gemini/packages/ad_sdk/lib/src/core/att_consent.dart).

1. **Storage Extraction**:
   - `IabStorage` accurately resolves platform-native preference storage: on Android, it reads the default `<packageName>_preferences` file via `SharedPreferencesAsyncAndroidOptions`; on iOS, it reads `UserDefaults` without prefixes.
   - Extracts `IABTCF_TCString`, `IABTCF_gdprApplies`, `IABTCF_PurposeConsents`, `IABUSPrivacy_String` (CCPA), `IABGPP_HDR_GppString`, and `IABGPP_7_String` (GPP Section 7 US National).
2. **Provider Propagation**:
   - **GDPR / EEA**: AdMob receives per-request `nonPersonalizedAds: !hasUserConsent` (`npa=1`). AppLovin MAX receives `AppLovinMAX.setHasUserConsent(bool)` and automatically reads TCF strings natively from platform storage.
   - **CCPA / US Privacy**: AdMob receives `AdRequest.extras: {'rdp': '1'}` (Restricted Data Processing). AppLovin MAX receives `AppLovinMAX.setDoNotSell(bool)`.
   - **COPPA / TFUA**: AdMob sets `tagForChildDirectedTreatment: yes/no` and `tagForUnderAgeOfConsent: yes/unspecified`. AppLovin MAX 4.x has no COPPA runtime API; `AppLovinAdapter.initialize` aborts and hard-disables all AppLovin ads if `isAgeRestrictedUser` is true (fails closed safely).
   - **Consent Withdrawal**: Mid-session consent withdrawal triggers `discardCachedFullscreenAds()` in AdMob and `_discardIfConsentStale()` in AppLovin, preventing ads loaded under previous broader consent from being displayed.
   - **Apple ATT**: `requestAttIfNeeded()` is sequenced before UMP consent during bootstrap, complying with Apple App Store Review Guidelines.

---

### 7. AdMob & AppLovin Policy Compliance & Anti-Fraud

#### Policy Adherence Checklist
- **Accidental Click & Overlay Protection**:
  - `InlineAdVisibility`: When any fullscreen ad (App Open, Interstitial, Rewarded) is shown, inline banner and MREC ads are hidden (AdMob) and their auto-refresh is paused (AppLovin MAX), preventing ads displaying under fullscreen dialogs or registering background impressions.
  - `umpFormOnScreen`, `AdLoadingDialog.isShowing`, `AdScreenRouteLogger.isDialogOnTop`, and `customOverlayOnScreen` all feed `AdManager._fullscreenBusyReason`, preventing App Open ads from firing on top of CMP consent forms, alert dialogs, or onboarding flows.
- **Rewarded Interstitial Mandate**:
  - Google AdMob policy strictly mandates an introductory announcement screen with an opt-out choice before showing a Rewarded Interstitial.
  - `AdScreenState.showRewardedInterstitialAd` includes a built-in Cupertino disclosure dialog enabled by default (`showDisclosure: true`).
- **Fraud Prevention & Frequency Capping**:
  - [`AdSafetyConfig`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit44_gemini/packages/ad_sdk/lib/src/core/ad_safety_config.dart) enforces:
    - Minimum intervals between fullscreen ads (default 60s).
    - Session caps (default 6), hourly caps (default 3), daily caps (default 5).
    - Per-placement daily caps (`PlacementRegistry`).
    - High CTR fraud threshold detection (`suspiciousCtrThreshold`, default 30% fullscreen CTR) and click-per-minute limits (default 3 clicks/min).

---

## Example App & Test Suite Review

- **Example App (`packages/ad_sdk/example/lib/main.dart`)**:
  - 4,986 lines providing comprehensive interactive test harnesses for Banner, MREC, Native, Interstitial, Rewarded, Rewarded Interstitial, App Open, VIP code redemption, Consent simulation, Compliance reports, and Diagnostics.
  - Accurately demonstrates the recommended bootstrap sequence: `requestAtt()` -> `requestUmpConsent()` -> `AdManager().initialize()`.
- **Test Suite (`packages/ad_sdk/test/`)**:
  - Over 130 comprehensive unit and integration test files covering adapter contracts, race conditions, stale callback quarantine, crash guard recovery, and edge-case clock tampering.

---

## Detailed Findings Table

| ID | Severity | Category | File & Line Citation | Description & Failure Scenario | Recommendation / Mitigation |
|---|---|---|---|---|---|
| **F-01** | **MINOR** | Functional / Mixed Audience | [`applovin_adapter.dart:733-743`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit44_gemini/packages/ad_sdk/lib/src/adapters/applovin_adapter.dart#L733-L743) | **AppLovin complete session disable for COPPA child users.** When `isAgeRestrictedUser == true`, AppLovin MAX 4.x has no COPPA tagging API. The adapter aborts initialization and hard-disables all AppLovin ad surfaces for the entire session. In a mixed-audience app configured with `AdProvider.appLovin`, child users receive 0% ad fill. | Document that mixed-audience apps requiring COPPA compliance should select `AdProvider.admob`. |
| **F-02** | **MINOR** | VIP / Security | [`_first_install_guard.dart:149-156`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit44_gemini/packages/ad_sdk/lib/src/vip/_first_install_guard.dart#L149-L156) | **Android First-Install Grace Reset on App Storage Clearing.** Android anti-reinstall relies on Auto Backup restoring `FlutterSharedPreferences.xml`. If a user manually clears app data in Android OS Settings or reinstalls without cloud sync, the 24h grace resets. | Accepted client-side trade-off. Host apps requiring server-level trial locking should implement backend authentication. |
| **F-03** | **MINOR** | VIP / Cryptography | [`signed_vip_key.dart:118-121`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit44_gemini/packages/ad_sdk/lib/src/vip/signed_vip_key.dart#L118-L121) | **Cross-Device VIP Code Replay.** Offline Ed25519 verification prevents single-device reuse via local ledger, but cannot prevent sharing a valid unexpired code across multiple physical devices without a central database. | Use AVP2 codes with short `expiresAtEpochSeconds` and distribute signed CRLs via `VipRevocationProvider` if code leaking is detected. |
| **F-04** | **NIT** | Compliance / Operational | [`ad_consent.dart:162-170`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit44_gemini/packages/ad_sdk/lib/src/core/ad_consent.dart#L162-L170) | **Mid-Session COPPA Update on AppLovin.** If consent changes to `isAgeRestrictedUser: true` mid-session after AppLovin initialized, AppLovin cannot apply child-directed flags dynamically. | Host apps updating child status mid-session should call `AdManager.destroy()` followed by re-initialization. |
| **F-05** | **NIT** | UX / Buffer Dialog | [`ad_loading_dialog.dart:82-93`](file:///Users/LoiTP/.claude/jobs/a04f6215/tmp/audit44_gemini/packages/ad_sdk/lib/src/widget/ad_loading_dialog.dart#L82-L93) | **Modal Buffer Blocking UI.** `AdLoadingDialog.showAdBuffer` renders a modal DialogRoute during `loadingBufferMs` (default 1000ms). | Ensure `loadingBufferMs` is kept reasonable (500–1000ms) to avoid perceived UI freezes. |

---

## Final Recommendation & Integration Checklist for Host Apps

To adopt `applovin_admob_sdk` (v2.9.23) into a production app, verify the following configuration:

1. **Android Manifest (`AndroidManifest.xml`)**:
   - Ensure Google AdMob Application ID metadata is registered:
     ```xml
     <meta-data
         android:name="com.google.android.gms.ads.APPLICATION_ID"
         android:value="ca-app-pub-xxxxxxxxxxxxxxxx~yyyyyyyyyy"/>
     ```
   - If using AppLovin MAX, configure AppLovin SDK key and ensure `android:allowBackup="true"` is set.
2. **iOS Info.plist (`ios/Runner/Info.plist`)**:
   - Configure `GADApplicationIdentifier` and SKAdNetwork identifier list (`SKAdNetworkItems`).
   - Configure `NSUserTrackingUsageDescription` for Apple ATT prompt.
3. **App Bootstrap**:
   - Utilize `bootstrap(AdBootstrapOptions(...))` or `AdReadinessSplashController` in your splash screen for optimal ATT -> UMP -> AdManager sequencing.
