# Partner Readiness Matrix Template

Use one copy per partner and release train. Fill unknowns with `TBD — owner, due date`; do not substitute assumed device models, regions, app IDs, or provider choices. A test is `PASS` only with recorded evidence.

## Current local smoke evidence (baseline only; not partner sign-off)

| Device | Build/package | Provider | Observed | Limits |
|---|---|---|---|---|
| TECNO KJ7 / Android 14 | debug, isolated `com.roy.admobwrapper.smoketest` | AdMob test inventory | App launched; UMP returned `notRequired`/`canRequestAds=true`; AdMob initialized; App Open test ad displayed; interstitial/rewarded/rewarded-interstitial loaded; no fatal exception observed | This proves one debug device's baseline only. EEA UMP presentation, custom native factories, rewarded dismiss/reward, release build, AppLovin provider, and partner app config were not verified here. UMP EEA test was blocked because no device-specific hashed test identifier was supplied; do not force geography without registering that test ID. |

## 1. Partner scope and decisions

| Field | Partner value / status | Owner | Evidence / notes |
|---|---|---|---|
| Partner / product / release train | `<name>` | `<owner>` | |
| Package version + Flutter/Dart | `<exact pinned versions>` | `<mobile lead>` | `pubspec.lock` |
| Active provider | `<AdMob / AppLovin MAX>` | `<monetization owner>` | |
| Mediation | `<none / AppLovin in AdMob / other approved setup>` | `<monetization owner>` | Add `gma_mediation_applovin` only for AppLovin as AdMob mediation |
| Android / iOS targets | `<yes/no + min OS>` | `<mobile lead>` | |
| Ad formats and placements | `<banner/MREC/native/interstitial/rewarded/App Open/rewarded-interstitial>` | `<product + monetization>` | Rewarded interstitial is AdMob-only in this SDK |
| Regions / age groups | `<countries/regions; child-directed?; age policy>` | `<privacy/legal>` | |
| Consent/CMP | `<UMP auto / manual UMP / partner CMP>` | `<privacy/legal + mobile>` | UMP message published for every AdMob App ID if enabled |
| ATT | `<in scope? purpose text and localization>` | `<privacy/legal>` | iOS only; require approved `NSUserTrackingUsageDescription` |
| CCPA / US state options | `<in scope? UI and backend owner>` | `<privacy/legal>` | Host exposes durable privacy-options route when required |
| VIP / free grace | `<out of scope / approved grant types, duration>` | `<product + security>` | If out of scope or unapproved, configure `FirstInstallVipGrace.disabled` |
| Android backup change | `<no / approved / rejected>` | `<security/privacy>` | Do not enable/change backup solely to support grace without approval |
| SSV | `<client-only / backend-authoritative>` | `<backend + monetization>` | SDK forwards values; partner backend verifies signed postback |
| Optional SDK modules | `<list selected: arbitrator, monitors, remote safety, diagnostics, exports...>` | `<owner>` | Record fields, network requests, retention, rollout and rollback |

## Named partner intake status

No partner-specific Android model/OS, iOS target, launch countries, active provider, app IDs, ad-unit inventory, consent policy, VIP scope, or SSV/backend owner was provided in this session. These rows are intake placeholders, not confirmed rollout requirements:

| Partner | Mobile owner | Android models/OS | iPhone/iOS target | Launch markets/age policy | Provider/formats | Backend/SSV owner | Status |
|---|---|---|---|---|---|---|---|
| Skyjoy | `TBD` | `TBD` | `TBD` | `TBD` | `TBD` | `TBD` | Inputs required |
| Vietjet | `TBD` | `TBD` | `TBD` | `TBD` | `TBD` | `TBD` | Inputs required |
| Samsung | `TBD` | `TBD` | `TBD` | `TBD` | `TBD` | `TBD` | Inputs required |
| HTC | `TBD` | `TBD` | `TBD` | `TBD` | `TBD` | `TBD` | Inputs required |
| TECNO | `TBD` | `TECNO KJ7 / Android 14` is local smoke evidence only; confirm launch target models | `TBD` | `TBD` | `TBD` | `TBD` | Inputs required |
| Huawei | `TBD` | `TBD` | `TBD` | `TBD` | `TBD` | `TBD` | Inputs required |

Do not substitute the SDK's local TECNO test for the partner's signed device matrix; Huawei distribution channel/services may also affect which ad provider SDKs are eligible and must be confirmed with the partner.

## 2. Native configuration checklist

| Platform | Item | Required when | Status | Evidence |
|---|---|---|---|---|
| Android | `minSdk >= 24` | Always | `<TBD>` | `android/app/build.gradle(.kts)` |
| Android | `INTERNET`, `ACCESS_NETWORK_STATE`, `AD_ID` | Ad SDK | `<TBD>` | `AndroidManifest.xml` |
| Android | AdMob `APPLICATION_ID` metadata | Bundled GMA/UMP, even if AppLovin serves ads | `<TBD>` | `AndroidManifest.xml` |
| Android | AppLovin SDK key + platform units | AppLovin selected | `<TBD>` | CI secret define + approved dashboard inventory; never commit key |
| Android | Kotlin Gradle plugin `>=2.3.0` and new compiler DSL | Current GMA 9.0.0 package line | `<TBD>` | `settings.gradle.kts`, `app/build.gradle.kts` |
| iOS | iOS deployment target `>=13.0` | iOS target | `<TBD>` | `Podfile` and Xcode target |
| iOS | `GADApplicationIdentifier` | Bundled GMA/UMP | `<TBD>` | `Info.plist` |
| iOS | `AppLovinSdkKey` | AppLovin selected | `<TBD>` | `Info.plist` |
| iOS | `NSUserTrackingUsageDescription` | ATT approved/in scope | `<TBD>` | Partner-approved localized copy in `Info.plist` |
| iOS | Current merged `SKAdNetworkItems` | Enabled providers/mediation require them | `<TBD>` | Merged `Info.plist`; preserve host entries |
| Android+iOS | Platform unit IDs for each enabled format | Selected provider + format + target platform | `<TBD>` | Provider console/config; no test IDs in release |
| Android+iOS | `gma_mediation_applovin` pin | AppLovin used as AdMob mediation only | `<TBD / N/A>` | Verify pod pin and fixture against selected SDK release |

## 3. Device and market test matrix

Add rows for actual launch-market devices. Do not treat an OEM name or simulator as a substitute for a model/OS combination.

| Device/model | OEM | OS/version | Region/test geo | Provider | Build | Network | Scenarios run | Result | Evidence path |
|---|---|---|---|---|---|---|---|---|---|
| `<required>` | `<OEM>` | `<version>` | `<market>` | `<provider>` | `<debug/release>` | `<wifi/mobile/offline>` | Cold start, splash, formats selected below | `NOT RUN` | |
| `<required>` | `<OEM>` | `<version>` | `<market>` | `<provider>` | `<debug/release>` | `<wifi/mobile/offline>` | Consent grant/deny/update failure/privacy options as in scope | `NOT RUN` | |

### 3.1 Core smoke cases

| Case | Expected observable result | Result / evidence |
|---|---|---|
| Cold start and SDK init | One init completion; no crash; hard cap reaches home if init/ad is slow | `NOT RUN` |
| Splash App Open, if enabled | Load → buffer → show; dismiss enters home; no stack on bare splash | `NOT RUN` |
| App Open resume, if enabled | SDK lifecycle handler; no duplicate host observer; modal/overlay cases documented | `NOT RUN` |
| Banner/MREC/native, if selected | Load on test inventory; route/offscreen lifecycle works; custom AdMob factory registered if used | `NOT RUN` |
| Interstitial, if selected | Existing approved trigger preserved; eligible and safety-blocked cases both checked | `NOT RUN` |
| Rewarded, if selected | User action only; grant only when `earned == true` | `NOT RUN` |
| Rewarded interstitial, if selected | AdMob only; disclosure and earned callback checked | `NOT RUN` |
| Offline → reconnect | Consent gate remains correct; selected slots recover or show documented fallback | `NOT RUN` |
| Release configuration | No test units/geography, verbose personal data, private VIP key, or unapproved exports | `NOT RUN` |

## 4. Consent matrix

Run only the flows applicable to partner markets/provider. For UMP, use a dedicated debug build and registered hashed test device. Do not force debug geography in release.

| Flow | Platform/provider | Expected result | Result / evidence |
|---|---|---|---|
| UMP not required | `<platform/market>` | Form skipped; record `status` and `canRequestAds` | `NOT RUN` |
| UMP required, first launch | `<platform/market>` | Published message displays; user choice persisted; result gates first ad request | `NOT RUN` |
| UMP no-network/update error | `<platform/market>` | Record error/status; verify SDK consent gate, do not assume ads load | `NOT RUN` |
| User revisits privacy options | `<platform/market>` | Permanent host settings entry opens provider form when required | `NOT RUN` |
| Consent withdrawal/resume | `<platform/provider>` | Re-check after resume; record provider-specific behavior, including AppLovin's unconfirmable fire-and-forget writes | `NOT RUN` |
| ATT, if approved | iOS | Prompt only after first frame; status recorded; does not replace UMP | `NOT RUN` |
| COPPA/age-restricted, if in scope | `<provider/platform>` | Verify selected provider's behavior; AppLovin may refuse init when child status is known | `NOT RUN` |

## 5. Feature/API coverage and ownership

| Feature | Selected? | Owner / configured inputs | Verification | Status |
|---|---|---|---|---|
| Provider/bootstrap/splash | Yes | `<mobile + selected provider>` | Core smoke matrix | `NOT RUN` |
| Selected ad formats/placements | `<yes/no>` | `<screen, trigger, units>` | One test case per enabled surface | `NOT RUN` |
| Route/visibility/inline control | `<yes/no>` | `<nested nav, IndexedStack, overlays>` | Tab/route/offscreen lifecycle | `NOT RUN` |
| Safety/placement overrides | `<default / customized>` | `<approved values and owner>` | eligible + blocked show cases | `NOT RUN` |
| Revenue/event analytics | `<yes/no>` | `<destination, schema, retention>` | event fields, dedupe, consent | `NOT RUN` |
| VIP/grace/signed promo | `<yes/no>` | `<public key; issuer owns private key; grant policy>` | valid/invalid/expired/wrong-app/used/offline; Android replay limitation | `NOT RUN` |
| SSV | `<yes/no>` | `<provider callback + backend owner>` | signature, timestamp, replay/idempotency, unknown user | `NOT RUN` |
| Remote safety / flags | `<yes/no>` | `<endpoint/issuer, public key, revision policy>` | valid/stale/invalid/offline payload; safe fallback | `NOT RUN` |
| Arbitrator/monetization modules | `<list or none>` | `<decision owner, sampling, rollback>` | controlled test events and rollback | `NOT RUN` |
| Diagnostics/compliance/flight recorder | `<yes/no>` | `<approved fields, storage, access, retention, transfer>` | export/verify/redact/delete | `NOT RUN` |
| Data erasure | `<yes/no>` | `<privacy deletion flow/scope>` | verify intended data removed and entitlements preserved/removed per choice | `NOT RUN` |

## 6. Release and handoff decision

- SDK version / Flutter / Dart / AGP / Kotlin / Xcode / provider plugin versions: `<fill exact values>`
- Builds: Android debug `<NOT RUN>`; Android release `<NOT RUN>`; iOS simulator `<NOT RUN>`; iOS device/archive `<NOT RUN>`
- App tests: `<commands run, pass/fail, summary>`
- Device/market matrix: `<completed rows / blockers>`
- Required partner approvals: product `<TBD>`, privacy/legal `<TBD>`, security `<TBD>`, backend `<TBD if SSV/VIP>`
- Accepted limitations and rollback owner/path: `<fill>`
- Final decision: `NOT READY` until required rows pass or have explicit owner-approved exception.
