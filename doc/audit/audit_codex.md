# Independent audit report: `applovin_admob_sdk` round 44

Audit date: 2026-09-18  
Checkout package version: `2.9.23` (`packages/ad_sdk/pubspec.yaml:6`)  
Latest pub.dev version: `2.9.23`, published 2026-09-18 ([pub.dev API](https://pub.dev/api/packages/applovin_admob_sdk)). The checkout therefore matches the current published version.

## Executive result

**Verdict: no — do not use version 2.9.23 in a real production app as-is.**

I found four MAJOR issues in consent/policy behavior and four MINOR hardening or sample-integration issues. The most consequential defects are: a non-certified local dialog can authorize personalized advertising, a documented pre-initialization US privacy opt-out is discarded, the TCF-to-AppLovin mapping ignores vendor consent, and App Open suppression omits native ads. I found no path that grants a network-ad reward without the provider's genuine reward callback, and the normal offline load paths are bounded and recover on reconnect.

Before production use, findings 1–4 must be fixed and covered by regression tests. Findings 5–8 should also be resolved or converted into explicit, enforceable integration constraints. Production adoption must additionally accept that a fully offline one-day trial is not attacker-resistant and that offline VIP codes cannot be globally single-use.

Severity definitions used here: **BLOCKER** means an unconditional or default-path release stopper; **MAJOR** means a realistic compliance, privacy, or material correctness failure that must be fixed before production; **MINOR** means a narrower integration-dependent defect or policy footgun; **NIT** means documentation/test quality only. No BLOCKER was found.

## Findings

### 1. MAJOR — The non-certified built-in dialog can clear the compliance block and authorize personalized ads

**Evidence.** The source itself says the Cupertino dialog is not a Google-certified CMP, produces no TCF string, and cannot establish a valid EEA legal basis (`packages/ad_sdk/lib/src/config/ad_config.dart:561-571`; `packages/ad_sdk/lib/src/core/ad_manager.dart:2678-2692`). Nevertheless, when UMP is disabled, the dialog's Allow action writes `hasUserConsent: true` (`packages/ad_sdk/lib/src/consent/consent_dialog.dart:282-293`), `ConsentManager.showDialog` persists and applies that result to the provider (`packages/ad_sdk/lib/src/consent/consent_manager.dart:358-379`), and the auto-show path then clears `_footgunBlocked` (`packages/ad_sdk/lib/src/core/ad_manager.dart:2724-2739`). The published README contradicts the implementation's own assessment by advertising “GDPR-compliant consent UI without integrating a third-party CMP” (`packages/ad_sdk/README.md:36-43`).

**Concrete failure scenario.** An EEA/UK/Swiss app sets `autoRequestUmpConsent: false`, leaves `autoShowConsentDialog: true`, and relies on the advertised built-in dialog. The initial release guard closes ad requests, but after the user taps Allow, this non-TCF choice is forwarded as consent and the guard is cleared. Subsequent loads can be personalized even though no certified CMP collected the required purpose/vendor choices.

Google currently requires a Google-certified, TCF-integrated CMP for personalized ads in the EEA, UK, and Switzerland ([AdMob CMP requirement](https://support.google.com/admob/answer/13554116), [Flutter GDPR guidance](https://developers.google.com/admob/flutter/privacy/gdpr)).

**Required fix.** The built-in dialog must never set provider personalization consent or clear the release gate in regulated regions. Prefer removing it as an advertising-consent source entirely and using it only for non-ad preferences. Remove the README claim. Require UMP or another certified CMP, and consume its complete TCF state.

### 2. MAJOR — `setDoNotSell` claims to work before initialization but silently discards the opt-out

**Evidence.** The public API documents that it is safe before `initialize` and will persist the choice (`packages/ad_sdk/lib/src/core/ad_manager.dart:5021-5023`). Its implementation does the opposite: when `_consentManager` is null it logs “ignored” and returns (`packages/ad_sdk/lib/src/core/ad_manager.dart:5024-5029`). This differs from the general `setConsent` path, which buffers pre-init settings (`packages/ad_sdk/lib/src/core/ad_manager.dart:4841-4867`). The only pre-init regression test asserts that the call completes, not that the value survives (`packages/ad_sdk/test/ccpa_opt_out_toggle_test.dart:69-73`).

**Concrete failure scenario.** A US privacy/region gate calls `await AdManager().setDoNotSell(true)` before SDK initialization, as the API explicitly permits. The value is dropped. Initialization then starts with `doNotSell == false`; AppLovin receives a false flag and AdMob requests lack the intended restricted-data-processing signal until the user happens to toggle it again.

Google's current US-state guidance requires publishers to implement the appropriate restricted-data-processing/privacy-message flow ([US states privacy guidance](https://developers.google.com/admob/flutter/privacy/us-states)).

**Required fix.** Buffer this call through the same pre-init mechanism as `setConsent`, or bootstrap/persist the consent store before returning. Add a test that calls it pre-init, initializes, and verifies both persisted state and both provider writes.

### 3. MAJOR — TCF personalization is inferred from purposes alone; vendor consent is knowingly ignored

**Evidence.** `tcfAllowsPersonalisedAds` reads only GDPR applicability and purpose-consent bits 1, 3, and 4 (`packages/ad_sdk/lib/src/core/iab_storage.dart:580-606`). Its documentation explicitly says it does not parse `IABTCF_VendorConsents` (`packages/ad_sdk/lib/src/core/iab_storage.dart:529-539`). The UMP mapping then treats those purpose bits as sufficient (`packages/ad_sdk/lib/src/core/ad_manager.dart:5379-5387`) and forwards the resulting single boolean to provider consent (`packages/ad_sdk/lib/src/core/ad_consent.dart:121-129`, `packages/ad_sdk/lib/src/core/ad_consent.dart:142-153`). Tests cover purpose combinations but no vendor-denial case (`packages/ad_sdk/test/tcf_personalisation_consent_test.dart:163-228`).

**Concrete failure scenario.** An EEA user consents to purposes 1/3/4 but denies AppLovin as a vendor, or the publisher omitted AppLovin from its configured ad-partner list. The package computes `hasUserConsent == true` and explicitly calls MAX's user-consent API with true. That is not the user's vendor-level choice. GMA may still independently honor the raw TCF string, but the package's claimed one-consent-to-both-provider abstraction is incorrect for MAX.

Google's current ad-serving matrix says vendor consent is material in addition to purpose consent ([ad serving modes](https://developers.google.com/admob/flutter/privacy/ad-serving-modes)). AppLovin says publishers are responsible for collecting and transmitting applicable consent flags and that MAX can consume TCF/Additional Consent strings from a CMP ([MAX Flutter privacy](https://support.applovin.com/en/max/flutter/overview/privacy)).

**Required fix.** Do not synthesize an affirmative MAX consent bit from purpose consent alone. Either let MAX's documented TCF/AC integration consume the CMP strings without overriding it, or correctly evaluate the relevant vendor consent/legal-basis data. Add tests for purpose-allowed/vendor-denied, missing vendor, Additional Consent, and provider-list misconfiguration.

### 4. MAJOR — App Open “hide every inline surface” protection excludes native ads on both providers

**Evidence.** Immediately before an App Open show, the manager invokes only the adapter's `InlineAdVisibility.setInlineAdsHidden(true)` capability (`packages/ad_sdk/lib/src/core/ad_manager.dart:7211-7233`). AdMob's implementation enumerates only banner and MREC registries (`packages/ad_sdk/lib/src/adapters/admob_adapter.dart:38-55`) and expressly says native instances are never registered or hidden (`packages/ad_sdk/lib/src/adapters/admob_adapter.dart:307-315`). AppLovin likewise enumerates only banner and MREC registries (`packages/ad_sdk/lib/src/adapters/applovin_adapter.dart:53-90`). The README overstates the behavior as blanking “every inline surface” (`packages/ad_sdk/README.md:244-251`).

**Concrete failure scenario.** A screen contains a live AdMob or MAX native ad. The user backgrounds and resumes the app. The manager presents App Open while the native ad remains mounted beneath it. This is exactly the ad-over-another-ad conflict that the banner/MREC suppression was introduced to prevent, but the native format is omitted on both providers.

Google says not to display App Open ads on top of other ads, giving banner content as an example rather than an exhaustive exception ([App Open guidance](https://support.google.com/admob/answer/9341964)).

**Required fix.** Include every mounted native instance in the same ownership-based fullscreen hide mechanism, and test native visibility during App Open for both adapters, including instances created while App Open is already showing.

### 5. MINOR — Standard rewarded disclosure is optional without an explicit host-compliance contract

**Evidence.** `AdScreenState.showRewardedAd` makes `disclosureTitle` nullable and documents that omission goes straight to the ad (`packages/ad_sdk/lib/src/core/ad_screen.dart:177-180`, `packages/ad_sdk/lib/src/core/ad_screen.dart:198-214`, `packages/ad_sdk/lib/src/core/ad_screen.dart:262-279`). The raw manager API has no disclosure concept. The README's main example is safe because its CTA says “Watch ad for +10 coins” (`packages/ad_sdk/README.md:802-812`), but the API does not state that an equivalent disclosure and opt-in are mandatory when the dialog is omitted.

**Concrete failure scenario.** A host calls the helper from an unlabeled Continue button or automatically after a game event, omits the optional disclosure fields, and the SDK proceeds directly to the rewarded ad. The user was not told what action is required and what reward will be delivered.

Google requires clear, accurate reward disclosure before each rewarded ad and affirmative opt-in ([rewarded-ad policy](https://support.google.com/admob/answer/7313578)).

**Required fix.** Either require the disclosure by default or require an explicit `hostProvidedDisclosure: true` acknowledgment. Document the obligation at both helper and raw-manager entry points. This finding is about the pre-show contract; the actual reward callback logic is correct and does not fabricate completion.

### 6. MINOR — Public `bypassSafety` can turn App Open frequency controls off outside splash

**Evidence.** The method's own comment admits that `bypassSafety` is public, is not technically restricted to splash, bypasses daily/hourly/session caps and the throttle, and can cause a provider-policy violation (`packages/ad_sdk/lib/src/core/ad_manager.dart:7074-7095`). With the flag true, the ordinary safety and placement-cap checks are skipped (`packages/ad_sdk/lib/src/core/ad_manager.dart:7173-7196`). The invalid-traffic pause remains enforced, which is good. The example uses the flag only at splash (`packages/ad_sdk/example/lib/main.dart:946-952`), but `callSiteTag` is descriptive and unverified.

**Concrete failure scenario.** An integrator copy-pastes `showAppOpenAd(bypassSafety: true)` to a resume handler or several routes. Every trigger can show an App Open ad without the SDK's normal pacing limits; the in-memory audit trail neither prevents it nor survives restart.

Both Google and AppLovin recommend App Open only at open/foreground loading transitions with controlled frequency ([Google App Open guidance](https://support.google.com/admob/answer/9341964), [MAX App Open guidance](https://support.applovin.com/en/max/flutter/ad-formats/app-open-ads)).

**Required fix.** Make the bypass private to the splash controller, or enforce a manager-owned active-splash token rather than trusting a public boolean/placement label.

### 7. MINOR — Late MAX native callbacks can mutate a replacement provider/session

**Evidence.** MAX native load/failure callbacks look up `AdManager().adapter` at callback time and only check that the current adapter is initialized before mutating `adapter.native(instanceKey)` (`packages/ad_sdk/lib/src/widget/native_ad_widget.dart:583-610`). Click and revenue callbacks do the same (`packages/ad_sdk/lib/src/widget/native_ad_widget.dart:613-658`). The disposed-instance tombstone is consulted only if the current adapter is an `AppLovinAdapter` (`packages/ad_sdk/lib/src/widget/native_ad_widget.dart:639-647`). Nothing captures the originating adapter or initialization generation.

**Concrete failure scenario.** A MAX native platform view has an in-flight callback while the app destroys and reinitializes the SDK with AdMob and keeps/rebuilds the widget tree. The old MAX failure can mark the new AdMob instance key as errored; a late click/revenue callback can write an AppLovin-tagged event into the replacement adapter's sink and increment safety metrics for the wrong session.

**Required fix.** Capture the originating adapter/session generation when building the MAX view and reject callbacks unless both still match. Apply the tombstone check to the captured MAX adapter, not whichever global adapter happens to be current.

### 8. MINOR — The AppLovin-default example splash omits MAX's requested app-open call-out

**Evidence.** The example can show a splash App Open ad (`packages/ad_sdk/example/lib/main.dart:946-952`), but the visible splash contains only an icon, package name, and spinner (`packages/ad_sdk/example/lib/main.dart:987-1005`). Its default provider configuration is AppLovin (`packages/ad_sdk/example/lib/main.dart:165-179`).

**Concrete failure scenario.** A developer uses the demo as the integration pattern with MAX. A cold-start ad appears after a generic loading screen that never tells the user an ad is about to appear.

AppLovin's current App Open guidance asks for a splash/loading call-out informing the user that an ad will be shown ([MAX Flutter App Open guidance](https://support.applovin.com/en/max/flutter/ad-formats/app-open-ads)).

**Required fix.** Add a visible, localizable “an ad may appear while the app loads” message to the example and splash-controller documentation.

## Subsystem conclusions

### Cross-platform provider abstraction

The basic abstraction is real rather than nominal. Both provider configs resolve Android/iOS overrides for banner, interstitial, App Open, rewarded, MREC, and native IDs (`packages/ad_sdk/lib/src/config/ad_config.dart:71-86`, `packages/ad_sdk/lib/src/config/ad_config.dart:104-209`, `packages/ad_sdk/lib/src/config/ad_config.dart:245-378`). AdMob native objects are explicitly disposed; MAX listener/timer teardown is substantial; fullscreen slots use provider bridges rather than hand-rolled platform-channel argument types. I did not find an Android-only ad-show path masquerading as cross-platform.

The material cross-provider gaps are findings 3, 4, and 7. One further release risk remains unverified rather than proven defective: the IAB store explicitly says its iOS branch has never been exercised on hardware (`packages/ad_sdk/lib/src/core/iab_storage.dart:39-41`), while consent correctness depends on that store. The existing tests emulate the preference implementation rather than a physical iOS UMP write/read cycle (`packages/ad_sdk/test/tcf_personalisation_consent_test.dart:230-238`). A real-device iOS consent matrix is required before claiming parity.

### Offline and no-network behavior

Normal offline behavior is fail-closed and bounded:

- SDK-owned UMP closes the ad gate before starting and keeps it closed on real consent-fetch failure (`packages/ad_sdk/lib/src/core/ad_manager.dart:3597-3609`, `packages/ad_sdk/lib/src/core/ad_manager.dart:3660-3689`). An inconclusive offline UMP result does not overwrite a previously persisted choice (`packages/ad_sdk/lib/src/core/ad_manager.dart:5388-5424`).
- Native adapter initialization has a 20-second bound (`packages/ad_sdk/lib/src/core/ad_manager.dart:3710-3739`). Load requests check connectivity and arm 30-second slot watchdogs; connectivity restoration refills eligible slots. A show request not confirmed by the provider is released after 10 seconds (`packages/ad_sdk/lib/src/state/ad_slot.dart:327-375`).
- Reward callbacks remain false/skipped on load/show failure; neither provider invents a reward when connectivity disappears.

The deliberate residual is that interstitial/rewarded have no timeout after the provider confirms display, because force-releasing a genuinely visible ad could stack another fullscreen (`packages/ad_sdk/lib/src/state/ad_slot.dart:354-363`). If a native SDK loses its dismiss callback after a mid-show failure, that slot and the caller's completion callback can remain unresolved for the session. This is a defensible safety trade-off, but hosts must not block critical navigation solely on the callback.

### Ad lifecycle correctness

Apart from findings 4 and 7, the lifecycle implementation is strong. Loads and shows have generation/identity guards, stale ads are discarded, teardown disposes AdMob objects and MAX listeners/timers, and banners/MRECs have route/background/fullscreen visibility ownership. Reward correctness is specifically sound: AdMob grants only from `onUserEarnedReward` (`packages/ad_sdk/lib/src/adapters/admob_adapter.dart:1622-1639`), while MAX grants only from `onAdReceivedRewardCallback` (`packages/ad_sdk/lib/src/adapters/applovin_adapter.dart:1901-1939`). Dismiss/failure paths return `earned: false`. SSV is available for hosts that require server-confirmed economic rewards.

`vipAutoGrant` is an explicit host-selected entitlement benefit, not a claim that an ad completed; it should remain clearly separated from network-reward accounting.

### One-day trial trust model

Release builds grant 24 hours by default (`packages/ad_sdk/lib/src/config/ad_config.dart:47-54`, `packages/ad_sdk/lib/src/config/ad_config.dart:532-552`). Expiry uses device wall time, a persisted high-water mark, and an in-process monotonic stopwatch (`packages/ad_sdk/lib/src/vip/vip_manager.dart:310-390`, `packages/ad_sdk/lib/src/vip/vip_manager.dart:830-873`). This blocks simple rollback after the SDK has already observed a later time, but it is not a trustworthy clock: an attacker can keep resetting the clock before the process observes expiry, and local/rooted storage can be edited or removed.

Reinstall/storage bypass is consciously accepted and documented. iOS uses a Keychain flag, with device erase still bypassing it; Android relies only on best-effort Auto Backup and intentionally returns “not previously granted” when local data is absent (`packages/ad_sdk/lib/src/vip/_first_install_guard.dart:27-88`, `packages/ad_sdk/lib/src/vip/_first_install_guard.dart:137-155`). Thus “one day” is a retention feature, not an enforceable trial license. This is an accepted no-backend product risk, not a newly hidden flaw. A product whose economics depend on strict one-time trial duration needs a server/account entitlement clock.

### Offline VIP-code authenticity and replay

The signed-code design is not trivially forgeable merely because the package is decompiled. AVP1/AVP2 payloads are Ed25519-verified with a public key; the private signing key does not ship (`packages/ad_sdk/lib/src/vip/signed_vip_key.dart:109-120`, `packages/ad_sdk/lib/src/vip/signed_vip_key.dart:149-191`). AVP2 additionally signs expiry and bundle binding (`packages/ad_sdk/lib/src/vip/signed_vip_key.dart:214-249`). Hosts must use this signed path; a custom local `vipKeyValidator` is only as strong as host-supplied logic.

Replay cannot be globally prevented without a backend. The implementation explicitly accepts that a leaked code is redeemable once per device (`packages/ad_sdk/lib/src/vip/vip_manager.dart:1246-1265`). iOS has a Keychain redeemed-ID ledger; Android depends on uninstallable preferences/optional backup (`packages/ad_sdk/lib/src/vip/_redeemed_key_ledger.dart:9-25`, `packages/ad_sdk/lib/src/vip/_redeemed_key_ledger.dart:79-99`). AVP1 remains unexpiring and unbound for compatibility (`packages/ad_sdk/lib/src/vip/signed_vip_key.dart:86-100`, `packages/ad_sdk/lib/src/vip/signed_vip_key.dart:210-212`). AVP2 bundle validation also deliberately fails open if package-info lookup fails (`packages/ad_sdk/lib/src/vip/vip_manager.dart:1341-1381`). These risks are documented and consciously accepted, but a monetized, single-use-code product requires server-side claiming; no client-only implementation can supply it.

### Consent coverage beyond GDPR

The package reads UMP/TCF, legacy US Privacy, and GPP US sections and forwards COPPA/CCPA-style flags. However, “all countries” cannot be guaranteed by a library-level boolean abstraction: dashboard message publication, correct ad-partner/vendor lists, age gating, privacy-policy content, and country-specific disclosures remain publisher responsibilities. Findings 1–3 currently prevent the stronger claim that one collection flow is correctly applied to both providers.

COPPA handling is conservative once known: AdMob gets per-request child-directed tags, and MAX initialization aborts for a known child user (`packages/ad_sdk/lib/src/adapters/applovin_adapter.dart:718-743`). The initial value must be supplied before initialization through `setConsent`; the package documentation itself warns that a brand-new always-child-directed app can otherwise initialize MAX once (`packages/ad_sdk/README.md:2465-2471`). AppLovin's current terms prohibit initializing/using its services in connection with a child ([MAX privacy](https://support.applovin.com/en/max/flutter/overview/privacy)). Therefore an always-child-directed app must not use the default MAX startup sequence.

### Provider policy posture

The SDK contains good defenses: global fullscreen exclusion, ad freshness checks, invalid-traffic cooldown, visibility/refresh ownership, frequency caps, rewarded-interstitial disclosure, and genuine provider reward callbacks. Those controls do not cure findings 4–6, and they cannot make arbitrary host placement compliant. Hosts remain responsible for natural transition points, non-deceptive placement, ad density, app-ads.txt, store disclosures, and provider-console consent configuration. Relevant current sources checked were [AdMob behavioral policies](https://support.google.com/admob/answer/2753860), [AdMob interstitial guidance](https://support.google.com/admob/answer/6201362), [AdMob App Open guidance](https://support.google.com/admob/answer/9341964), [AdMob rewarded policy](https://support.google.com/admob/answer/7313578), [MAX publisher best practices](https://support.applovin.com/en/max/max-dashboard/best-practices), and [MAX interstitial best practices](https://support.applovin.com/en/max/best-practices/when-is-it-best-to-display-interstitial-ads).

## Test assessment

The checkout has broad unit/widget coverage of slot races, watchdogs, consent, connectivity, and adapter lifecycle. I did not execute `flutter test` or `flutter analyze`, because the requested audit is read-only and running Flutter tooling could update dependency metadata/cache state. This report is therefore a source and policy audit, not a claim that the current suite passes.

Missing regression coverage directly associated with the findings:

1. Pre-init `setDoNotSell(true)` surviving initialization and reaching both providers.
2. TCF purposes allowed while AppLovin/vendor consent is denied or absent.
3. The local dialog being unable to authorize regulated personalized ads.
4. Native-ad suppression for both providers during App Open, including late-created instances.
5. Late MAX native callbacks after destroy/provider swap.
6. A policy-safe standard rewarded call contract.
7. Physical iOS verification of UMP-written TCF/GPP preference reads.

## Final production decision

**No, version 2.9.23 should not be shipped as-is.** Fix findings 1–4 first, add the listed consent/native regression tests, and validate the IAB read path on physical iOS hardware. Resolve or explicitly constrain findings 5–8 before presenting the package as policy-safe by default. After those changes, use is still conditional: the publisher must configure a certified CMP and all mediation partners correctly, supply child status before MAX initialization, and accept—or replace with a backend—the documented trial-clock and cross-device VIP replay limitations.
