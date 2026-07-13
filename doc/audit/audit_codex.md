# Audit Codex - AdMob/AppLovin SDK + Example

Audit time: 2026-07-13 15:09 +07

Scope:
- `packages/ad_sdk`: Flutter SDK core for AdMob + AppLovin MAX.
- `packages/ad_sdk/example`: SDK example app.
- Host integration touchpoints in `lib/`, `android/`, `ios/`.
- Policy cross-check against current official docs:
  - Google AdMob Flutter UMP: https://developers.google.com/admob/flutter/privacy
  - Google AdMob app-open guidance: https://developers.google.com/admob/flutter/app-open
  - AdMob app-open best practices: https://support.google.com/admob/answer/9341964
  - AppLovin MAX Flutter privacy: https://developers.applovin.com/en/max/flutter/overview/privacy/

## Verdict

**SDK core: production-usable with conditions.**

The SDK is not a blind "ship as-is everywhere" library, but the core implementation is strong enough for production app integration if the host app enforces the required startup contract:

1. Run ATT on iOS before first ad request.
2. Run Google UMP `requestConsentInfoUpdate()` / form flow before SDK `initialize()`.
3. Do not initialize AppLovin for children / child-directed traffic.
4. Do not publish the example app with its current real AppLovin IDs and QA safety preset.
5. Add production guardrails so the integration fails closed, not just logs warnings, when consent flow is missing.

**Example app: not production-safe as-is.**

The example currently includes real AppLovin SDK/ad-unit IDs and uses relaxed QA safety limits in all build modes. It is useful for device audit, but must not be published or used as a template without replacing IDs and restoring production safety defaults.

## Verification

Passed:
- `flutter test` in `packages/ad_sdk`: **514 tests passed**.
- `flutter test` in `packages/ad_sdk/example`: **8 tests passed**.
- `flutter analyze` in `packages/ad_sdk`: **No issues found**.
- `flutter analyze` in `packages/ad_sdk/example`: **No issues found**.

Notes:
- Commands print `(eval):1: unmatched "` from the local shell init, but all commands exited `0`.
- Dependency warnings show newer incompatible versions exist, especially `google_mobile_ads 7.0.0 -> 9.0.0` and `applovin_max 4.6.4` current constraint. This is not a failing audit item, but should be scheduled as dependency review.

## Major Findings

### P0 - AppLovin Must Not Be Initialized For Child Users

AppLovin's current privacy guidance says publishers must set consent/do-not-sell before SDK init and must not initialize/use AppLovin services in connection with a "child" under applicable law. The SDK code only logs a warning when `AdConsent.isAgeRestrictedUser == true`; it does not prevent `AppLovinAdapter.initialize()`.

Evidence:
- `packages/ad_sdk/lib/src/core/ad_consent.dart:75-89` logs that AppLovin MAX 4.x has no child-directed API and warns integrators.
- `packages/ad_sdk/lib/src/adapters/applovin_adapter.dart:116-140` initializes AppLovin regardless of age-restricted state.
- Official AppLovin doc states consent/privacy flags must be set before init and AppLovin must not be used for child users.

Impact:
- For general adult apps: acceptable if the app has no child audience and privacy policy is correct.
- For mixed audience / Families / child-directed apps: **do not use AppLovin path** without a pre-init age gate that routes child users away from AppLovin entirely.

Recommendation:
- Add `AdConfig.isChildUser` / `audienceMode` gate, and block AppLovin initialization when child mode is true.
- For child-directed apps, use only AdMob/Families-certified flow or disable ads for child users.

### P0 - Example Contains Real Production AppLovin IDs

The example source has real AppLovin SDK key and ad-unit IDs.

Evidence:
- `packages/ad_sdk/example/lib/main.dart:44-64` explicitly says real production AppLovin keys were borrowed and must be replaced before publish.
- `packages/ad_sdk/example/ios/Runner/Info.plist:50-51` includes the AppLovin SDK key.

Impact:
- If published, public example can generate real traffic/revenue/noise under production IDs.
- If copied by app teams, it teaches an unsafe pattern.

Recommendation:
- Replace example source with placeholders or dart-defines.
- Move real IDs to local-only ignored config.
- Add CI check that rejects `YOUR_` absence / known production IDs in example package before publish.

### P1 - Consent Safety Is Strong In Host Flow, But SDK Defaults Are Too Easy To Misuse

Google UMP docs require `requestConsentInfoUpdate()` on every launch and `canRequestAds()` before requesting ads. The SDK implements a proper gate once `requestUmpConsent()` is used, but `AdConfig.autoRequestUmpConsent` defaults to `false` and `disableAppLovinCmpFlow` defaults to `true`.

Evidence:
- `packages/ad_sdk/lib/src/config/ad_config.dart:260-263` defaults `autoRequestUmpConsent=false`, `disableAppLovinCmpFlow=true`.
- `packages/ad_sdk/lib/src/core/ad_manager.dart:810-839` only warns if no UMP/CMP flow will run.
- `packages/ad_sdk/lib/src/core/ad_manager.dart:1211-1237`, `1418-1441`, `1532-1555` block loads when `_canRequestAds == false`.
- `packages/ad_sdk/lib/src/core/ump_consent.dart:94-151` calls `requestConsentInfoUpdate()` and `canRequestAds()`.
- Host app correctly calls ATT and UMP before initialize in `lib/mckimquyen/widget/splash/splash_screen.dart:167-201`, then initializes at `212-290`.

Impact:
- Host app currently integrates correctly.
- A future app can accidentally ship with no real consent form and still initialize/request ads because the SDK logs but does not fail.

Recommendation:
- Change production default to `autoRequestUmpConsent=true`, or add release assert/hard failure unless host marks `consentFlowHandledExternally=true`.
- Keep the custom Cupertino consent dialog as a preference UI only; do not treat it as a replacement for UMP in regions where Google requires certified CMP behavior.

### P1 - AppLovin Consent Is Applied After SDK Init In `AdManager.initialize`

AppLovin requires consent and do-not-sell values before SDK initialization. The adapter initializes first, and `ConsentManager.applyToProviders()` is called afterward. This is safe only if the host already called `AdManager.requestUmpConsent()` before `initialize()`, because `requestUmpConsent()` calls `setConsent()` and `applyConsentToProviders()` before init.

Evidence:
- Adapter init at `packages/ad_sdk/lib/src/core/ad_manager.dart:748-759`.
- Consent manager bootstrap/apply at `776-808`, after adapter init.
- AppLovin init at `packages/ad_sdk/lib/src/adapters/applovin_adapter.dart:138-140`.
- Host app calls UMP before init at `lib/mckimquyen/widget/splash/splash_screen.dart:189-201`.

Impact:
- Current host flow: acceptable.
- SDK-owned `autoRequestUmpConsent=true` path: currently runs UMP after adapter init (`813-820`), which is late for AppLovin's "set before initialize" requirement.

Recommendation:
- Move consent bootstrap and optional UMP before adapter creation/init.
- Or require host-preflight UMP for AppLovin provider and fail release if not done.

### P1 - VIP Security Is Good Offline, But Not Globally One-Time Without Backend

The signed VIP key design is appropriate for no-backend apps: Ed25519 public key verification means decompiling cannot forge new keys. However, without a server, a leaked valid code can be redeemed on multiple devices.

Evidence:
- `packages/ad_sdk/lib/src/vip/signed_vip_key.dart:59-70` documents offline Ed25519 model and the multi-device reuse limitation.
- `packages/ad_sdk/lib/src/vip/vip_manager.dart:467-528` enforces per-device one-time use.
- `packages/ad_sdk/lib/src/vip/_redeemed_key_ledger.dart:9-22` adds iOS Keychain durable reuse guard; Android relies on prefs only.

Impact:
- Good enough for low/medium-value VIP codes, giveaways, internal unlocks.
- Not strong enough for paid/high-value entitlement unless backend validation exists.

Recommendation:
- Keep signed offline keys for no-backend mode, but document "per-device, not global" in integration checklist.
- For paid VIP, use StoreKit/Billing or backend verification.

### P1 - Example Uses QA Safety Limits In All Modes

Example config intentionally disables meaningful frequency caps for QA.

Evidence:
- `packages/ad_sdk/example/lib/main.dart:145-150` says demo uses loose preset even in release.
- `packages/ad_sdk/example/lib/main.dart:176-189` sets session/hour/day caps to 999, CTR threshold 1.0.

Impact:
- Example is useful for testing ad UI repeatedly.
- Not acceptable for production template.

Recommendation:
- Make example use `AdSafetyParams.auto` by default, with `--dart-define=QA_AD_STRESS=true` for loose caps.

## Positive Findings

- Provider abstraction is clean: `AdProviderAdapter` isolates AdMob/AppLovin object lifecycle.
- AdMob path has conservative default `npa=1`, RDP extras, stale ad expiry, and native object disposal.
- Load/show gates cover VIP, daily cap, UMP `canRequestAds`, network state, and re-entrancy.
- App-open lifecycle is heavily guarded: splash active guard, fullscreen-dismiss debounce, dialog-on-top guard, rapid resume gate, hard cap watchdog.
- Banner widget unsubscribes route observer, hides/suppresses for VIP, blocks offline/consent-not-ready startup, and disposes notifiers.
- First-install trial exists: release default 24h, debug default 30s.
- Trial expiry is handled mid-session by `VipManager` expiry timer.
- Android/iOS ad unit separation is supported through per-platform IDs.
- Host app has required native keys/permissions: Android AdMob App ID, `AD_ID`, iOS `GADApplicationIdentifier`, `AppLovinSdkKey`, `NSUserTrackingUsageDescription`, SKAdNetwork entries.

## Offline / No-Network Behavior

Pass with caveat:
- Load paths check `AdManager.isConnected` before app-open/interstitial/rewarded/banner requests.
- Connectivity watch refills slots on offline -> online transition.
- If connectivity detector fails, SDK falls back to last-known optimistic state; a real offline request can still fail through native SDK and go into cooldown. This is acceptable but should be monitored in logs.

Evidence:
- `packages/ad_sdk/lib/src/core/ad_manager.dart:1190-1205`, `1211-1237`, `1418-1441`, `1532-1555`, `1992-2031`.

## Ad Type Coverage

- Banner: implemented for AdMob adaptive banner and AppLovin widget view. Route pause/resume covered.
- App Open: implemented for splash and resume, with hard caps and lifecycle guards.
- Interstitial: implemented with safety/frequency gates and post-dismiss reload.
- Rewarded: implemented with reward callback, optional VIP auto-grant, SSV data plumbing.

Caveat:
- Interstitial/rewarded do not have watchdog hard caps for missing native callbacks. Tests treat callbacks as reliable. App-open has watchdog because it has known lifecycle risk.

Evidence:
- AdMob interstitial/rewarded comments at `packages/ad_sdk/lib/src/adapters/admob_adapter.dart:592-599`, `760-764`.
- AppLovin interstitial/rewarded comments at `packages/ad_sdk/lib/src/adapters/applovin_adapter.dart:638-645`, `820-825`.

Recommendation:
- Add optional show watchdog for interstitial/rewarded too, using the app-open pattern.

## Production Decision

Use this SDK in production app only under these rules:

1. For our current FastNet host app, using AppLovin provider is acceptable **if the app is not child-directed and does not classify any served user as a child**.
2. Keep host startup order: ATT -> UMP -> `AdManager.initialize`.
3. Do not rely on SDK defaults in new apps; explicitly set/confirm UMP ownership.
4. Do not publish the example package/app until real IDs are removed and QA safety preset is gated.
5. If switching to AdMob provider, replace all public Google test unit IDs in `AdKey.adMob` first.
6. For VIP codes, offline signed keys are acceptable for local entitlement, not for global paid entitlement.

Final answer: **Yes, we can use the SDK core for production after the P0/P1 guardrails above. No, we should not ship/copy the example as-is.**
