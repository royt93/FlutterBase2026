# Round 45 independent adversarial audit — `applovin_admob_sdk`

Date: 2026-09-18  
Scope: `packages/ad_sdk` (Flutter, Android + iOS, AdMob + AppLovin MAX)  
Method: static source-level runtime tracing. Per the audit constraint, I did not run Git or any command that could generate/update package artifacts, and I did not run the test suite.

## Executive summary

I found one **MAJOR** consent defect that defeats the principal round-44 fix on the ordinary AppLovin cold-start path, plus three lower-severity correctness/policy issues. The MAJOR issue is release-relevant: for a returning EEA user, `AppLovinAdapter.initialize()` still sends MAX a purpose-only `hasUserConsent` boolean before MAX initializes, even when UMP has already written a real TCF string. That can override the TCF vendor-specific decision the code explicitly intends MAX to read.

| Severity | Finding |
|---|---|
| **MAJOR** | R45-01 — AppLovin pre-init consent still overrides UMP/TCF vendor consent |
| **MINOR** | R45-02 — a late AppLovin native click is counted/emitted after its widget instance was disposed |
| **MINOR** | R45-03 — the common rewarded-interstitial API silently no-ops on AppLovin |
| **MINOR** | R45-04 — public AdMob test IDs remain usable in release; validation is warning-only |

I did **not** re-file the explicitly accepted limitations in `CLAUDE.md`/README as new defects: Android data-clear/reinstall can reset trial and redemption state; offline codes cannot have global cross-device replay prevention; AppLovin consent setters are fire-and-forget; AppLovin lacks an ad-freshness API; IndexedStack and unobservable custom/nested overlays require host wiring; and the documented first-install AppLovin/COPPA gap remains a product constraint.

## Findings

### R45-01 — AppLovin pre-init consent still overrides UMP/TCF vendor consent

**Severity: MAJOR — must fix before production AppLovin traffic in EEA/UK**

**Locations:**

- `lib/src/adapters/applovin_adapter.dart:809-829`
- `lib/src/adapters/applovin_adapter.dart:847-850`
- `lib/src/core/ad_manager.dart:3412-3450`
- `lib/src/core/ad_manager.dart:3596-3637`
- `lib/src/core/ad_manager.dart:3827-3844`
- `lib/src/core/ad_consent.dart:143-169`
- `lib/src/core/iab_storage.dart:529-540`
- `lib/src/core/iab_storage.dart:580-606`
- `test/r44_applovin_tcf_gate_test.dart:62-75`
- `test/applovin_adapter_test.dart:232-251`

**What is wrong:** round 44 correctly changed `applyConsentToProviders()` to read `IABTCF_TCString` and skip `AppLovinMAX.setHasUserConsent(...)` when a real CMP string exists (`ad_consent.dart:153-169`). However, that safeguard covers only the later provider-apply funnel. Initialization follows another path:

1. `AdManager.initialize()` bootstraps persisted consent (`ad_manager.dart:3412-3450`).
2. It passes that `AdConsent` into `adapter.initialize(...)` (`ad_manager.dart:3596-3637`).
3. `AppLovinAdapter.initialize()` unconditionally calls `_bridge.setHasUserConsent(consent.hasUserConsent)` before `_bridge.initialize(...)` (`applovin_adapter.dart:809-829,847-850`). It never checks for `IABTCF_TCString`.
4. Only after MAX has initialized does the manager call the round-44-aware `applyToProviders()` (`ad_manager.dart:3827-3844`). That call sees the TC string and deliberately does nothing, so it cannot undo the pre-init explicit override.

The boolean is not vendor-aware. `tcfAllowsPersonalisedAds()` deliberately evaluates purposes 1/3/4 only and does not parse `IABTCF_VendorConsents` (`iab_storage.dart:529-540,580-606`). The round-44 regression test exercises only `applyConsentToProviders()` (`r44_applovin_tcf_gate_test.dart:62-75`), while the adapter test explicitly requires the unconditional pre-init setter (`applovin_adapter_test.dart:232-251`). The two tests therefore lock in contradictory behavior rather than covering the full cold-start call chain.

**Concrete failure scenario:** a returning EEA user allowed purposes 1/3/4 in UMP but denied AppLovin as a vendor. The SDK persists `hasUserConsent=true`. At the next AppLovin launch, the adapter calls `setHasUserConsent(true)` immediately before MAX init, overriding or short-circuiting the vendor-specific result MAX should derive from UMP's TCF storage. The later round-44 guard skips its own setter and leaves the wrong explicit value in force. AppLovin may request/serve personalized ads without vendor consent, creating GDPR/TCF and platform-policy exposure.

**Required correction:** make the *pre-init* AppLovin path use the same TC-string gate as `applyConsentToProviders()`. The check must complete before `_bridge.initialize()`. Preserve unconditional pre-init `setDoNotSell`, and retain `setHasUserConsent` only for the documented no-CMP/no-TC-string path. Add an end-to-end initialization test with a TC string present and assert that the bridge receives no `setHasUserConsent` before `initialize`.

### R45-02 — a late AppLovin native click is counted/emitted after disposal

**Severity: MINOR**

**Locations:**

- `lib/src/widget/native_ad_widget.dart:627-640`
- `lib/src/widget/native_ad_widget.dart:649-675`
- `lib/src/widget/native_ad_widget.dart:374-389`
- `lib/src/adapters/applovin_adapter.dart:461-493`
- `lib/src/adapters/applovin_adapter.dart:534-571`

**What is wrong:** the native revenue callback correctly resolves the current adapter and, when it is AppLovin, rejects a callback whose `instanceKey` has been tombstoned (`native_ad_widget.dart:649-660`). The click callback does not mirror that protection. It calls `AdSafetyConfig.recordAdClick()` *before even checking whether an adapter is live*, then emits through whatever adapter is current, with no `isNativeInstanceDisposed(instanceKey)` check (`native_ad_widget.dart:627-640`). Widget disposal removes listeners/timers and tombstones the instance (`native_ad_widget.dart:374-389`; `applovin_adapter.dart:534-571`), but it cannot cancel a native platform callback already queued.

There is also no session/provider binding in the callback: it looks up `AdManager().adapter` at delivery time. Thus a sufficiently late callback can target a newly initialized adapter after a destroy/provider switch.

**Concrete failure scenario:** the user taps an AppLovin native ad while navigation immediately removes its `NativeAdWidget`. The queued click arrives after `dispose()`. The SDK records a click against the global invalid-traffic/click cap even though that instance is gone, and, if the manager has already reinitialized, may emit an AppLovin-tagged click into the new session. Near the click threshold this can falsely suppress subsequent ads and corrupt analytics/safety attribution.

**Required correction:** capture/bind the originating adapter or session revision and reject mismatches. At minimum, resolve the adapter first, require `adapter is AppLovinAdapter`, and return when `isNativeInstanceDisposed(instanceKey)` before calling `recordAdClick()` or the event sink. Add the same disposed-instance regression test already represented conceptually by the revenue callback.

### R45-03 — rewarded-interstitial silently no-ops on AppLovin through a provider-neutral API

**Severity: MINOR (documented limitation, but weak runtime contract)**

**Locations:**

- `lib/src/core/ad_provider_adapter.dart:307-323`
- `lib/src/adapters/applovin_adapter.dart:2050-2063`
- `lib/src/core/ad_manager.dart:7971-8023`
- `lib/src/core/ad_manager.dart:8840-8849`

**What is wrong:** the interface exposes rewarded-interstitial uniformly, but AppLovin's load implementation is an empty async body and show merely reports `shown=false` (`applovin_adapter.dart:2050-2063`). The manager still sends AppLovin through its ordinary load/coalescing/watchdog flow and the periodic refill repeatedly invokes the no-op (`ad_manager.dart:7971-8023,8840-8849`). There is no explicit `unsupported_provider` skip/event or configuration-time rejection.

This is disclosed in comments and AppLovin genuinely has no equivalent format (`ad_provider_adapter.dart:307-323`), so the missing format is not itself a provider bug. The defect is the silent provider-neutral runtime behavior.

**Concrete failure scenario:** a host changes only `AdConfig.provider` from AdMob to AppLovin while retaining a natural-transition rewarded-interstitial placement. Loads appear to complete as `Future<void>` but the slot never becomes ready; shows report false with no diagnostic distinction between “not yet filled” and “unsupported.” Monetization and reward UX disappear silently.

**Required correction:** fail fast or emit an explicit unsupported-provider skip/result before invoking the adapter. Ideally expose provider capability metadata so a host can disable the placement deterministically.

### R45-04 — public AdMob test IDs remain usable in release; validation is warning-only

**Severity: MINOR (documented release footgun)**

**Locations:**

- `lib/src/core/ad_manager.dart:285-310`
- `lib/src/core/ad_manager.dart:3190-3197`
- `README.md:601-608`
- `README.md:957-968`

**What is wrong:** all seven AdMob formats are now detected correctly, but detection produces only a log plus `assert(false, ...)` (`ad_manager.dart:285-310,3190-3197`). Assertions are stripped from normal release builds and initialization proceeds. The primary README sample contains Google's public test IDs (`README.md:601-608`), and the documentation explicitly says the checks never block (`README.md:957-968`).

**Concrete failure scenario:** an integrator copies the sample, switches the provider to AdMob, and overlooks release logs. A store build initializes and serves public test inventory, earning no revenue and risking AdMob enforcement. This is reachable release behavior, not dead example code.

**Required correction:** provide an opt-in/opt-out release enforcement switch with a safe default, or reject public test IDs in release unless the host explicitly acknowledges them. At minimum, make initialization failure observable to the host rather than relying on production logs.

## 1. Dual-provider and platform correctness

### Format matrix

| Format | AdMob | AppLovin | Android/iOS conclusion |
|---|---|---|---|
| Banner | Real `BannerAd`, keyed per widget | `MaxAdView`/preloaded widget view, keyed per widget | Implemented on both mobile platforms through their plugins |
| MREC | `BannerAd` with medium rectangle size | MAX MREC widget view | Implemented on both |
| Native | Real `NativeAd` + template | self-contained `MaxNativeAdView` | Implemented on both; see R45-02 |
| App open | `AppOpenAd` | MAX app-open listener/load/show | Implemented on both |
| Interstitial | `InterstitialAd` | MAX interstitial | Implemented on both |
| Rewarded | `RewardedAd`, GMA SSV | MAX rewarded, `customData` SSV | Implemented on both |
| Rewarded interstitial | Real GMA format | Unsupported/no-op | Not equivalent; see R45-03 |

The production bridges are thin, unconditional plugin forwards: GMA implements all four fullscreen loaders (`gma_bridge.dart:117-223`) and AppLovin exposes app-open/interstitial/rewarded plus widget-view creation/destruction (`applovin_bridge.dart:48-114`). I found no Android-only or iOS-only ad format silently disabled. The only platform branch in the reviewed adapters is AppLovin's app-open lost-callback watchdog: iOS deliberately ignores the “foreground means hung” heuristic because MAX is presented as an in-app modal there, while Android uses it after a grace tick (`applovin_adapter.dart:1454-1493`). That is platform-specific handling, not a no-op.

## 2. Offline / no-network behavior

The SDK degrades to “app works, ads do not show” rather than crashing or blocking the host indefinitely:

- Native adapter initialization is bounded to 20 seconds (`ad_manager.dart:3611-3641`) and failed initialization receives bounded 5/15/30-second retries (`ad_manager.dart:1812-1842`).
- App-open, interstitial, rewarded, and rewarded-interstitial loads check connectivity and return without touching the adapter (`ad_manager.dart:6864-6917`, `7323-7357`, `7567-7602`, `7982-8017`). Inline widgets independently skip initialization offline; native does so at `native_ad_widget.dart:298-319`.
- The connectivity setup is itself capped at 20 seconds, subscription ownership is generation-guarded, and failure is caught (`ad_manager.dart:8680-8713`). Reconnect retries UMP when needed and refills ads (`ad_manager.dart:8724-8797`); a periodic refill is a backstop (`ad_manager.dart:8572-8667`, `8800-8849`).
- If the connectivity plugin is unavailable, the detector is optimistic and actual provider loads fail into normal backoff rather than permanently disabling ads (`ad_manager.dart:6842-6854`).
- An initial UMP network/platform failure keeps the gate closed on the auto-consent initialization path (`ad_manager.dart:3580-3591`) and retry logic runs on reconnect/backstop. This is legally conservative; the app remains usable without ads.

I found no unbounded provider-init wait, no offline crash path in the reviewed orchestration, and no ad requirement that blocks normal app navigation. Signed VIP redemption is deliberately rejected while offline; that is discussed below and is not caused by the ad network path.

## 3. Ad lifecycle, capping, and app-open modal safety

Fullscreen types use shared consent/VIP/daily/network gates and a shared fullscreen mutex. The mutex includes UMP/ATT native forms, host-declared custom overlays, teardown, every fullscreen slot, the loading dialog, and observed popup routes (`ad_manager.dart:2101-2150`). Resume app-open consumes the ad-click-return latch, observes the same busy gate, enforces recent-dismiss and resume frequency guards, and uses `bypassSafety:false` (`ad_manager.dart:7161-7258`, `7276-7313`). `showAppOpenAd()` rechecks consent and the full mutex at presentation (`ad_manager.dart:6999-7045`). Inline ads are hidden for the fullscreen duration (`ad_manager.dart:7103-7128`).

This satisfies integration contract point 7 for root-navigator popup routes and declared overlays. The remaining limitations are already explicit: nested-navigator bottom sheets must use `showAdSafeModalBottomSheet` (`ad_route_observer.dart:5-42`), and raw `OverlayEntry` users must bracket the overlay with `markCustomOverlayOnScreen` (`ad_route_observer.dart:45-68`). I did not reclassify those unobservable host UI states as SDK bugs.

AppLovin has no freshness API, so AdMob's one-hour cache checks are intentionally not reproducible on MAX. Safety/frequency checks are performed in the manager before shows; the public `bypassSafety` remains an intentionally documented splash-only footgun (`ad_manager.dart:6966-6987`). Native/MREC/banner loads are gated through the manager/widget plus adapter `canReload` defenses; provider-specific reload mechanics differ but the policy gates do not.

## 4. One-day trial

The default trial is 24 hours in release and 30 seconds in debug (`config/ad_config.dart:524-546`). It is granted once per install after the VIP store is loaded and stamped in preferences (`ad_manager.dart:3274-3371`).

Clock handling is substantially hardened:

- VIP times serialize as UTC instants, so timezone/DST changes do not move the entitlement (`vip_entry.dart:72-105`).
- Expiry uses a persisted maximum-observed wall-clock plus an in-session monotonic estimate (`vip_manager.dart:310-390`). Resume re-anchors the monotonic check because device sleep semantics differ from wall time (`vip_manager.dart:392-409`).
- A grant must also have started according to the raw clock, preventing a future-clock grant from becoming permanent after rollback (`vip_manager.dart:830-873`). Purging requires both effective and raw clocks to agree that expiry passed, so a corrected honest clock fault does not delete the row (`vip_manager.dart:875-919`).

The remaining tamper properties are the accepted offline design:

- iOS uses an uninstall-persistent Keychain marker (`_first_install_guard.dart:17-25,146-155,221-234`). A read error fails open; a five-second manager-level timeout specifically skips the grant for that launch (`ad_manager.dart:3294-3321`).
- Android has no durable class-level guard and relies on best-effort Auto Backup; clearing data or reinstalling without restored backup grants another day (`_first_install_guard.dart:27-57,137-155`; `config/ad_config.dart:538-543`). This is explicitly accepted in `CLAUDE.md`/source, not a newly discovered bypass.
- An honest forward clock fault while the app is closed can park the high-water mark in the future and temporarily suppress valid VIP. The code documents this fail-closed tradeoff (`vip_manager.dart:323-373`). Timezone changes alone are safe because persisted instants are UTC.

## 5. Offline/no-backend VIP code activation

The Ed25519 check is live and precedes entitlement grant:

- `verifySignedVipKey()` validates structure, decodes payload/signature, tries configured 32-byte public keys, and throws unless Ed25519 verifies (`signed_vip_key.dart:121-191`). Only then does it parse duration, expiry, key id, and AVP2 app binding (`signed_vip_key.dart:193-249`).
- `redeemSignedKey()` calls that verifier before CRL, replay ledger, or `addVip` (`vip_manager.dart:1339-1404`), checks the CRL and both per-install/in-flight replay state (`vip_manager.dart:1406-1429`), checks the durable ledger, grants, then burns the key only after persistence survived teardown (`vip_manager.dart:1431-1484`). I found no unsigned or parse-only grant path in this method.
- Stack behavior extends from the latest live expiry and clamps to `now + maxStackDuration`; non-stacking grants are clamped too (`vip_manager.dart:1066-1121`). The default cap is 90 days (`config/ad_config.dart:398-404,498-516`).

Replay guarantees are necessarily local. The same code can be used once on unlimited devices because there is no server claim (`vip_manager.dart:1246-1265`; `signed_vip_key.dart:115-120`). iOS mirrors redeemed key IDs to Keychain; Android's durable ledger is a no-op and relies on SharedPreferences/optional Auto Backup (`_redeemed_key_ledger.dart:9-25,79-99`). Thus Android app-data clear/reinstall can reset the one-time ledger. These are explicit accepted limitations.

One terminology caveat: signature verification is offline, but *redemption while the device is offline is intentionally refused*. `_waitForConnectivity()` polls for two seconds and returns an `offline` result before signature verification (`vip_manager.dart:1267-1304,1325-1337`). The source marks this as a deliberate product gate. Therefore this SDK is “no backend / locally verified,” but it does **not** support activation with no current network connection. If “offline activation” in the product requirement literally means airplane-mode redemption, the current implementation does not meet that requirement, even though this is not an accidental security defect.

## 6. Consent by jurisdiction and provider consistency

The built-in non-CMP dialog is gone. The default `autoRequestUmpConsent:true` runs UMP before adapter initialization (`config/ad_config.dart:553-560`; `ad_manager.dart:3452-3593`). UMP's `canRequestAds` controls the global load gate (`ad_manager.dart:5243-5267`). `obtained` is not incorrectly treated as personalized consent: purposes 1/3/4 are read from IAB storage and a refusal selects non-personalized ads (`ad_manager.dart:5273-5296`; `iab_storage.dart:580-606`). Inconclusive/offline UMP does not overwrite an earlier stored choice, while the ad-request gate follows UMP's cached answer (`ad_manager.dart:5297-5334`).

AdMob receives per-request `nonPersonalizedAds` and CCPA/US restricted-data-processing state (`admob_adapter.dart:638-646`; examples at `admob_adapter.dart:1173-1177,2393-2398`). The IAB reader targets Android's default `<package>_preferences` SharedPreferences file and prefix-free iOS `NSUserDefaults` access (`iab_storage.dart:13-40,123-166`). US privacy combines the legacy string and GPP national/California/state sections, with true-beats-false semantics and fail-closed read errors (`iab_storage.dart:250-343`).

The intended AppLovin model is correct in the post-init funnel: let native MAX read the same `IABTCF_*` keys UMP wrote and do not replace vendor consent with a coarse boolean (`ad_consent.dart:153-169`). R45-01 shows that the pre-init adapter path still diverges and makes the overall implementation non-compliant despite that intended design.

The iOS IAB storage path is documented in-source as not having been exercised on a physical device (`iab_storage.dart:39-41`). I cannot assert that it fails from static review, but production sign-off should include an iOS device test that compares raw `NSUserDefaults` values written by UMP with `AdManager.tcfConsentString` and MAX behavior.

## 7. AdMob/AppLovin policy review

- **COPPA/under-age:** AdMob applies `tagForChildDirectedTreatment` and TFUA before `MobileAds.initialize()` (`admob_adapter.dart:450-465`) and later consent applies the same axes (`ad_consent.dart:193-223`). AppLovin has no corresponding API, so the adapter refuses initialization when age restriction is already known (`applovin_adapter.dart:741-766`). The fresh-install “age not known until after MAX init” gap is explicitly documented in `README.md:2420-2421`; it remains unsuitable for an always-child-directed AppLovin app unless the host establishes age before initialization.
- **Density/placement/refresh:** fullscreen mutual exclusion and inline hiding are implemented. Banner/MREC widgets unsubscribe and dispose when routes go away; AppLovin refresh ownership is paused rather than pretending its inert `visible` flag is sufficient (`applovin_adapter.dart:250-260,315-327`). Bare IndexedStack and arbitrary overlays remain documented host responsibilities.
- **Mediation:** both provider bridges use the native SDK/plugin mediation mechanisms. No custom auction/waterfall manipulation bypass was found. AdMob paid events expose adapter response data; AppLovin uses its native callbacks.
- **Test traffic:** AppLovin test devices are registered only in debug (`applovin_adapter.dart:839-845`). AdMob's effective test-device list intentionally retains configured/QA hashes across consent changes, which affects only matching devices, but public test *unit IDs* are not blocked in release; see R45-04.
- **Auto-refresh:** native ads load once; AppLovin banner/MREC refresh ownership is paused while hidden/background/fullscreen. The documented IndexedStack blind spot can still refresh off-screen if the host ignores `active`/Visibility integration.

## 8. Memory/resource lifecycle review

I traced these concrete cleanup chains end to end:

1. **Banner:** `BannerAdWidget.dispose()` detaches its controller, debounce, consent listeners, route observer, and local notifiers, then calls the manager (`banner_ad_widget.dart:664-676`). The manager removes cooldown bookkeeping (`ad_manager.dart:2758-2761`). AdMob disposes the keyed `BannerAd`, removes registry/listenable state and route state (`admob_adapter.dart:230-240`). AppLovin removes/disposes registry and ad-view notifiers, removes route state, and destroys the native widget view with bounded detach retries (`applovin_adapter.dart:282-299,369-432`).
2. **MREC:** `MrecAdWidget.dispose()` removes controller/consent/route listeners and local notifiers (`mrec_ad_widget.dart:374-385`), the manager clears cooldown state (`ad_manager.dart:2809-2812`), AdMob disposes the keyed medium-rectangle object and registry bundle (`admob_adapter.dart:300-310`), and AppLovin disposes registry/ad-view notifiers and destroys the native widget view (`applovin_adapter.dart:352-367`).
3. **Native:** `NativeAdWidget.dispose()` detaches controller and consent/error listeners, cancels its retry timer, disposes the provider instance and local notifier (`native_ad_widget.dart:374-389`). The manager drops the keyed cooldown (`ad_manager.dart:2853-2856`). AdMob disposes its keyed `NativeAd` and bundle (`admob_adapter.dart:338-346`). AppLovin removes/disposes its bundle and tombstones the key so queued callbacks cannot recreate it (`applovin_adapter.dart:461-493,534-571`). R45-02 is the click callback's missing use of that tombstone, not a missing core disposal chain.
4. **Whole adapter/fullscreen:** manager teardown waits up to five seconds for showing fullscreen slots, detaches listeners, and bounds adapter disposal to two seconds (`ad_manager.dart:6692-6757,6759-6803`). AdMob marks itself disposed before releasing all fullscreen/inline native objects and pending callbacks (`admob_adapter.dart:480-534`), then disposes all slot/listenable registries (`admob_adapter.dart:536-618`). AppLovin synchronously marks registries disposed, cancels watchdog/quarantine/destroy timers, clears native listeners, destroys tracked widget views, resolves pending callbacks, and disposes slot/listenable state (`applovin_adapter.dart:913-980,989-1126`).
5. **Manager-owned async state:** destroy bounds broadcast-stream close, disposes the adapter, removes and disposes VIP/listeners, and detaches consent listeners (`ad_manager.dart:6423-6478`). `VipManager.dispose()` cancels expiry/read-retry timers and closes its stream (`vip_manager.dart:1831-1849`).

I did not find an additional unbounded `StreamController`, `Timer`, native ad object, or widget AnimationController leak in these paths. The AppLovin native callback ownership issue in R45-02 is the remaining concrete lifecycle defect found.

## Verdict

**No: this SDK is not safe to ship as-is for production AppLovin traffic in the EEA/UK.** R45-01 must be fixed first because it can override a real CMP's vendor-specific decision at the exact pre-init point MAX consumes privacy configuration. The fix is small but compliance-critical, and it needs an end-to-end cold-start regression test rather than another isolated test of `applyConsentToProviders()`.

R45-02 should be fixed before release if native AppLovin ads are enabled; it is a contained analytics/safety-cap correctness bug. R45-03 and R45-04 are lower-risk, documented integration hazards and could ship only with explicit product acceptance and strong host validation.

After R45-01 (and preferably R45-02) is corrected, the reviewed offline behavior, trial/VIP cryptography, lifecycle disposal, app-open modal guard, and AdMob consent/request paths are generally production-oriented. The no-backend replay/reset limitations remain real by design and must be acceptable to the product owner; they are not equivalent to server-enforced one-time entitlements.
