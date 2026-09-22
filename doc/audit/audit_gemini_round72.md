# Independent Security & Quality Audit Report — Round 72

**Package:** `applovin_admob_sdk` (v3.1.0)  
**Target Repository:** `/Users/LoiTP/StudioProjects/roy/applovin_admob_sdk`  
**Auditor:** Independent Security & Quality Auditor  
**Date:** September 22, 2026  
**Methodology:** End-to-end static code analysis across `packages/ad_sdk/lib/**`, `packages/ad_sdk/example/lib/**`, `pubspec.yaml`, `pubspec.lock`, and native platform integration files (`android/`, `ios/`).

---

## 1. Executive Verdict

**Verdict: SAFE TO USE IN PRODUCTION (WITH CONDITIONS).**

The `applovin_admob_sdk` codebase demonstrates an exceptionally high standard of defensive engineering and domain maturity. The dual-provider mediation abstraction (Google AdMob via `google_mobile_ads` 7.0.0 and AppLovin MAX via `applovin_max` 4.6.4) is decoupled cleanly with strict widget instance-keyed isolation (`bannerSlot`, `mrecSlot`, `nativeSlot`), eliminating historical singleton collisions. Offline resilience is robust, featuring fail-fast gates, comprehensive 30-second load watchdogs (`armLoadWatchdog`), and zone-guarded reconnect refill pipelines. Privacy management across GDPR/TCF, CCPA/US Privacy, GPP, COPPA, and iOS ATT is properly wired with pre-init ordering and cache invalidation upon consent revocation. The clock-tamper resistance in `VipManager` (dual-clock validation against monotonic anchors and high-water marks) prevents both rollback and forward-jump exploitation. 

Production deployment is approved **subject to two conditions**:
1. Patching residual `@visibleForTesting` test seams in `AdManager` and `ConsentManager` that lack runtime release-mode guards (`_testSeamsBlocked`).
2. Acknowledging the architectural boundary of offline VIP key distribution: without a central claim server or device hardware binding, valid `AVP2` codes can be shared and redeemed across multiple distinct physical devices during their validity window.

---

## 2. Critical Special Investigation: Ad Fraud & Covert Ad Injection

**EXPLICIT CONCLUSION: NO EVIDENCE FOUND.**

An adversarial, end-to-end investigation was conducted across the entire repository to evaluate suspicions of covert ad injection, third-party network hijacking, programmatic click fraud, or revenue skimming. **No evidence of malicious, fraudulent, or undisclosed behavior was found.**

### Detailed Investigation Findings:

1. **Network Endpoints & External Communication**:
   - Every string literal, URL, domain, IP address, and Base64 blob across `lib/` and `example/lib/` was cataloged.
   - The only network endpoints contacted originate strictly from the declared underlying official SDKs:
     - **Google Mobile Ads (AdMob)** and **Google User Messaging Platform (UMP)** (`googleads.g.doubleclick.net`, `pagead2.googlesyndication.com`, `fundingchoicesmessages.google.com`).
     - **AppLovin MAX SDK** (`applovin.com`, `applvn.com`).
   - Grep searches across all Dart code for `HttpClient`, `dart:io` sockets, `http.Client`, and WebSocket APIs confirmed that `packages/ad_sdk/lib` performs **zero direct network requests**. Network I/O is delegated exclusively to the official native platform plugins. The only `dart:io` import in the package is `show Platform` for platform detection.
2. **Hidden Views & Off-Screen Ad Rendering**:
   - All uses of `SizedBox.shrink()`, `Opacity`, and layout bounds were audited (`packages/ad_sdk/lib/src/widget/banner_ad_widget.dart:756-762`, `packages/ad_sdk/lib/src/widget/mrec_ad_widget.dart:426-432`, `packages/ad_sdk/lib/src/widget/native_ad_widget.dart:414-420`).
   - `SizedBox.shrink()` is employed strictly when an ad surface is inactive: when VIP status is active, when consent is not granted, prior to initialization, or when a load error occurs.
   - When ads are rendered, they use full-sized, standard containers: `_BannerContainer` (320x50 adaptive), `_MrecContainer` (300x250), and `NativeAdWidget` (standard Google/AppLovin templates). No 1x1, transparent, or off-screen rendering tricks exist.
3. **Synthetic Clicks & Programmatic Dispatch**:
   - Zero occurrences of synthetic input dispatching (`GestureBinding`, `PointerEvent`, `PointerDownEvent`, `PointerUpEvent`, or automated element tapping) exist in `packages/ad_sdk/lib`.
   - Ad interaction events (`onClicked`, `onImpression`) are strictly incoming observer callbacks emitted by the native SDKs.
4. **Ad Auto-Refresh Compliance**:
   - The SDK does not implement custom, unmetered banner reload timers.
   - For AppLovin, `autoRefresh` is governed by the native `MaxAdView` widget properties (`packages/ad_sdk/lib/src/widget/banner_ad_widget.dart:838`). When a route is paused, hidden via bottom-nav tabs (`VisibilityDetector`), or occluded by a fullscreen ad, `autoRefreshEnabled` is explicitly flipped to `false` (`packages/ad_sdk/lib/src/adapters/applovin_adapter.dart:2701, 2710`).
   - For AdMob, banner refresh is controlled server-side via the AdMob console (minimum 30s policy).
5. **Dynamic Code Loading & Reflection**:
   - Zero occurrences of `DexClassLoader`, `PathClassLoader`, `Class.forName`, `dart:mirrors`, `Function.apply`, or runtime code evaluation.
6. **Dependency & Manifest Verification**:
   - `packages/ad_sdk/pubspec.lock` and `packages/ad_sdk/example/pubspec.lock` resolve all hosted dependencies exclusively to `https://pub.dev`. No Git dependencies, path overrides, or unofficial forks are present.
   - Native manifests (`AndroidManifest.xml`, `build.gradle.kts`, `Podfile`, `Podfile.lock`) contain only official Google Mobile Ads and AppLovin MAX dependencies; no undisclosed ad networks or telemetry SDKs exist.
7. **Telemetry & Data Exfiltration**:
   - Compliance logging classes (`AdEventLog`, `ConsentProvenanceJournal`, `IncidentRecorder`, `BypassAuditTrail`, `RevenueIntegrityLedger`) write exclusively to local on-device `SharedPreferencesAsync` storage for on-demand debugging and compliance export. Zero telemetry is forwarded to third parties.

---

## 3. Findings Table

| Severity | File : Line | Summary | Why It Matters | Suggested Fix / Options |
| :--- | :--- | :--- | :--- | :--- |
| **MAJOR** | [`ad_manager.dart:1550, 3595`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/core/ad_manager.dart#L1550) <br> [`ad_manager.dart:1642, 3842`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/core/ad_manager.dart#L1642) <br> [`ad_manager.dart:1993, 4655`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/core/ad_manager.dart#L1993) <br> [`ad_manager.dart:2034`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/core/ad_manager.dart#L2034) <br> [`ad_manager.dart:2092`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/core/ad_manager.dart#L2092) <br> [`ad_manager.dart:6227, 6246`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/core/ad_manager.dart#L6227) <br> [`consent_manager.dart:295, 316`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/consent/consent_manager.dart#L295) <br> [`consent_manager.dart:187, 372`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/consent/consent_manager.dart#L187) | Residual `@visibleForTesting` test seams lack runtime release-mode guards (`_testSeamsBlocked`). | In Round 68, runtime guards (`_testSeamsBlocked`) were added to critical test seams because `@visibleForTesting` is an analyzer annotation that does not prevent invocation in compiled release builds. However, several test hooks were missed: <br>1. `debugFirstInstallGuardFactory` (`ad_manager.dart:3595`): Any code in the isolate can replace `FirstInstallGuard` in release mode, bypassing the trial anti-uninstall check. <br>2. `debugForceAutoUmpError` (`ad_manager.dart:3842, 5508, 5783`): Throws an artificial exception in release mode if non-null, breaking UMP consent flows in production. <br>3. `debugInitRetryDelays` (`ad_manager.dart:4655`) & `debugReconnectDebounce` (`ad_manager.dart:2092`): Can mutate production retry/debounce timing without release checks. <br>4. `debugBumpInitGen()` (`ad_manager.dart:2034`): Unconditionally increments `_initGen`, invalidating in-flight initializations. <br>5. `ConsentManager.debugPersistDelay` (`consent_manager.dart:316`) & `debugApplyBarrier` (`consent_manager.dart:372`): Can hang consent persistence and provider consent updates indefinitely in release builds. | **Option A (Comprehensive Call-Site Check - Recommended):** At every read and assignment site, gate execution with `if (_testSeamsBlocked)` or `if (kReleaseMode || debugSimulateReleaseModeForTestSeams)` and fall back to standard production behavior. <br>*Pros:* Minimal architectural change; guarantees release safety even if static fields are manipulated. <br>*Cons:* Requires auditing future seams manually. <br><br>**Option B (Setter Encapsulation):** Convert all public mutable static fields (`debugFirstInstallGuardFactory`, `debugPersistDelay`, etc.) into private fields exposed only via setters that reject assignments when `_testSeamsBlocked` is true. <br>*Pros:* Centralized gatekeeping at the assignment boundary. <br>*Cons:* Slightly more boilerplate for test utilities. |
| **MAJOR** | [`signed_vip_key.dart:88-120`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/vip/signed_vip_key.dart#L88-L120) <br> [`vip_manager.dart:1252-1265`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/vip/vip_manager.dart#L1252-L1265) | Cross-device replay of offline-signed VIP keys (`AVP2`). | An `AVP2` key payload consists of `<seconds>|<keyId>|<expiresAtEpochSeconds>|<bundleId>`. Local verification uses asymmetric Ed25519 cryptography. Per-device single-use is enforced via local `AdPreferences` and the iOS Keychain `RedeemedKeyLedger`. However, because verification is strictly local with zero backend coordination, **any valid signed key leaked or shared publicly can be redeemed once by an unlimited number of different physical devices** until its `expiresAt` deadline or until a CRL update is distributed. | **Option A (Accepted Zero-Backend Policy - Status Quo):** Keep key redemption validity windows short (e.g. `tool/vip_mint.dart --valid-days 2`) and maintain active CRL distributions via `VipRevocationProvider`. <br>*Pros:* Requires zero server infrastructure, preserves pure offline capability. <br>*Cons:* Leaked keys are vulnerable to widespread multi-device farming during the active validity window. <br><br>**Option B (Device-Bound Offline Minting - AVP3):** Incorporate a cryptographic hash of a client-side identifier (e.g. `AdvertisingId`, IDFV, or an install UUID) into the signed payload: `<seconds>|<keyId>|<expiresAt>|<bundleId>|<deviceHash>`. The host application displays the user's device hash in the redeem screen; the minting tool requires `--device <hash>`. <br>*Pros:* Eliminates cross-device key sharing entirely while remaining 100% offline. <br>*Cons:* Cannot sell generic pre-printed retail gift cards; requires users to submit their device hash prior to code generation. <br><br>**Option C (Hybrid Backend Claim API):** Introduce an optional online claim check (e.g. lightweight Cloudflare Worker or serverless database) that marks `keyId` as claimed globally, falling back to offline mode only if explicitly enabled. <br>*Pros:* True global single-use enforcement. <br>*Cons:* Introduces a backend dependency and hosting overhead. |
| **MINOR** | [`signed_vip_key.dart:135, 210-212`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/vip/signed_vip_key.dart#L135) | `verifySignedVipKey` unconditionally accepts legacy `AVP1` format without enforcement of minimum key version. | `verifySignedVipKey` accepts both `AVP1` (`<seconds>|<keyId>`) and `AVP2` (`<seconds>|<keyId>|<expiresAt>|<bundleId>`). Unlike `AVP2`, `AVP1` keys never expire and cannot be bound to a specific app bundle. There is currently no parameter or configuration flag (e.g. `allowV1: false`) allowing a publisher to enforce that only time-limited and app-bound `AVP2` keys are accepted. If an attacker acquires an `AVP1` key, it remains valid forever across all apps sharing that public key. | **Option A:** Add an optional `bool allowV1 = true` parameter to `verifySignedVipKey`, `AdConfig`, and `VipManager.redeemSignedKey`, defaulting to `true` for backward compatibility but allowing publishers to set `false`. <br>**Option B:** Introduce a `SignedVipKeyVersion minVersion` configuration parameter. |
| **MINOR** | [`_first_install_guard.dart:27-58, 137-138`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/vip/_first_install_guard.dart#L27-L58) | Android first-install grace trial reset on reinstall when Google Auto Backup is disabled. | On iOS, `FirstInstallGuard` persists the trial grant token in Keychain (`kSecAttrAccessibleAfterFirstUnlock`), which survives app deletion. On Android, `FirstInstallGuard` performs no independent check and relies entirely on Android Auto Backup restoring `FlutterSharedPreferences.xml`. If a user uninstalls on an Android device where Auto Backup is disabled, unsynced, or if app data is cleared prior to uninstall, the 1-day grace is granted again upon reinstall. | **Option A (Status Quo):** Accept as a documented trade-off. Reinstalling an app daily for a 24-hour trial represents significant user friction for minimal gain. <br>**Option B:** Integrate an optional Play Install Referrer check or device-rooted attestation to verify install timestamps. |
| **NIT** | [`ad_manager.dart:1633, 3832`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/packages/ad_sdk/lib/src/core/ad_manager.dart#L1633) | `debugLastAutoUmpParams` diagnostic field is populated unconditionally in release mode. | In `AdManager.initialize()`, `debugLastAutoUmpParams` is assigned during the auto-UMP branch even when running in release mode. While harmless, it retains unnecessary Map allocations. | Wrap the assignment with `if (!_testSeamsBlocked) debugLastAutoUmpParams = ...`. |

---

## 4. Systems Verified and Found Genuinely Robust

The following subsystems were subjected to adversarial testing and verified to be compliant, robust, and correctly implemented:

1. **Dual-Provider Abstraction (`AdProviderAdapter`)**:
   - `AdMobAdapter` and `AppLovinAdapter` adhere strictly to the `AdProviderAdapter` contract without leaking provider-specific behaviors into the shared API surface.
   - Separate widget instances of `BannerAdWidget`, `MrecAdWidget`, and `NativeAdWidget` maintain isolated slot state via object-keyed registries (`bannerSlot(key)`, `mrecSlot(key)`, `nativeSlot(key)`), preventing cross-widget clobbering.
   - Rewarded Interstitial format (`T89`), supported only by AdMob, gracefully degrades to documented no-op stubs in `AppLovinAdapter` without throwing or stalling callers.
2. **Offline & Network Flakiness Resilience**:
   - Calling `load*` or `show*` while offline (`!isConnected`) fails fast, emitting `AdSkipEvent(reason: 'no_network')` and safely invoking callbacks with `false` or `RewardResult.skipped`.
   - Every load pipeline is defended by a 30-second watchdog timer (`armLoadWatchdog` in `packages/ad_sdk/lib/src/state/ad_slot.dart:253`), ensuring ad slots never remain stuck in `loading` state if the native bridge drops callbacks.
   - Network restoration transitions (`_onConnectivityChanged` in `ad_manager.dart:9161`) are debounced against connection flapping and wrapped in `runZonedGuarded` to prevent unhandled asynchronous platform-channel exceptions from terminating the isolate.
3. **Widget Lifecycle & Memory Leak Prevention**:
   - `BannerAdWidget`, `MrecAdWidget`, and `NativeAdWidget` unregister from `adRouteObserver`, cancel debounce timers, detach controllers, and dispose native ad objects (`AdMobAdapter._bannerAdsByKey.remove(key)?.dispose()`, `AppLovinAdapter.destroyWidgetAdView`) on `dispose()`.
   - Neither `AdManager` nor route observers retain static references to `BuildContext` or `Element`. `AdReadinessSplashController` nulls its context reference upon navigation or disposal.
   - `VisibilityDetector` accurately tracks off-screen or tab-swapped widgets (such as `IndexedStack` or `PageView`), disabling AppLovin auto-refresh and concealing AdMob `AdWidget` views to prevent invisible ad impressions.
4. **Time & Clock-Tamper Resistance**:
   - `VipManager._effectiveNow()` combines a monotonic `Stopwatch` anchor (`_sessionClockStopwatch`) with a persistent high-water mark (`vipMaxObservedClockMs`), neutralizing device clock rollback attacks.
   - Forward clock tampering is defeated by `_isLive` (`packages/ad_sdk/lib/src/vip/vip_manager.dart:868-873`), which requires that a grant must have started according to the *raw* device clock while evaluating expiration against the high-water mark. Setting the clock forward, redeeming, and rewinding leaves the grant inactive until the forward date, at which point the high-water mark declares it expired.
5. **Consent & Privacy Compliance (GDPR, CCPA, COPPA, GPP, ATT)**:
   - `IabStorage` accurately accesses default native preferences (`<packageName>_preferences` on Android and standard `NSUserDefaults` on iOS), correctly parsing `IABTCF_TCString`, `IABUSPrivacy_String`, and multi-segment GPP strings.
   - Privacy parameters are passed to AppLovin MAX and AdMob **prior to SDK initialization** (`AppLovinAdapter.initialize:853`, `AdMobAdapter.updateRequestConfiguration:471`).
   - AdMob requests attach `nonPersonalizedAds: true` (`npa=1`) whenever consent is absent or withdrawn.
   - Revoking consent mid-session triggers `discardCachedFullscreenAds()`, immediately disposing cached ready ads and bumping `consentEpoch` so in-flight responses requested under stale consent are discarded upon receipt.
6. **Ad Program Policy Compliance**:
   - Accidental clicks are mitigated by mandatory visual labeling (clear yellow "Ad" badges on banner, MREC, and native containers) and a pre-display buffer dialog (`AdLoadingDialog.showAdBuffer`).
   - Ad stacking is prevented by the process-wide mutex `_fullscreenBusyReason` (`ad_manager.dart:2321`), which blocks fullscreen ad presentation if another ad is showing, if a modal/route is on top, if a UMP consent form is displayed, or if teardown is in flight.
   - App Open ads on resume strictly suppress impressions when the app is foregrounded as a result of an ad click (`consumeBackgroundedFromAdClick`), complying with Google placement rules.
