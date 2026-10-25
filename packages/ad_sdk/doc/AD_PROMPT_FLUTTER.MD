# Flutter Partner Integration Guide — `applovin_admob_sdk`

## How to use this document

This file targets the current SDK integration API and is the single partner handoff for `applovin_admob_sdk`. Start with the **Fast path** (Android + AdMob test banner), then follow **Quick start** for minimum ad setup, then complete selected feature recipes and release checklist. **Coverage:** every public SDK feature family has an in-file recipe or an explicit SDK ceiling (see the completeness gate at the end). Coverage is documentation coverage; runtime credentials, device behavior, consent/legal approval and provider policy still require evidence in Step 11. Fill Section 0 with partner-approved values first; stop and ask when required decisions or credentials are missing. Keep optional features disabled unless explicitly approved.

This file is the self-contained integration path, and it is written so you can finish without contacting anyone. From 3.6.2 on the same file also ships inside the pub.dev package (`doc/AD_PROMPT_FLUTTER.MD` after `dart pub unpack`), so the copy you were handed can be checked against the version you pinned. If the two differ, the copy inside the package for your pinned version wins. Where a step names an SDK file (the example app, the README, a tool script), you can get all of them yourself from pub.dev with one command and no checkout:

```bash
mkdir -p ~/sdk_ref && cd ~/sdk_ref
dart pub unpack applovin_admob_sdk:3.6.2      # use the version you pinned
# ~/sdk_ref/applovin_admob_sdk-3.6.2/ now contains README.md, CHANGELOG.md,
# example/ (a full runnable demo app), tool/ (operator scripts), lib/ (SDK source)
# and, from 3.6.2 on, doc/AD_PROMPT_FLUTTER.MD (a copy of this guide)
```

Use that folder as a read-only reference; never edit files inside it and never run it from inside your own app. If this guide and the SDK's own README ever disagree, trust this guide for **your integration steps** and the README for **API details**, and record the difference in Step 12.

Manual users can run companion `example/` app as reference. Search by class name, not line number; demo entry point changes frequently.

## Contents

Use the Quick start first. Steps 4.1–4.10 are the core ad path; everything marked optional is chosen per partner scope.

- [Fast path — Android + AdMob, first banner in about 30 minutes](#fast-path--android--admob-first-banner-in-about-30-minutes)
- [Quick start — minimum working integration](#quick-start--minimum-working-integration)
- [0. Context — fill in before running](#0-context--fill-in-before-running)
- [Feature coverage matrix — select before Step 2](#feature-coverage-matrix--select-before-step-2)
- [Forbidden (applies to every project)](#forbidden-applies-to-every-project)
- [Working without access to the SDK author](#working-without-access-to-the-sdk-author)
- [Step 1 — Verify the selected SDK release and recipe coverage](#step-1--verify-the-selected-sdk-release-and-recipe-coverage)
- [Step 2 — Audit the current state of the project](#step-2--audit-the-current-state-of-the-project)
- [Step 3 — Write the integration plan into `<PROJECT_PATH>/doc/AD.MD`](#step-3--write-the-integration-plan-into-projectpathdocadmd)
- [Step 4 — Lifecycle requirements (hard rule, applies to every Flutter project)](#step-4--lifecycle-requirements-hard-rule-applies-to-every-flutter-project)
  - [4.0 — Add package and native prerequisites before Dart integration](#40--add-package-and-native-prerequisites-before-dart-integration)
  - [4.1 — Bootstrap order in `main.dart` (do NOT reorder)](#41--bootstrap-order-in-maindart-do-not-reorder)
  - [4.2 — Splash flow (controller is the default)](#42--splash-flow-controller-is-the-default)
  - [4.3 — Splash UI and partner-approved disclosure](#43--splash-ui-and-partner-approved-disclosure)
  - [4.4 — Banner: extend `AdScreen` + edge-to-edge](#44--banner-extend-adscreen--edge-to-edge)
  - [4.5 — App Open when returning to the foreground](#45--app-open-when-returning-to-the-foreground)
  - [4.6 — Interstitial pattern](#46--interstitial-pattern)
  - [4.7 — Rewarded pattern](#47--rewarded-pattern)
  - [4.8 — MREC pattern](#48--mrec-pattern)
  - [4.9 — Native ad pattern](#49--native-ad-pattern)
  - [4.10 — Rewarded Interstitial (optional; AdMob only)](#410--rewarded-interstitial-optional-admob-only)
  - [4.11 — Known SDK limitations to design around](#411--known-sdk-limitations-to-design-around)
  - [4.12 — Adaptive and in-feed placements (optional)](#412--adaptive-and-in-feed-placements-optional)
  - [4.13 — Rewarded preload and host-controlled power (optional)](#413--rewarded-preload-and-host-controlled-power-optional)
  - [4.14 — Sensitive screens, hidden tabs and inline controls](#414--sensitive-screens-hidden-tabs-and-inline-controls)
  - [4.15 — Local house-ad fallback (optional)](#415--local-house-ad-fallback-optional)
  - [4.16 — Advanced controls and monetization modules (choose individually)](#416--advanced-controls-and-monetization-modules-choose-individually)
  - [4.17 — Custom native layouts (AdMob Android/iOS and AppLovin)](#417--custom-native-layouts-admob-androidios-and-applovin)
  - [4.18 — QA, runtime controls and custom-provider boundary](#418--qa-runtime-controls-and-custom-provider-boundary)
- [Step 5 — Scope of replacement (replace only approved ad call sites)](#step-5--scope-of-replacement-replace-only-approved-ad-call-sites)
- [Step 6 — Resolve dependencies, build selected platforms, test selected features](#step-6--resolve-dependencies-build-selected-platforms-test-selected-features)
- [Step 7 — Ad policy and disclosure review](#step-7--ad-policy-and-disclosure-review)
- [Step 8 — Consent (UMP + iOS ATT)](#step-8--consent-ump--ios-att)
  - [8.1 — Google UMP form (review for every selected provider/market)](#81--google-ump-form-review-for-every-selected-providermarket)
  - [8.2 — Optional iOS ATT](#82--optional-ios-att)
  - [8.3 — COPPA (`isAgeRestrictedUser`) — AppLovin/AdMob asymmetry](#83--coppa-isagerestricteduser--applovinadmob-asymmetry)
- [Step 9 — Optional first-install VIP grace + anti-uninstall-bypass guard](#step-9--optional-first-install-vip-grace--anti-uninstall-bypass-guard)
- [Step 10 — Optional VIP management screen UI/UX](#step-10--optional-vip-management-screen-uiux)
  - [10.1 — Optional file structure (adapt to the host app)](#101--optional-file-structure-adapt-to-the-host-app)
  - [10.2 — Add the public VIP key (only if VIP promotions are approved)](#102--add-the-public-vip-key-only-if-vip-promotions-are-approved)
  - [10.2b — Or skip 10.3 entirely: wrap the SDK's `VipRedeemScreen`](#102b--or-skip-103-entirely-wrap-the-sdks-vipredeemscreen)
  - [10.3 — Optional custom VIP UI (only if approved and `VipRedeemScreen` does not meet host r](#103--optional-custom-vip-ui-only-if-approved-and-vipredeemscreen-does-not-meet-host-requirements)
  - [10.4 — Optional animation examples (skip unless approved by product/design)](#104--optional-animation-examples-skip-unless-approved-by-productdesign)
  - [10.5 — Lifecycle checklist for custom VIP UI](#105--lifecycle-checklist-for-custom-vip-ui)
  - [10.6 — Signed VIP redemption + special entries (only if VIP is approved)](#106--signed-vip-redemption--special-entries-only-if-vip-is-approved)
  - [10.7 — Localize VIP strings (only if VIP UI is in scope)](#107--localize-vip-strings-only-if-vip-ui-is-in-scope)
  - [10.8 — Optional entry point from the host UI](#108--optional-entry-point-from-the-host-ui)
  - [10.9 — Optional modules beyond ad surfaces (navigation and SSV recipe)](#109--optional-modules-beyond-ad-surfaces-navigation-and-ssv-recipe)
  - [10.10 — SDK-scoped data erasure (optional, destructive)](#1010--sdk-scoped-data-erasure-optional-destructive)
  - [10.11 — Events and safe diagnostics (optional)](#1011--events-and-safe-diagnostics-optional)
  - [10.12 — Evidence and compliance recipes (optional, local by default)](#1012--evidence-and-compliance-recipes-optional-local-by-default)
  - [10.13 — VIP status, promotion results and revocation (optional)](#1013--vip-status-promotion-results-and-revocation-optional)
  - [10.6a — VIP operator quick start (no SDK checkout needed)](#106a--vip-operator-quick-start-no-sdk-checkout-needed)
- [Step 11 — Partner readiness review & update `<PROJECT_PATH>/doc/AD.MD`](#step-11--partner-readiness-review--update-projectpathdocadmd)
  - [11.0 — Partner release gates](#110--partner-release-gates)
  - [11.0a — Building and checking a release (copy-paste, verified)](#110a--building-and-checking-a-release-copy-paste-verified)
  - [11.1 — Native config](#111--native-config)
  - [11.2 — Bootstrap](#112--bootstrap)
  - [11.3 — Slot integration](#113--slot-integration)
  - [11.4 — Consent + optional VIP](#114--consent--optional-vip)
  - [11.5 — Host conventions and lifecycle](#115--host-conventions-and-lifecycle)
  - [11.6 — Smoke and device-matrix tests (mandatory before partner handoff)](#116--smoke-and-device-matrix-tests-mandatory-before-partner-handoff)
- [Step 12 — Partner handoff report](#step-12--partner-handoff-report)
- [Appendix A — API mapping (Android Kotlin → Flutter Dart)](#appendix-a--api-mapping-android-kotlin--flutter-dart)
- [Appendix B — Where to find more detail](#appendix-b--where-to-find-more-detail)
- [Appendix D — Current compatibility and troubleshooting](#appendix-d--current-compatibility-and-troubleshooting)
- [Appendix E — Historical migration record (verbatim; not current setup)](#appendix-e--historical-migration-record-verbatim-not-current-setup)
- [Appendix F — Semantic-preservation record for the one-file restructure](#appendix-f--semantic-preservation-record-for-the-one-file-restructure)
- [Appendix G — Public API coverage map (types without their own recipe)](#appendix-g--public-api-coverage-map-types-without-their-own-recipe)
- [Single-file completeness gate — SDK owner review before handoff](#single-file-completeness-gate--sdk-owner-review-before-handoff)

## Fast path — Android + AdMob, first banner in about 30 minutes

**Read only this section first.** It gets a new app to a working test banner, a test interstitial and a test rewarded ad on Android. Everything else in this file (iOS, AppLovin, VIP, advanced modules, release) comes after, and only if the partner asked for it. Do not read ahead; do not install anything not named here.

**Before you start, you need nothing from anyone.** Google's public test IDs are already in the snippets. Real ad IDs, AppLovin keys and VIP keys are **not** needed for this path.

| # | Do this | Where the exact text is | You know it worked when |
|---|---|---|---|
| 1 | `flutter create my_app`, then `cd my_app` and `dart pub add applovin_admob_sdk` | Step 4.0(a) | `pubspec.yaml` lists `applovin_admob_sdk` |
| 2 | Make edits 1-4 (edit 2 has two parts) (Kotlin 2.3.0, delete `kotlinOptions`, add `kotlin { compilerOptions }`, `minSdk = 24`, delete `android:taskAffinity=""`). Skip edit 5 (R8 rule) until a release build. | Step 4.0(a2), edits 1-4 | edits copy-paste as shown, no guessing |
| 3 | Add 3 permissions and the AdMob test App ID `ca-app-pub-3940256099942544~3347511713` to `AndroidManifest.xml` | Step 4.0(b) | `flutter build apk --debug` succeeds |
| 4 | Delete `test/widget_test.dart` | Step 4.0(a2), last paragraph | `flutter analyze` is no longer red about `MyApp` |
| 5 | Create `lib/main.dart`, `lib/ad_config.dart`, `lib/splash_screen.dart`, `lib/home_screen.dart`, `lib/privacy_screen.dart` by copying the Dart blocks tagged `main.dart`, `ad_config.dart`, `splash_screen.dart`, `home_screen.dart` (Steps 4.1, 4.2, 4.4) and `privacy_screen.dart` (Step 8.1). Copy whole blocks, change nothing. | Steps 4.1, 4.2, 4.4, 8.1 | `flutter analyze` prints `No issues found` (it stays red until all 5 files exist) |
| 6 | Connect a device or start an emulator, then `flutter run` | Step 4.0(e) | spinner, then Home with a Google "Test Ad" banner at the bottom |
| 7 | Tap the two buttons | Step 4.0(e) | rewarded: test video, then +10 coins. Interstitial: test ad, then the privacy screen |

**If it fails, look here first.**

| Symptom | Cause and fix |
|---|---|
| Build error `Inconsistent JVM-target compatibility` | `jvmTarget` differs from `compileOptions`; make both 17 (Step 4.0(a2) edit 2) |
| Build error mentioning `kotlinOptions` | You skipped deleting it (edit 2) |
| Banner never appears | Device offline, or you are not in a debug build; read `flutter logs` for the reason, do not swap in production IDs (Step 4.0(e)) |
| Interstitial does nothing on first tap | Ad had not loaded yet; wait a few seconds after start-up and tap again |
| Back to launcher after closing an ad | `taskAffinity` was not deleted (edit 4) |
| UMP form appears, then no ad | Normal in a consent region; answer the form (Step 8.1) |

**What this path leaves out on purpose, and where to continue:**

| You also need | Go to |
|---|---|
| Your own production ad IDs | Step 11.0a (release build with `--dart-define`) |
| iOS | Step 4.0(c), then Step 6 |
| AppLovin instead of AdMob | Step 4.2 (`applovin_ad_config.dart`) and Step 8.3 (COPPA rule) |
| MREC, native, in-feed, rewarded interstitial | Steps 4.8 to 4.13 |
| VIP codes | Steps 9, 10 and 10.6a |
| Consent and privacy review | Steps 7 and 8 |
| Final checklist before handing over | Steps 11 and 12 |

## Quick start — minimum working integration

1. Pin approved SDK version and run `flutter pub get` (Step 4.0).
2. Merge required Android/iOS app IDs and native configuration for selected provider/platform; never replace whole manifests (Step 4.0).
3. Before `runApp`, register `AdManager().setNavigatorKey(navigatorKey)`; add `adRouteObserver` and `AdScreenRouteLogger()` to root navigator (Step 4.1).
4. Create splash with `AdReadinessSplashController`; it owns init event ordering, hard cap, splash state and optional splash App Open ad (Step 4.2). Use manual orchestration only for custom ATT/consent timing it cannot express.
5. Add banner on selected screen with `AdScreen` / `AdScreenState` (Step 4.4). Keep placement and trigger unchanged unless product approves.
6. Add interstitial only at an existing natural break; keep safety gates enabled (Step 4.6).
7. Add rewarded only behind explicit user action; grant reward only when `earned == true` (Step 4.7).
8. Keep automatic UMP as single consent owner unless manual flow is explicitly required (Step 8). Never request UMP twice.
9. Run analyze, tests, debug/release builds and selected-device smoke matrix (Steps 6 and 11).
10. Complete handoff evidence and list unverified cases; widget tests do not prove native provider behavior.

MREC, Native, Rewarded Interstitial, Adaptive/In-feed, VIP, SSV, analytics, diagnostics and advanced modules are optional. Select them in feature matrix and follow dedicated recipes only when approved.

Example references: `main.dart` registers navigator key/observers near app setup; `_SplashScreenState` is manual fallback; `ReadinessControllerDemoPage` demonstrates controller; `BannerDemoPage`, `MrecDemoPage`, `NativeDemoPage`, `InterstitialDemoPage`, `RewardedDemoPage` and `RewardedInterstitialDemoPage` demonstrate surfaces. Native references: `example/android/app/src/main/AndroidManifest.xml`, `example/android/app/build.gradle.kts`, `example/ios/Runner/Info.plist` and native-ad factories.

**Example conventions:** GetX, `BaseStatefulState`, `SafeLogger`, and `.tr` appear in historical examples from one host app; they are not SDK requirements. Keep the partner app's existing state management, navigation, localization, and logging. The SDK-specific constraints are called out in each step (navigator setup, splash event ordering, ad safety, consent-before-provider initialization, and optional VIP behavior).

> **Maintenance note:** this file is the partner workflow and step-by-step integration handoff. Whenever the SDK version, ad unit conventions, native config requirements, splash lifecycle, VIP flow, or consent flow changes, update this file at the same time.
>
> **Filling in this template:** Section 0 below is where you record the *consuming* project's own values — SDK version pinned, provider choice, ad unit IDs, bundle ID, native config, logging setup, and so on. Do not carry over IDs, paths, or config from any other project. Every `<...>` placeholder must be filled with values that belong to the project you are integrating into.
>
> This template applies to any **Flutter** project. Before handing it to an AI agent, **fill in every `<...>` placeholder** in Section 0. VIP is optional: integrate it only when the partner's approved product scope requires it. If not approved, skip Steps 9–10 entirely and set `firstInstallVipGrace: FirstInstallVipGrace.disabled`; do not ship first-install grace by default. If enabled, use the SDK's signed-key flow or the pre-built `VipRedeemScreen`; never add a plaintext or Base64-obfuscated key whitelist. First-install grace is SDK-managed only when explicitly approved.
>
> **Core rules (apply only to the NEW code this integration generates — the splash screen, VIP screen, and any other file the agent writes/edits for this task — not a mandate to refactor the rest of the existing project):**
> 1. Preserve the host app's state-management conventions; use its existing reactive pattern where needed.
> 2. Use null-safe Dart patterns and avoid force-unwrapping values that can legitimately be absent (for example, `AdManager().vip` before initialization).
> 3. Manage lifecycle-bound resources (`Timer`, controllers, subscriptions) with the host app's existing conventions and dispose/cancel them with their owning widget.
> 4. **Provider choice is partner-owned**: select `AdProvider.appLovin` or `AdProvider.admob` only after confirming the partner's account, inventory, mediation setup, and regional policy. The SDK selects its provider at initialization and does not silently fail over in-session.
> 5. **State management and navigation**: preserve the partner app's existing framework and localization approach; do not add GetX or another framework solely for this SDK integration.
> 6. **Logging**: wire `AdConfig.onLog` to the partner's approved logger and apply its retention/access policy. Do not log ad identifiers, consent strings, user-entered VIP codes, or other personal data unless the partner's privacy/security review explicitly approves the fields and purpose. (Use the logger convention already established by the partner project; redact ad identifiers, consent strings, and user-entered VIP codes.)

---

## 0. Context — fill in before running

Follow this file in the consuming Flutter project; source checkout is not required for the documented recipes. Paths starting with `lib/`, `android/`, or `ios/` below belong to that consuming app unless explicitly prefixed with `packages/ad_sdk/`. SDK source/example paths are optional references available after dependency download, not files the partner must receive separately. If a selected feature has no complete recipe here, record it as blocked; do not infer the missing implementation from its name.

| Field | Value |
|---|---|
| Current project (cwd, absolute path) | `<PROJECT_PATH>` |
| Dart package name (from `pubspec.yaml: name`) | `<DART_PACKAGE_NAME>` |
| Current state management | `<existing framework/pattern, or none>` |
| Default locale | `<vi_VN \| en_US \| ...>` (default to whatever the project already targets) |
| `applovin_admob_sdk` version | **`3.6.2`** unless the partner names another. This guide was verified against 3.6.2. To use a newer one, pin it in `pubspec.yaml` (Step 4.0) and skim that version's CHANGELOG on pub.dev first. |
| Library's own spec files | Obtained with `dart pub unpack` (see "How to use this document"): `README.md`, `CHANGELOG.md`. Optional deeper reading; this file does not depend on them. |
| Sample app | `example/lib/main.dart` inside the unpacked package (demo pages, one page per feature); optional |
| Debug build target | `flutter build apk --debug` (Android) + `flutter build ios --simulator --debug --no-codesign` (iOS, if targeting iOS) — both must succeed |
| Release build target | `flutter build apk --release --analyze-size` (Android); compare against the partner's approved size budget/baseline, if one exists |
| Primary provider (active at runtime) | **AdMob** unless the partner names AppLovin MAX. If you receive no instruction, build and test with AdMob test units; that needs no partner credentials. |
| Alternate provider | `<optional; provider is selected at initialization, not switched automatically during a session>` |
| AppLovin SDK key | `<only if AppLovin is selected; store in CI/build secret and provide as `--dart-define=APPLOVIN_SDK_KEY=...`; embedded in binary at build>` (86 chars, from `dash.applovin.com → Account → Keys → SDK Key`) |
| AppLovin ad-unit IDs (each enabled format/platform) | `<required only when AppLovin is selected; keep Android/iOS units separate>` |
| AdMob `APPLICATION_ID` | `<required by the bundled google_mobile_ads/UMP setup even when AppLovin is the active provider; use partner app ID, or Google test app ID for a test-only app>` |
| AdMob ad-unit IDs (each enabled format/platform) | `<required only if AdMob is selected; use platform-specific production IDs in release and test IDs only in test builds>` |
| AppLovin MREC/native IDs | `<per platform, only if those formats are selected; custom native builder is optional>` |
| AdMob rewarded-interstitial IDs | `<separate Android/iOS AdMob units, only if Rewarded Interstitial is selected>` |
| AdMob MREC/native IDs | `<per platform, only if selected; custom NativeAdFactory is separate Android/iOS host work>` |
| Privacy Policy URL | `<partner-approved privacy policy URL if required by enabled providers/regions or VIP UI>` |
| Splash hard cap (seconds) | **8** unless the partner states another value; must equal `AdConfig.splashMaxDuration` |
| First-install VIP grace | `<default is 24h in release; partner integrations should use disabled unless explicitly approved>` |
| VIP feature | `<enabled only if product requires it; otherwise skip VIP UI/key setup>` |
| VIP signing public key | `<if VIP is enabled: embed the Ed25519 public key only; keep the private signing key in an approved secret manager, never in the app/repository>` |
| VIP activation | `<if VIP is enabled: use redeemSignedKey or VipRedeemScreen; activation requires network, VIP works offline after activation>` |

**Hard rules for Section 0**:

1. Choose exactly the active ad provider approved for this build and configure only that provider's ad-unit IDs. The Android/iOS AdMob `APPLICATION_ID` metadata is still required by `google_mobile_ads`/UMP initialization even when AppLovin serves ads; use the partner's AdMob App ID, or Google's test App ID only for an explicitly test-only app with no production AdMob account. Never substitute a test ad-unit ID for a partner's production unit. Keep provider app IDs/ad units correct per platform.
2. For AppLovin builds, read the SDK key from the CI/build secret channel into `--dart-define=APPLOVIN_SDK_KEY=...`; the key is embedded in the app binary because the native SDK needs it at runtime. Do not commit it in Dart/Gradle source or confuse it with the VIP private signing key (which must never ship).
3. Include `gma_mediation_applovin` only when the partner uses AppLovin as an AdMob mediation network. Direct AppLovin (`AdProvider.appLovin`) and AdMob-only integrations do not need it.
4. If any required field is missing, ask for it and pause that branch. Do not infer production identifiers, bundle IDs, provider choice, privacy/legal copy, backup policy, VIP grants, or tracking purpose text. If VIP is out of scope, do not ask for VIP signing material.
5. Confirm the approved release and matching `pubspec.lock` version before editing. For an upgrade, review its release notes and native constraints; for the documented baseline, follow the native setup and migration checks in this file. `flutter pub outdated` alone does not establish the approved release.

---

## Feature coverage matrix — select before Step 2

Use this table to decide what the partner app will integrate. **Core** means needed for any ad-serving integration; **select** means choose only the formats/features in approved product scope; **optional** means no code/config is needed unless the partner explicitly adopts it. The SDK exposes more APIs than most apps should wire on day one.

| Area | Scope | In-file recipe | Provider/platform notes |
|---|---|---|---|
| Provider config, startup, splash | Core | Steps 0, 4.0–4.2 | One provider per initialization; controller default; manual only for ATT/custom consent/remote-safety init |
| App Open splash/resume | Select | Steps 4.2, 4.5, 4.11 | `bypassSafety` only at approved splash; resume is SDK-owned; AppLovin has no freshness timestamp |
| Banner / MREC / Adaptive | Select | Steps 4.4, 4.8, 4.12, 4.14 | Hidden tabs need `active`; MREC fixed 300×250 |
| Native default layout | Select | Step 4.9 | Default needs no host native code |
| Native custom layout | Optional | Step 4.17 | AdMob Android/iOS host factories; AppLovin Flutter asset widgets |
| In-feed list, house ads, inline controls | Optional | Steps 4.12, 4.14, 4.15, 4.18 | Verify route/tab lifecycle and local fallback behavior |
| Interstitial / rewarded / rewarded interstitial | Select | Steps 4.6, 4.7, 4.10 | Reward only when `earned == true`; Rewarded Interstitial is AdMob only |
| Reward SSV | Optional | Step 10.9 | Backend owns authoritative verification |
| Consent, UMP, ATT, COPPA, CCPA | Required when applicable | Steps 8, 4.18 | One consent owner; AppLovin writes are fire-and-forget; COPPA differs by provider |
| Safety/placements/retry/remote safety | Core defaults; optional overrides | Steps 7, 4.16 | Remote-safety initialization requires the manual startup branch |
| Signed feature flags and compatibility matrix | Advanced/operations | Step 4.16 | Kill switch only; compatibility data is reviewed test-matrix evidence |
| VIP, trial, promotion keys, CRL | Optional | Steps 9, 10.1–10.8, 10.13, D.4 | Promotions are not paid licenses; activation requires network |
| Monetization observers and advice modules | Optional | Step 4.16 | Each module separate; CohortOptimizer has no public construction path |
| Events, diagnostics, evidence, flight recorder, provenance | Optional | Steps 10.11, 10.12 | Privacy-owner approval; local by default |
| Data erasure | Optional destructive | Step 10.10 | SDK-scoped erase only; host exports require separate deletion |
| QA scenario/fake adapter/custom-provider boundary | QA/advanced | Step 4.18 | No production adapter registration API exists |
| Native build/release validation | Core QA | Steps 6, 11, D | Compile/analyze is not device, policy or rendering proof |
| Test devices and release validation | Core QA | Steps 6, 11, D.2 | The SDK carries a built-in QA test-device hash fleet that stays active in release builds; register partner test devices in the provider console; AdMob test IDs and test geography must not ship as release config |
| Connectivity and recovery | Core runtime | Steps 11.6, D.2 | Test offline cold start, mid-load loss and reconnect with every selected format and mounted inline widget; the SDK retries known surfaces but host owns connectivity UX and monitoring |
| Navigation and inline lifecycle | Core for mounted ads | Steps 4.1, 4.4, 4.14 | Add `adRouteObserver` + `AdScreenRouteLogger()` (also to nested navigators); use `showAdSafeModalBottomSheet`; overlays and `IndexedStack` need explicit wiring |

Record selected rows and explicit exclusions in `<PROJECT_PATH>/doc/AD.MD` before Step 2. For every selected row, identify owner screen/file, trigger, provider, platforms, required identifiers/native files, and a verification case. Do not add optional modules merely because they appear in the public API.

## Forbidden (applies to every project)

Items marked partner approval below are release gates, not optional documentation suggestions. Never infer a provider, VIP entitlement, backup policy, or consent policy from the sample app.

- Adding a new ad slot beyond the slots that already exist in the current code.
- Refactoring code unrelated to the ad integration.
- Bumping or downgrading the SDK version outside the range settled in Section 0.
- Changing `AdConfig.provider` without partner approval. Select only a provider the partner has configured and approved; the SDK does not perform silent in-session provider failover.
- Treating a previous review or a passing build as proof that changed integration code still works. Re-read changed sections and rerun affected checks when an API, lifecycle or privacy decision changes.
- Adding a new interstitial trigger (e.g. "show after every action X") if the existing code doesn't already do that.
- Putting a Google test ad-unit ID or a placeholder into a **release** build when a production ID exists. If the production ID is not available yet, ship nothing to production and record the blocker in Step 12.
- Bypassing `AdSafetyParams.auto` anywhere except the one sanctioned spot: the splash App Open ad (`bypassSafety: true`).
- Re-implementing first-install VIP grace in app code. If product and security owners approve VIP grace, configure the SDK's `firstInstallVipGrace` explicitly; otherwise use `FirstInstallVipGrace.disabled`. Never silently enable a free entitlement in a partner app.
- Showing an App Open Ad **directly on a bare splash screen** (this violates AdMob's "Disallowed interstitial implementations" policy) — it must go through the flow `loadAppOpenAd → AdLoadingDialog.showAdBuffer → showAppOpenAd(bypassSafety: true)`.
- Subscribing to `WidgetsBindingObserver` lifecycle yourself to show App Open on resume — the SDK already hooks this; double-subscribing means double-showing.
- Adding an Android/iOS permission beyond the whitelist (see Step 2 + Step 11), except for an ad-related permission with a clear justification (e.g. `ACCESS_WIFI_STATE` for AppLovin GeoTargeting). Any non-ad-related permission → ask the user first.
- Introducing lifecycle leaks, unsafe nullable-state access, or a parallel state-management framework solely to satisfy this template. Existing host conventions such as `setState`, `late`, or a chosen framework are not prohibited; review changed code for actual lifecycle/nullability bugs instead of blanket grep bans.
- Adding new user-facing consent/disclosure strings without using the host app's existing localization mechanism.

---

## Working without access to the SDK author

This section answers "what do I do when I do not have an answer" so you never need to wait for one.

| Missing input | What to do |
|---|---|
| No production AdMob IDs or account yet | Build everything with Google's public **test** App ID and test ad units (Step 4.0, Step 4.2). Mark the release gate "blocked: awaiting production IDs" in Step 12; do not guess IDs and do not ship test IDs (the SDK blocks them in release). |
| No AppLovin credentials | Use AdMob, or stop at "AppLovin blocked: no SDK key / ad units". AppLovin cannot be tested without them. |
| No privacy-policy URL, ATT wording, legal text | Use the placeholder, record it as an open item in Step 12, and do not ship to production with it. The SDK works without them in test builds. |
| Unsure whether the app is child-directed | Follow the decision rule in Step 8.3. If the answer is not obvious, treat it as an open legal question in Step 12 and use AdMob. |
| No physical device / EEA device | Build, analyze and run the Dart/unit checks, then mark device checks "not run" in Step 12 with the reason. Never mark a device check passed without running it. |
| A step fails | Search this file for the exact error text. Then check Appendix D.2 (common issues). Then unpack the SDK (see above) and read `README.md` and `example/lib/main.dart` for the same feature; the demo app is a working reference. |
| The guide and the SDK disagree, or an API in this guide does not exist in your pinned version | Trust the SDK's own `CHANGELOG.md` for that version, keep a note of the difference in Step 12, and continue with the closest working option rather than stopping. |
| Nothing above helps | Open an issue at the SDK's GitHub repository (Appendix D.3 lists the exact repo URL and what to include: this file's Step number, the pinned version, redacted `roy93~` logs). Continue with the rest of the integration while you wait. |

## Step 1 — Verify the selected SDK release and recipe coverage

> **New app with no existing ads? Skip Steps 1, 2 and 3 and go to the Fast path (top of this file).** These three steps are for projects that already have ad code or need a written plan.

This step does not require the junior partner to read SDK source. Use the in-file recipes for implementation; the source/README/example navigation below is optional for reviewers. Version metadata and release notes must be checked when upgrading beyond the version this guide was verified against. If a feature is listed without an executable host recipe, label it blocked rather than claiming it is fully documented.

**Optional reviewer reference map (not a substitute for missing steps):**

- Package contents for reference: `~/.pub-cache/hosted/pub.dev/applovin_admob_sdk-<VERSION>/` after `flutter pub get`, or the folder created by `dart pub unpack` (see "How to use this document").
- Fetch `https://pub.dev/api/packages/applovin_admob_sdk` to verify the latest stable version and update Section 0 if needed.
- Optional reference: the unpacked package's `README.md` (Quick start, Configuration reference, Public API). These are the SDK touchpoints implemented below:
  - Bootstrap: `AdManager().setNavigatorKey(key)`, `adRouteObserver`, `AdScreenRouteLogger()`, `SimpleEventBus().listen`, `AdManager().initialize(config:, onComplete:)`.
  - Splash flow: `markSplashActive` / `markSplashInactive` / `incrementSplashCount` / `countInitSplashScreen`, `loadAppOpenAd`, `AdLoadingDialog.showAdBuffer`, `showAppOpenAd(bypassSafety: true)`.
  - Per-screen: `class XxxScreen extends AdScreen` → `class _XxxState extends AdScreenState<XxxScreen>` gives you `buildBanner()`, `showInterstitialAd(onDone:)`, `showRewardedAd(onEarnedReward:)`.
  - VIP (only if the product needs it): `AdManager().vip` is nullable. For promotions, use `redeemSignedKey` or `VipRedeemScreen` with the public key; activation requires network and VIP works offline after activation. Never place the private key or a plaintext/Base64 key whitelist in the app. `addVip` is for trusted purchase/reward flows, not validating user-entered promo codes. Check this SDK version's README/CHANGELOG for stacking, revoke, and expiry APIs.
  - Rewarded while already VIP: `showRewardedAd(bypassVipGuard: true, ...)` lets a VIP user **voluntarily** watch a real rewarded ad to extend their window (the SDK loads the ad on-demand and shows a loading dialog; default `false` keeps the surface suppressed). Configurable `onDemandLoadTimeout` (default 15s). `showRewardedAd` is already **re-entrancy-safe** (blocks double-tap while loading/showing). (Available in current SDK releases — check `CHANGELOG.md` for the exact version.)
  - Consent: `AdManager().requestUmpConsent(testMode:, debugGeography:, testIdentifiers:)` (Google UMP, a certified CMP, wired by default via `AdConfig.autoRequestUmpConsent: true`) + `CcpaOptOutToggle` for the separate CCPA "Do Not Sell" axis. No built-in GDPR consent dialog; use the selected certified CMP/UMP flow.
  - Safety: `AdSafetyParams.auto` (default, do NOT override).
  - Logger pipe: `AdConfig.onLog: (level, tag, msg) { ... }`.
- Optional version check: when you move to a newer version than this guide's, read that version's `CHANGELOG.md` on `pub.dev/packages/applovin_admob_sdk/changelog` first.
- Use the README chapter matching selected feature; don't ask junior integrators to infer feature steps from internal architecture docs:
  - Setup/provider/bootstrap/formats → `README.md` → [Quick start](README.md → Quick start), Configuration reference, Pitfalls
  - Consent/UMP/ATT/CCPA/COPPA/privacy options → Consent & compliance
  - VIP/signed keys/CRL/Android limits → VIP system, Known limitations
  - Rewarded server verification → Server-Side Verification
  - Native ad layouts/factories → Native Ad (v1)
  - Arbitrator/fill-rate/waterfall/cohort/failover advice → Monetization Arbitrator, Fill-rate monitor, Other advanced opt-in modules
  - Diagnostics/self-check/exports → Diagnostics & integration self-check
- For runnable examples, open only the matching class in `example/lib/main.dart`; the file is intentionally long so pub.dev can display a complete example entry point. Current examples include: ad formats/lifecycle (`BannerDemoPage`, `BannerAdaptiveSizingDemoPage`, `MrecDemoPage`, `NativeDemoPage`, `InterstitialDemoPage`, `RewardedDemoPage`, `RewardedInterstitialDemoPage`, `AppOpenDemoPage`, `AdaptiveSurfaceDemoPage`, `InlineAdControllerDemoPage`); consent (`ConsentDemoPage`, `CcpaToggleDemoPage`, `I18nPresetDemoPage`); VIP and SDK data (`VipDemoPage`, `ClearSdkDataDemoPage`); controls (`SafetyDemoPage`, `PlacementThrottleDemoPage`, `RemoteSafetyDemoPage`, `ReadinessControllerDemoPage`); operations (`ComplianceDemoPage`, `DiagnosticsDemoPage`, `EventsDemoPage`, `LogViewerDemoPage`, `RevenueDemoPage`, `StatePanelDemoPage`, `TestDeviceHashDemoPage`, `CustomOverlayDemoPage`). Search the current file for each class before using it; this navigation list is not a substitute for the public API reference.

**Required output from Step 1**: return (a) a one-line summary of the installed package version, (b) one row per feature-family in the matrix stating public entry point, host action, and optional/provider limitations, and (c) a clear list of behaviors the SDK owns automatically versus behaviors the host must implement. Do not use a 10-line cap if that would omit an exported feature family; link to the exact README chapter for details.

## Step 2 — Audit the current state of the project

Answer 8 questions (yes/no + evidence as `file:line`):

1. Is `applovin_admob_sdk` already present? Record the current package/version and existing ad integrations; do not remove a provider or old implementation until every caller and intended migration scope is identified.
2. What does `main.dart` call during startup? Record the navigator key, `navigatorObservers`, and current splash/init entry point with `file:line` evidence.
3. Does splash use `AdReadinessSplashController` (default) or the manual fallback? If manual: does it call `initialize` rather than `main()`, register `SimpleEventBus().listen` before init, and implement the hard-cap timer plus hot-restart guard (`countInitSplashScreen > 1`)?
4. Which screens show each currently used format, what triggers them, and which SDK API is used? Record existing `AdScreen`/`AdScreenState` usage; do not add ad placements or change triggers during migration.
5. **Does partner-approved scope include VIP or first-install grace?** If not, record both as disabled and skip the corresponding implementation/UI steps. If yes, record approved grant types, activation policy, duration, and Android backup/privacy decision before coding.
6. Which state-management, navigation, localization, and logging systems does the host app already use? Keep these; do not add GetX or create a new framework layer solely for this integration.
7. Which existing base widget/state or lifecycle helpers can the integration reuse? Reuse if useful; do not create `BaseStatefulState` or other project-wide abstractions merely to match this template.
8. Which logger does the host app use, and what fields/retention are approved? Wire `AdConfig.onLog` to that logger without logging raw consent strings, user-entered VIP codes, or personal data.

## Step 3 — Write the integration plan into `<PROJECT_PATH>/doc/AD.MD`

Target file: `<PROJECT_PATH>/doc/AD.MD` (create it if it doesn't exist yet).

**Short form for a brand-new app or a one-day test integration.** If there is no existing ad code to replace, you may write a short `AD.MD` instead of the four full sections below: (a) one line stating the scope ("new app, Android + AdMob test units, formats: banner, interstitial, rewarded, splash App Open: no"), (b) the list of files you created, (c) the answers to the three decisions in Step 4.2, (d) open items (production IDs, privacy-policy URL, legal wording) and (e) the test results you actually ran. Skip the "Old API replaced" and "Before/after" tables, because nothing is being replaced. Use the full sections whenever you are modifying an app that already shows ads.

It must contain these sections (full form, for existing apps):

**(1) Touchpoint table** — one row per slot. If a slot doesn't exist yet in the project, write `(none yet)` in the "Old API replaced" column:

| Feature/API | In scope? | Host file / owner | Trigger/config | Provider/platform caveat | Verification case | README reference |
|---|---|---|---|---|---|---|
| SDK bootstrap + splash | Yes | `<main.dart>`, `<splash file>` | `setNavigatorKey` before `runApp`; register observers; initialize from splash with hard cap | Choose one UMP owner; don't manual-call UMP if auto UMP is enabled | Cold start, init success/failure, timeout, no duplicate init event | Quick start / Consent & compliance |
| App Open (splash) | `<yes/no>` | `<splash file>` | Existing splash trigger only; `loadAppOpenAd → showAdBuffer → showAppOpenAd(bypassSafety: true)` | `bypassSafety` only at this splash call | Ad available/unavailable, dismiss, hard cap | Quick start / Pitfalls |
| App Open (resume) | `<yes/no>` | SDK lifecycle | SDK auto via `WidgetsBindingObserver`; never call manually | Provider freshness differs; modal/overlay edge cases below | Background/resume, modal on top | Quick start / Pitfalls |
| Banner | `<yes/no>` | `<screen/file>` | Existing placement; `buildBanner()` or `BannerAdWidget` | Verify approved provider unit IDs and visible placement | Load, route away/back, rotate/resize | Quick start |
| MREC | `<yes/no>` | `<screen/file>` | Existing placement; `buildMrec()` or `MrecAdWidget` | Fixed 300×250 | Load, route/off-screen lifecycle | Quick start |
| Native | `<yes/no>` | `<screen/file>` | Existing feed/card placement; `buildNative()` or `NativeAdWidget` | AdMob custom layout requires native factory; AppLovin builder differs | Default/custom factory loads on each selected provider | Native Ad (v1) |
| Interstitial | `<yes/no>` | `<screen/file>` | Keep existing user-flow trigger; `showInterstitialAd(onDone:)` | Respect safety gate; no new frequency trigger | Eligible, blocked, dismiss | Quick start / Configuration |
| Rewarded | `<yes/no>` | `<screen/file>` | Explicit user action; `showRewardedAd(onEarnedReward:)` | Grant reward only when `earned == true`; SSV optional for authoritative server reward | Earned/not-earned, unavailable, repeated tap | SSV for rewarded ads |
| Rewarded Interstitial | `<yes/no>` | `<screen/file>` | User action and pre-ad disclosure | AdMob only; don't promise this format for AppLovin | AdMob load/show/disclosure; AppLovin excluded | README API / example demo |
| VIP / first-install grace | `<yes/no>` | `<screen/config>` | Only with product/security approval | Disabled by default in partner config unless approved; Android replay/backup trade-offs | Signed-key cases and grace expiry only if enabled | VIP system / Known limitations |
| Revenue/events | `<yes/no>` | `<analytics adapter>` | Subscribe to `AdManager().events` only if partner needs analytics | Partner owns analytics endpoint, retention and dedupe | Revenue event fields, consented logging | Public API |
| SSV / advanced modules | `<yes/no>` | `<partner backend or module owner>` | Add only selected modules from feature matrix | SSV verification/remote config are partner backend responsibilities | Backend signature/replay tests or module-specific checks | SSV / Other advanced opt-in modules |

Keep one row per existing placement. `In scope? = no` means leave old behavior untouched and do not add a slot. Add the exact SDK API, test/verification case, and code owner before editing.

**(2) Step-by-step plan** — plan only the in-scope work: setup pubspec + native config, app init wiring + consent + ATT, splash flow, enabled ad placements/triggers, and optional VIP UI/config/i18n only when partner-approved. Each step should state which files get edited, which functions get added, and which lines get removed.

**(3) Before/after comparison table** — at least 8 rows (Provider, Architecture, App Open lifecycle, Consent UI + UMP, Memory leak risk, Frequency cap, VIP support, Banner pause/resume).

**(4) Information still needed from the user** — list only required values for the approved scope: selected provider credentials/ad unit IDs, target platforms, enabled formats/placements, privacy-policy URL if required, splash hard-cap, and target markets/age groups for consent review. If VIP is approved, ask for the public signing key and activation/grant policy; never request or embed the private signing key. Ask before adding any missing third-party package or changing backup policy.

## Step 4 — Lifecycle requirements (hard rule, applies to every Flutter project)

### 4.0 — Add package and native prerequisites before Dart integration

Do these steps in the consuming app root. Fill every placeholder from Section 0 first. Do not replace entire manifests/plists; merge only the shown entries into existing app configuration.

**(a) `pubspec.yaml`** — the package is hosted on **pub.dev**; no git or path dependency is needed. Look up the current stable version once (`dart pub add applovin_admob_sdk` writes it for you, or open `https://pub.dev/packages/applovin_admob_sdk`), then keep that exact version in `pubspec.yaml` for the whole integration. This guide was verified against **3.6.2**; if you pin a newer version, read its changelog on pub.dev before using version-specific steps.

```yaml
dependencies:
  applovin_admob_sdk: ^3.6.2   # replace with the version you selected
  # Only AppLovin served through AdMob mediation (not direct AppLovin):
  # gma_mediation_applovin: <PARTNER_APPROVED_COMPATIBLE_VERSION>
```

Run:

```bash
flutter pub get
```

Do not separately add `google_mobile_ads`, `applovin_max`, `app_tracking_transparency`, or UI/state-management packages just because the SDK/example uses them transitively. Add `gma_mediation_applovin` only for the mediation branch. Current package source supports Flutter `>=3.38.1`, Dart `>=3.10.0`, and constrains `google_mobile_ads` to `>=9.0.0 <9.1.0`; verify the selected published release's constraints before relying on these values.

**(a2) Android build files — exact edits for a project created with `flutter create`.** The first four edits are required for every build and the fifth for shrunk release builds; each one fixed a real build failure when the guide was tried on a fresh app (Flutter 3.41.9 template). Skip an edit only if its "before" text is already absent.

1. `android/settings.gradle.kts` — raise the Kotlin plugin to 2.3.0 or newer (Google Mobile Ads 9.0.0 needs it):

   ```diff
   -    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
   +    id("org.jetbrains.kotlin.android") version "2.3.0" apply false
   ```

2. `android/app/build.gradle.kts` — delete the whole `kotlinOptions { ... }` block (Kotlin 2.3 rejects it) and add a `kotlin { compilerOptions { ... } }` block **after the `android { }` block**. The `jvmTarget` must equal `compileOptions` (17 on the current template):

   ```diff
        compileOptions {
            sourceCompatibility = JavaVersion.VERSION_17
            targetCompatibility = JavaVersion.VERSION_17
        }
   -
   -    kotlinOptions {
   -        jvmTarget = JavaVersion.VERSION_17.toString()
   -    }
   ```

   ```kotlin
   kotlin {
       compilerOptions {
           jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
       }
   }
   ```

   If your project uses Java 11, use `JVM_11` instead. A mismatch fails with `Inconsistent JVM-target compatibility`.

3. `android/app/build.gradle.kts` — the SDK needs `minSdk` 24 or higher:

   ```diff
   -        minSdk = flutter.minSdkVersion
   +        minSdk = 24
   ```

4. `android/app/src/main/AndroidManifest.xml` — **delete** `android:taskAffinity=""` from the `MainActivity` `<activity>` element. Flutter's template adds it, and with it an interstitial or App Open closed after the user pressed Home can drop the user at the launcher instead of your app. Keep every other attribute:

   ```diff
          android:launchMode="singleTop"
   -      android:taskAffinity=""
          android:theme="@style/LaunchTheme"
   ```

5. **Release builds only** — AppLovin's bundled ad-verification library triggers an R8 "Missing class `com.amazon.privacypass...`" error when you build a release with code shrinking on, even if you never use AppLovin. Add `android/app/proguard-rules.pro`:

   ```text
   # Optional Amazon Privacy Pass classes referenced by the bundled IAB OMID library.
   -dontwarn com.amazon.privacypass.**
   ```

   and enable shrinking in the `release` block of `android/app/build.gradle.kts` (skip this if your project already sets `isMinifyEnabled = true` and `proguardFiles(...)`; just add the rule to your existing rules file):

   ```kotlin
   buildTypes {
       release {
           isMinifyEnabled = true
           isShrinkResources = true
           proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
           // keep your existing signingConfig line here
       }
   }
   ```

   With a default `flutter create` project (shrinking off) you will not see the error until you turn shrinking on; turn it on, since unshrunk release builds are large. A release build was verified to succeed with exactly these edits.

Then delete the template's `test/widget_test.dart` in a **new** app (it references the `MyApp` class that Step 4.1 replaces, so `flutter analyze` and `flutter test` fail until it is removed). Create all four files from Steps 4.1, 4.2 and 4.4 (`main.dart`, `ad_config.dart`, `splash_screen.dart`, `home_screen.dart`) before running `flutter analyze`: each imports the others, so analysis is red until the set is complete.

**(b) Android permissions and app ID** — edit `android/app/src/main/AndroidManifest.xml`. These are fragments to merge into the existing elements; do not paste the comment markers as tags or replace the whole manifest.

Add the permissions as direct children of the existing `<manifest>`:

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
<uses-permission android:name="com.google.android.gms.permission.AD_ID" />
```

Add the App ID metadata inside the existing `<application>`:

```xml
<meta-data
    android:name="com.google.android.gms.ads.APPLICATION_ID"
    android:value="<ADMOB_APPLICATION_ID_OR_TEST_ONLY_ID>" />
```

Use the partner's AdMob App ID when one exists. Google's public test App ID is only for a test-only app/build that will not serve production ads; do not ship it in production. For AppLovin, do not add an `applovin.sdk.key` manifest entry: pass the SDK key to `AppLovinConfig.sdkKey` in Step 4.2 via the partner-approved secret/config mechanism. Keep any existing `android:taskAffinity` non-empty; see README → Pitfalls.

Set `minSdk = 24` in the app's existing Gradle file. With current GMA 9.0.0, set Kotlin Gradle plugin `>=2.3.0` in `android/settings.gradle.kts`; if upgrading from older Kotlin, replace removed `kotlinOptions { jvmTarget = ... }` with the `kotlin { compilerOptions { ... } }` snippet in Step 11.1.

**(c) iOS identifiers and deployment target** — only if you ship on iOS. Merge into `ios/Runner/Info.plist` (inside the top-level `<dict>`; do not replace the file):

```xml
<key>GADApplicationIdentifier</key>
<string><ADMOB_APPLICATION_ID_OR_TEST_ONLY_ID></string>
<!-- Only when the partner approves an App Tracking Transparency prompt: -->
<key>NSUserTrackingUsageDescription</key>
<string><PARTNER_APPROVED_LOCALIZED_TRACKING_PURPOSE></string>
```

- **App IDs.** AdMob test App IDs (Google's public ones, safe for test-only builds): Android `ca-app-pub-3940256099942544~3347511713`, iOS `ca-app-pub-3940256099942544~1458002511`. Production builds use the partner's own App ID from the AdMob console (an App ID contains `~`; an ad-unit ID contains `/`).
- **`AppLovinSdkKey` is not required.** The SDK passes `AppLovinConfig.sdkKey` from Dart to the native AppLovin SDK, so do **not** add an `AppLovinSdkKey` entry to `Info.plist` (it would only put the secret into a committed file). Supply the key as a dart-define (Step 4.2).
- **ATT purpose text.** iOS shows the system prompt only if this key exists, and the text is reviewed by Apple and your privacy owner, so the partner must approve the wording. Example draft (not legal text): "This identifier is used to deliver personalised ads." Localize it per language through `InfoPlist.strings`.
- **Podfile.** Set `platform :ios, '13.0'` in `ios/Podfile`, then run `(cd ios && pod install)`. If the project has no `ios/` folder, create it first with `flutter create --platforms=ios .` from the app root; that command also re-creates `test/widget_test.dart`, so delete it again.
- **What you will see on first run (iOS Simulator, observed).** The app launches and the log shows `initialize start, provider=admob`. A first-run privacy explainer dialog (UMP message) can cover Home and keeps the banner from loading until the user taps **Continue**; that is not an integration failure. While it is open, `_initBanner` logs `AdManager not initialised yet` and the splash budget (8s) may expire first. The iOS Simulator does not give reliable UMP evidence, so verify consent on a real iPhone (Step 11). On a `--no-codesign` Simulator build you may also see `VipManager secure storage read FAILED ... retrying` (retries at 2s, 10s, 45s). The cause was not confirmed; it appeared only on the unsigned Simulator build, so re-check on a signed device build before treating it as a defect.
- **SKAdNetwork.** Add a `SKAdNetworkItems` array so ad networks can attribute installs. Shape (one `<dict>` per network):

  ```xml
  <key>SKAdNetworkItems</key>
  <array>
    <dict>
      <key>SKAdNetworkIdentifier</key>
      <string>cstr6suwn9.skadnetwork</string>
    </dict>
    <!-- one dict per identifier -->
  </array>
  ```

  The complete lists change over time, so copy them from the official sources instead of from memory: Google's list at `developers.google.com/admob/ios/3p-skadnetworks` and, for AppLovin, the SKAdNetwork IDs in AppLovin's documentation. Merge both into **one** array and remove duplicates. If you have the SDK's example (obtained with `dart pub unpack`, Step 10.6a), its `example/ios/Runner/Info.plist` holds a long array (about 150 entries; the exact count changes per release) you can use as a starting point. Compare against your unpack as the baseline: `plutil -p ios/Runner/Info.plist | grep -c skadnetwork`.

**(d) Resolve before proceeding:** run `flutter pub get`; if mediation or native dependency versions changed, run `pod install` and build both Android and iOS Simulator before proceeding. A successful Dart dependency solve or CocoaPods resolve alone is not a successful native build; see Step 6 and Appendix D.1.

**(e) First run on a device (what you should see).** After the five edits above and Steps 4.1–4.4 and 8.1 (create `main.dart`, `ad_config.dart`, `splash_screen.dart`, `home_screen.dart`, `privacy_screen.dart`):

```bash
flutter pub get
flutter analyze            # expect: No issues found
flutter run                # a debug build on a USB device or emulator
```

Expect, in order: a spinner splash for a few seconds, then the Home screen with a banner at the bottom (a Google "Test Ad" banner), a coin counter in the app bar, and two buttons. Tapping the rewarded button shows a Google test video and, when you finish it, adds 10 coins. Tapping the privacy button shows an interstitial test ad (the first one needs the ad to have loaded, so wait a few seconds after start-up) and then opens the privacy screen. To read the SDK's own log lines run `flutter logs` or `adb logcat | grep "roy93~"`.

If the banner stays blank: check the device is online, that you used a Google **test** unit in a debug build, and that the log shows `consent`/`canRequestAds` as allowed (Step 8.1). A first start in a region that needs consent shows the consent form before any ad. If an ad format never loads in a debug build, read the log for the reason; do not switch to production IDs to "fix" it. This sequence was verified to build and analyze cleanly; displaying real test creatives needs a device, which this guide's verification did not have.

### 4.1 — Bootstrap order in `main.dart` (do NOT reorder)

Create `lib/main.dart` with the following shell only for a new app. In an existing app, merge its navigator wiring; do not replace routing/state-management setup. `splash_screen.dart` and `home_screen.dart` are defined below.

<!-- snippet: main.dart -->
```dart
import 'package:flutter/material.dart';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'splash_screen.dart';

final navigatorKey = GlobalKey<NavigatorState>();

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Register before runApp; dialogs and App Open resume need this Navigator.
  AdManager().setNavigatorKey(navigatorKey);

  runApp(MaterialApp(
    navigatorKey: navigatorKey,
    navigatorObservers: [adRouteObserver, AdScreenRouteLogger()],
    home: const SplashScreen(),
  ));
}
```

Keep the host app's existing state-manager initialization, locale loading, theme, and app widget. Add only `setNavigatorKey`, both SDK observers, and `SplashScreen` wiring shown above. Do not add GetX, wakelock, or display-mode packages solely for this SDK integration.

If `setNavigatorKey` is missing, App Open on resume and `AdLoadingDialog`'s buffer will silently fail.

### 4.2 — Splash flow (controller is the default)

**Decide these three things first (a junior can decide all of them without asking anyone).**

| Question | Default if you have no instruction | Effect |
|---|---|---|
| Show an App Open ad on the splash screen? | **No** (`showAppOpenOnReady: false`) | `true`: after init succeeds the controller loads an App Open ad, shows the short loading buffer, then shows the ad (`bypassSafety: true`, the only allowed call site) and calls `onReady` when the ad is dismissed, skipped or failed. `false`: `onReady` is called as soon as init finishes and no splash ad is attempted. Choose `true` only if the partner wants a splash ad; resume App Open ads (returning from background) are separate and stay governed by `appOpenTrigger`. |
| How long may the splash wait? | **8 seconds** | `hardCapDuration` is the longest the splash waits for init plus the ad **load**; when it expires `onReady` fires so the app is never stuck. Once an ad is actually showing, its own dismissal ends the wait. Set the controller `hardCapDuration` and `AdConfig.splashMaxDuration` to the same value. |
| Does the iOS build need the ATT prompt or a custom consent step before ads? | **Android-only app: No. App that ships on iOS: ask the partner, because "No" has a cost** | Yes means use the manual splash below instead of the controller. The controller never calls `requestAtt()`. On iOS with the controller, the SDK therefore logs `requestUmpConsent() called before requestAtt() on iOS` and, in release, a louder warning that IDFA availability is unsettled for the first ad requests (lost attribution/revenue, not a legal block). That log is expected when the partner declines ATT; record the decision in Step 12 so nobody treats it as a bug. |

Choose exactly one startup path:

| Requirement | Startup path |
|---|---|
| Android + automatic UMP, including AdMob | Controller below |
| iOS without an app-managed ATT prompt or custom pre-init consent step | Controller below, after privacy-owner approval |
| iOS with an app-managed ATT prompt before ads, or any custom pre-init consent flow | Manual fallback below; do not call controller `start()` too |
| Remote safety provider (Step 4.16) | Manual fallback below |

The controller owns init-event ordering, the splash loading budget, splash-active bookkeeping, re-entry protection, and optional buffered splash App Open ad. Its hard cap stops waiting before presentation; once an ad is handed to the provider, the ad dismissal/watchdog owns completion. It does not forcibly close a native ad after eight seconds.

**Create `lib/ad_config.dart` first.** This Android + AdMob configuration uses Google's test ad units only in debug; supply approved release units with `--dart-define` or the host's build configuration. Empty optional format IDs mean that format is not configured. Replace the required units before release; never use these debug units in release. The AdMob App ID belongs in the manifest (Step 4.0), not this object. The separate `ios*` fields below prevent Android IDs becoming iOS fallbacks. Supply release IDs for each platform actually shipped; leave optional unsupported placements out of the UI.

<!-- snippet: ad_config.dart -->
```dart
import 'package:flutter/foundation.dart';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

const myAdConfig = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: kDebugMode
        ? 'ca-app-pub-3940256099942544/6300978111'
        : String.fromEnvironment('ADMOB_ANDROID_BANNER_ID'),
    interstitialId: kDebugMode
        ? 'ca-app-pub-3940256099942544/1033173712'
        : String.fromEnvironment('ADMOB_ANDROID_INTERSTITIAL_ID'),
    appOpenId: kDebugMode
        ? 'ca-app-pub-3940256099942544/9257395921'
        : String.fromEnvironment('ADMOB_ANDROID_APP_OPEN_ID'),
    rewardedId: kDebugMode
        ? 'ca-app-pub-3940256099942544/5224354917'
        : String.fromEnvironment('ADMOB_ANDROID_REWARDED_ID'),
    rewardedInterstitialId: kDebugMode
        ? 'ca-app-pub-3940256099942544/5354046379'
        : String.fromEnvironment('ADMOB_ANDROID_REWARDED_INTERSTITIAL_ID'),
    mrecId: kDebugMode
        ? 'ca-app-pub-3940256099942544/6300978111'
        : String.fromEnvironment('ADMOB_ANDROID_MREC_ID'),
    nativeId: kDebugMode
        ? 'ca-app-pub-3940256099942544/2247696110'
        : String.fromEnvironment('ADMOB_ANDROID_NATIVE_ID'),
    iosBannerId: kDebugMode
        ? 'ca-app-pub-3940256099942544/2934735716'
        : String.fromEnvironment('ADMOB_IOS_BANNER_ID'),
    iosInterstitialId: kDebugMode
        ? 'ca-app-pub-3940256099942544/4411468910'
        : String.fromEnvironment('ADMOB_IOS_INTERSTITIAL_ID'),
    iosAppOpenId: kDebugMode
        ? 'ca-app-pub-3940256099942544/5575463023'
        : String.fromEnvironment('ADMOB_IOS_APP_OPEN_ID'),
    iosRewardedId: kDebugMode
        ? 'ca-app-pub-3940256099942544/1712485313'
        : String.fromEnvironment('ADMOB_IOS_REWARDED_ID'),
    iosRewardedInterstitialId: kDebugMode
        ? 'ca-app-pub-3940256099942544/6978759866'
        : String.fromEnvironment('ADMOB_IOS_REWARDED_INTERSTITIAL_ID'),
    iosMrecId: kDebugMode
        ? 'ca-app-pub-3940256099942544/2934735716'
        : String.fromEnvironment('ADMOB_IOS_MREC_ID'),
    iosNativeId: kDebugMode
        ? 'ca-app-pub-3940256099942544/3986624511'
        : String.fromEnvironment('ADMOB_IOS_NATIVE_ID'),
  ),
  autoRequestUmpConsent: true,
  firstInstallVipGrace: FirstInstallVipGrace.disabled,
  keepScreenOnDuringSession: false,
  splashMaxDuration: Duration(seconds: 8),
  logLevel: kDebugMode ? AdLogLevel.verbose : AdLogLevel.warning,
);
```

These IDs identify different **ad formats**, not different partner accounts. Keep only approved placements in the UI; configuring a unit does not approve a new trigger. Configure UMP in the AdMob console before the first test (Step 8). For release testing, register the QA device as a test device; do not click live ads or switch off the release test-ID guard.

**Direct AppLovin alternative:** replace only the `myAdConfig` definition in `lib/ad_config.dart` with the following block; do not keep two configs with the same name. No public universal AppLovin test ad-unit IDs exist: QA needs the partner's configured test units/device settings. Empty credentials are unresolved prerequisites, not working defaults. AdMob `APPLICATION_ID` metadata/UMP setup still applies because the SDK bundles Google Mobile Ads/UMP. Rewarded Interstitial is not supported on direct AppLovin.

<!-- snippet: applovin_ad_config.dart -->
```dart
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

const myAdConfig = AdConfig(
  provider: AdProvider.appLovin,
  appLovin: AppLovinConfig(
    sdkKey: String.fromEnvironment('APPLOVIN_SDK_KEY'),
    bannerId: String.fromEnvironment('APPLOVIN_ANDROID_BANNER_ID'),
    interstitialId: String.fromEnvironment('APPLOVIN_ANDROID_INTERSTITIAL_ID'),
    appOpenId: String.fromEnvironment('APPLOVIN_ANDROID_APP_OPEN_ID'),
    rewardedId: String.fromEnvironment('APPLOVIN_ANDROID_REWARDED_ID'),
    mrecId: String.fromEnvironment('APPLOVIN_ANDROID_MREC_ID'),
    nativeId: String.fromEnvironment('APPLOVIN_ANDROID_NATIVE_ID'),
    iosBannerId: String.fromEnvironment('APPLOVIN_IOS_BANNER_ID'),
    iosInterstitialId: String.fromEnvironment('APPLOVIN_IOS_INTERSTITIAL_ID'),
    iosAppOpenId: String.fromEnvironment('APPLOVIN_IOS_APP_OPEN_ID'),
    iosRewardedId: String.fromEnvironment('APPLOVIN_IOS_REWARDED_ID'),
    iosMrecId: String.fromEnvironment('APPLOVIN_IOS_MREC_ID'),
    iosNativeId: String.fromEnvironment('APPLOVIN_IOS_NATIVE_ID'),
  ),
  autoRequestUmpConsent: true,
  firstInstallVipGrace: FirstInstallVipGrace.disabled,
  keepScreenOnDuringSession: false,
);
```

**Where the AppLovin values come from (direct AppLovin only).** Everything is created in the AppLovin MAX dashboard (`dash.applovin.com`), with the partner's own account:

1. **SDK key.** Account → Keys → "SDK Key" (86 characters). One key covers both Android and iOS apps in the same AppLovin account. Never commit it.
2. **Ad Unit IDs.** MAX → Manage → Ad Units → create one unit per format **per platform** (banner, interstitial, rewarded, app open, and optionally MREC and native) and copy each Ad Unit ID. A banner unit ID does not work for another format, and an AppLovin ID is not an AdMob ID: AdMob IDs contain `ca-app-pub-` and a `/`.
3. **Pass them at build time**, not in source. Example for Android debug:

   ```bash
   flutter run \
     --dart-define=APPLOVIN_SDK_KEY=<86-char-key> \
     --dart-define=APPLOVIN_ANDROID_BANNER_ID=<id> \
     --dart-define=APPLOVIN_ANDROID_INTERSTITIAL_ID=<id> \
     --dart-define=APPLOVIN_ANDROID_APP_OPEN_ID=<id> \
     --dart-define=APPLOVIN_ANDROID_REWARDED_ID=<id>
   ```

   Add the `APPLOVIN_ANDROID_MREC_ID` / `APPLOVIN_ANDROID_NATIVE_ID` pair only for formats you use, and the matching `APPLOVIN_IOS_*` defines for iOS (the config above lists every name). A define you forget becomes an empty string, which means that format is not configured.
4. **Test ads.** AppLovin has no public universal test unit IDs. In a **debug** build the SDK registers the current device as an AppLovin test device automatically (it reads the device advertising ID for you), so the units you created serve test creatives on your own phone. Never tap production ads on any other device. A release build serves real ads.
5. **AdMob App ID is still required.** The SDK bundles Google Mobile Ads and UMP for consent, so the AdMob `APPLICATION_ID` manifest entry and `GADApplicationIdentifier` plist entry (Step 4.0) must exist even when AppLovin serves the ads. Use the partner's real AdMob App ID, or Google's public test App ID for a test-only app.

**What differs on AppLovin (read before choosing it).**

| Topic | Behavior with `AdProvider.appLovin` |
|---|---|
| Rewarded Interstitial | Not supported. The call does nothing; use rewarded or interstitial. |
| Custom native layout | Flutter-side `customNativeAdBuilder` (Step 4.17). AdMob's `factoryId` is ignored. |
| Consent writes | AppLovin consent flags are fire-and-forget and cannot be confirmed (Step 4.11). Do not treat them as a hard guarantee. |
| Consent form | Google UMP still runs through the bundled AdMob plugin; AppLovin's own consent flow is off by default. |
| Child-directed users | AppLovin never initializes (Step 8.3). |
| Ad freshness | No load timestamp exists, so the SDK cannot reject an old cached ad (Step 4.11). |
| Release checks | Empty `sdkKey` is warned about in release; AdMob test-ID checks (Step 11.0a) do not apply, so check your AppLovin IDs by hand. |

**Create `lib/splash_screen.dart`.** `HomeScreen` is the screen implemented in Step 4.4; imports assume both files live under `lib/`.

<!-- snippet: splash_screen.dart -->
```dart
import 'package:flutter/material.dart';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'ad_config.dart';
import 'home_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  final _splash = AdReadinessSplashController(
    config: myAdConfig,
    hardCapDuration: const Duration(seconds: 8),
    showAppOpenOnReady: false,
  );

  @override
  void initState() {
    super.initState();
    _splash.start(context, onReady: _goHome);
  }

  void _goHome() => Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => const HomeScreen()),
      );

  @override
  void dispose() {
    _splash.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
}
```

The sample uses `showAppOpenOnReady: false`. To show a splash App Open ad change that one line to `true`; nothing else in the splash needs to change (the controller does the load, buffer, show and navigation). With `true` expect `onReady` to fire **after** the ad closes, and verify with the Google App Open **test** unit before using real units. If you change `hardCapDuration`, change `AdConfig.splashMaxDuration` in `ad_config.dart` to the same value.

#### Manual fallback — only for custom ATT/consent timing

Use this longer flow only when requirements cannot be expressed by `AdReadinessSplashController`. The controller already covers the normal flow; do not combine both implementations.

<!-- snippet: manual_splash_screen.dart -->
```dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'ad_config.dart';
import 'home_screen.dart';

class ManualSplashScreen extends StatefulWidget {
  const ManualSplashScreen({super.key});

  @override
  State<ManualSplashScreen> createState() => _ManualSplashScreenState();
}

// Set to true only after the partner's iOS tracking/privacy review approves ATT
// (it also needs NSUserTrackingUsageDescription in Info.plist, Step 4.0c).
const bool kRequestAtt = false;

class _ManualSplashScreenState extends State<ManualSplashScreen> {
  Timer? _hardCap;
  void Function(BoolEvent)? _onInitEvent;
  bool _navigated = false;

  @override
  void initState() {
    super.initState();

    AdManager().markSplashActive();
    AdManager().incrementSplashCount();

    // 4.2.1 — Hot-restart guard (mandatory)
    if (AdManager().countInitSplashScreen > 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _goHome());
      return;
    }

    // 4.2.2 — The hard-cap timer is started AFTER ATT (below), never before:
    // the iOS tracking dialog waits for the user, and a timer already running
    // would send the app to Home underneath that dialog.

    // 4.2.3 — Subscribe BEFORE initialize
    void onInitEvent(BoolEvent event) {
      if (!mounted || _navigated) return;
      if (event.value) {
        _showSplashAppOpen();
      } else {
        _goHome();
      }
    }
    _onInitEvent = onInitEvent;
    SimpleEventBus().listen(onInitEvent);

    // 4.2.4 — If ATT is in scope: request it after first frame, then initialize.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Call ATT only when the partner approved it; requestAtt() is no-op on Android.
      if (!mounted || _navigated) return;
      if (kRequestAtt) {
        final att = await AdManager().requestAtt();
        debugPrint('ATT status=${att.status.name}');
      }
      if (!mounted || _navigated) return;
      // Start the hard cap now (default 8s; keep equal to AdConfig.splashMaxDuration).
      _hardCap = Timer(const Duration(seconds: 8), _goHome);
      final config = myAdConfig;

      await AdManager().initialize(
        config: config,
        onComplete: (success, _) {
          if (!success && mounted) _goHome();
        },
      );
    });
  }

  void _showSplashAppOpen() {
    AdManager().loadAppOpenAd(onAdLoaded: (loaded) {
      if (_navigated || !mounted) return;
      if (!loaded) return _goHome();
      AdLoadingDialog.showAdBuffer(context, onComplete: () {
        if (_navigated || !mounted) return;
        // Cancel the hard-cap BEFORE showAppOpenAd
        _hardCap?.cancel();
        _hardCap = null;
        AdManager().showAppOpenAd(
          bypassSafety: true,                   // the ONLY place this is allowed
          onAdDismiss: (_) => _goHome(),
        );
      });
    });
  }

  void _goHome() {
    if (_navigated) return;
    _navigated = true;
    _hardCap?.cancel();
    _hardCap = null;
    AdManager().markSplashInactive();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil<void>(
      MaterialPageRoute<void>(builder: (_) => const HomeScreen()),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );

  @override
  void dispose() {
    _navigated = true;
    _hardCap?.cancel();
    AdManager().markSplashInactive();
    final onInitEvent = _onInitEvent;
    if (onInitEvent != null) SimpleEventBus().remove(onInitEvent);
    super.dispose();
  }
}
```

**Use the manual splash.** Replace `home: const SplashScreen()` in `main.dart` (Step 4.1) with `home: const ManualSplashScreen()`, import `manual_splash_screen.dart`, and delete the controller-based `splash_screen.dart`. Never have both screens call `initialize()`. The manual screen does not read `showAppOpenOnReady`; it always attempts the splash App Open ad after a successful init (delete the `_showSplashAppOpen()` call and call `_goHome()` there instead if you do not want one).

**`bootstrap(...)` option:** `bootstrap(AdBootstrapOptions(config: ..., requestAtt: ...))` runs optional ATT, then an explicit `requestUmpConsent()`, then `initialize()`, and returns `AdBootstrapResult`. Because it requests UMP itself, use it only with a config that sets `autoRequestUmpConsent: false`; otherwise `initialize()` will request UMP again. It does not own the hard-cap timer, event subscription, splash bookkeeping, or splash App Open display. Use it only inside the manual fallback and do not combine it with the manual `requestAtt()/initialize()` calls or with `AdReadinessSplashController`. Read `result.initSuccess` and handle `result.ump`. Its `initTimeout` (default 20s) stops waiting for init but does not cancel it.

### 4.3 — Splash UI and partner-approved disclosure

Keep the host splash screen and add disclosure copy only if the partner's policy/legal owner requires it or approves it. Do not copy the sample sentence below as a universal legal statement. Place approved localized text where it is visible before any ad surface it describes, using the host app's existing localization system.

Example layout (replace `localizedDisclosure` with the host localization lookup; omit the `Text` entirely if no splash disclosure is approved/required):

```dart
Widget buildSplashContent() {
  // Replace with partner-approved localized copy, or keep null if none applies.
  const String? localizedDisclosure = null;
  return Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (localizedDisclosure case final text?)
        Text(text, textAlign: TextAlign.center),
      const LinearProgressIndicator(),
    ],
  );
}
```

Record the approved copy, languages, placement, and approving owner in `<PROJECT_PATH>/doc/AD.MD`; never infer legal wording from this example.

### 4.4 — Banner: extend `AdScreen` + edge-to-edge

Create `lib/home_screen.dart`. This complete minimal screen is the destination imported by Step 4.2. Replace its content area with the partner's existing UI; preserve `super.initState()`/`super.dispose()` if overriding them later. `SafeArea(top: false)` keeps the banner above system navigation in an edge-to-edge app; do not add a second bottom inset when the host already owns it.

<!-- snippet: home_screen.dart -->
```dart
import 'package:flutter/material.dart';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

import 'privacy_screen.dart';

class HomeScreen extends AdScreen {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends AdScreenState<HomeScreen> {
  int _coins = 0;

  /// Interstitial: show an ad at a natural break, then ALWAYS continue.
  void _openNextScreen() {
    showInterstitialAd(onDone: (shown) {
      // shown == true : an ad was displayed and closed.
      // shown == false: no ad (blocked by a safety limit, no network, still
      //                 loading). The user must still reach the next screen.
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const PrivacyScreen()),
      );
    });
  }

  /// Rewarded: only after the user taps; grant ONLY when earned is true.
  void _watchForCoins() {
    showRewardedAd(onEarnedReward: (earned) {
      if (!mounted) return;
      if (!earned) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No reward. The ad was not completed or is not ready.')),
        );
        return;
      }
      setState(() => _coins += 10);
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text('Home  -  coins: $_coins')),
        body: Column(
          children: [
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ElevatedButton(
                      onPressed: _openNextScreen,
                      child: const Text('Open privacy screen (interstitial)'),
                    ),
                    const SizedBox(height: 12),
                    ElevatedButton(
                      onPressed: _watchForCoins,
                      child: const Text('Watch ad for 10 coins (rewarded)'),
                    ),
                  ],
                ),
              ),
            ),
            SafeArea(top: false, child: buildBanner()),
          ],
        ),
      );
}
```

This single file is the whole Android + AdMob UI: a banner at the bottom, an interstitial before opening the next screen, and a rewarded button. The rewarded callback receives `earned`; the reward is a local counter here, so replace `_coins += 10` with the partner's real reward logic (a VIP-time grant is only one option and is shown separately in Step 4.7). `PrivacyScreen` comes from Step 8.1; create `lib/privacy_screen.dart` before running `flutter analyze` (or temporarily replace that navigation with `Navigator.of(context).pop()`). The interstitial is paced by the SDK safety layer: repeated taps within the minimum interval (60 seconds in release, shorter in debug) return `shown == false`, which is the correct "do nothing extra" outcome, not a bug. A fresh app has no earlier screen to navigate to, so the privacy screen doubles as that destination.

Acceptance: banner loads with a test unit, does not cover navigation controls, and pauses/disposes when the route becomes inactive. Test offline/no-fill without a stuck spinner or an obscured host button. Direct `BannerAdWidget` is valid when the host cannot extend `AdScreen`; explicitly wire visibility/route ownership, especially for tabs (Step 4.14). Never assign one adapter key/controller to two simultaneous banners.

### 4.5 — App Open when returning to the foreground

The SDK already hooks `WidgetsBindingObserver`. **Do NOT** subscribe to lifecycle a second time — that causes a double-show.

As of current SDK releases: `showAppOpenAdOnResume` will not show App Open on top of a modal —
it checks `isDialogOnTop` (tracked by `AdScreenRouteLogger` counting open `PopupRoute`s) plus
`AdLoadingDialog.isShowing` before showing; if a dialog or loading buffer is currently on top, it skips.

### 4.6 — Interstitial pattern

`showInterstitialAd` is a method of `AdScreenState`, so call it from the State class of any screen that extends `AdScreen` (the complete example is `home_screen.dart` in Step 4.4). Use it only at a natural break: after the user finished a task and is about to move on. Never on app launch, never right after the user tapped a button that does something else, and never in a loop.

```dart
showInterstitialAd(onDone: (shown) {
  // shown == true : ad displayed and closed.
  // shown == false: blocked by safety / VIP / no network / still loading.
  // ALWAYS perform the existing post-action regardless.
  if (!mounted) return;
  Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => const NextScreen()),
  );
});
```

Replace `NextScreen` with the screen your existing action already navigates to; keep the original trigger and destination unchanged. Do not call `showInterstitialAd` from `build()` and do not call it again in the callback.

### 4.7 — Rewarded pattern

Only load + show when the user taps a button (e.g. VIP screen "Watch ad → 3 days VIP", clear history, unlock a feature):

```dart
showRewardedAd(onEarnedReward: (earned) {
  if (!earned) return;
  // grant the reward (e.g. grant 3 days of VIP)
  final vip = AdManager().vip;     // RULE #2 no `!`
  if (vip == null) return;
  // Stacking: use a FIXED key (not a timestamp) + `stack: true` →
  // every ad watch adds +3 days on top of the current expiry, collapsed into one entry (no list clutter).
  vip.addVip(key: 'REWARDED_VIP', duration: const Duration(days: 3), stack: true);
});
```

**Letting an active VIP user stack more time (optional, only if the user asks for it).** By default, while VIP is
active the SDK suppresses all ads → the "Watch ad" button is usually hidden. If you want an active VIP to
extend their window **by watching a real ad** (stacking on top of remaining time), keep the button visible
and pass `bypassVipGuard: true`:

```dart
showRewardedAd(
  bypassVipGuard: true,            // an active VIP can still watch a REAL rewarded ad (SDK loads on demand)
  onEarnedReward: (earned) {
    if (!earned) return;           // still only grants on a completed watch — never auto-grant
    AdManager().vip?.addVip(
      key: 'REWARDED_VIP', duration: const Duration(days: 3), stack: true);
  },
);
```

> ⚠️ Do NOT hand out free VIP time to an already-VIP user (e.g. forcing `vipAutoGrant: true` and then stacking) —
> that's +N days of infinite unwatched ad time, which costs revenue and carries policy risk. `bypassVipGuard`
> still requires watching a real ad, so it's legitimate; anti-spam relies on the SDK's fullscreen safety cap.

### 4.8 — MREC pattern

Fixed 300×250 rectangle, same route-aware pause/resume lifecycle as banner. Only add this if the
project actually wants a rectangle placement (e.g. inline in a feed/list) — do not add speculatively.

```dart
class HistoryScreen extends AdScreen {  // NOT StatefulWidget
  const HistoryScreen({super.key});
  @override State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends AdScreenState<HistoryScreen> {
  @override
  Widget build(BuildContext context) => Scaffold(
    body: ListView(
      children: [
        _content(),
        Center(child: buildMrec()),   // fixed 300x250, place wherever the layout wants it
      ],
    ),
  );
}
```

Same memory-leak/dispose rule as banner (Step 6.2) — `super.dispose()` at the end of `dispose()` is enough,
`buildMrec()` manages its own controller lifecycle internally.

### 4.9 — Native ad pattern

Blends into the host app's own UI instead of a fixed ad frame. AdMob renders a template ad; AppLovin renders
a custom native layout — both go through the same call:

```dart
class FeedScreen extends AdScreen {
  const FeedScreen({super.key});
  @override State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends AdScreenState<FeedScreen> {
  @override
  Widget build(BuildContext context) => Scaffold(
    body: ListView(
      children: [
        _content(),
        buildNative(),   // loads once per mount, does not react to navigation
      ],
    ),
  );
}
```

`buildNative()` loads once per mount and does not re-fetch on navigation — do not wrap it in anything that rebuilds it on every route change (that would burn ad requests without gaining impressions).

**Default vs. custom layout:** `buildNative()`/`NativeAdWidget()` works without any native code and is the right starting point. Use a custom layout only when design requires it: **Step 4.17 contains the complete Android (Kotlin + XML), iOS (Swift + AppDelegate) and AppLovin recipes**, with the factory ID, registration and cleanup steps. Create a **Native** ad unit in the provider console first (AdMob "Native advanced", or an AppLovin MAX native unit); a banner unit ID does not work.

### 4.10 — Rewarded Interstitial (optional; AdMob only)

Use only when `AdProvider.admob` is selected, this format is configured with an AdMob rewarded-interstitial unit ID, and product wants the extra disclosure/intro step. AppLovin MAX does not support this surface through this SDK; if provider is AppLovin, skip this section and use an approved AppLovin-supported format instead.

Same earned-only reward contract as plain rewarded (Step 4.7), but the SDK shows a built-in disclosure/intro screen by default:

```dart
showRewardedInterstitialAd(onDone: (shown, earned) {
  // shown=true  → ad (or its intro) was displayed
  // earned=true → user watched to completion — only then grant the reward
  if (!earned) return;
  final vip = AdManager().vip;     // RULE #2 no `!`
  if (vip == null) return;
  vip.addVip(key: 'REWARDED_VIP', duration: const Duration(days: 3), stack: true);
});
```

Declining the built-in intro screen reports `(shown: false, earned: false)` at no ad-budget cost. Pass
`showDisclosure: false` only if the host app renders its own localized/branded intro screen first — then the
host takes on the obligation to disclose the reward before the ad plays.

### 4.11 — Known SDK limitations to design around

Not bugs to fix — real, current limits of the SDK you are integrating against. Know these before you design
around them, instead of rediscovering each one the hard way:

- **`bypassSafety` (on `showAppOpenAd`) is not technically restricted to the splash screen** — it's a public
  parameter, callable from anywhere in the host app. It exists so the splash's App Open call can skip the
  daily/hourly/session caps and 60s throttle right after cold start (Step 4.2). Only ever pass
  `bypassSafety: true` from that one splash call site. Passing it anywhere else (a settings screen, a
  promotional button, ...) shows App Open ads with no frequency limit — a real AdMob/AppLovin
  placement-policy violation, not just a code smell.
- **`AdScreenRouteLogger`'s dialog-stacking guard only sees Flutter `Route`s.** A popup built by inserting an
  `OverlayEntry` directly — common in third-party loading/toast/coach-mark packages, and `SnackBar` (goes
  through `ScaffoldMessenger`, not a route) — is invisible to it. If the host app shows one of these at the
  moment an App Open ad could resume, the ad can appear on top of it. There is no SDK-side fix; avoid
  non-route popups during a window where App Open could resume, or explicitly mark them with
  `markCustomOverlayOnScreen(true/false)` as described in Step 4.14. Clear the flag only when the last overlay closes.
- **No automatic runtime failover between AdMob and AppLovin.** `AdConfig.provider` picks one backend per
  session (including a stable per-install A/B split via the SDK's own cohort picker) — this is fully
  runtime-configurable, no rebuild needed. But if the active provider degrades mid-session (outage, no-fill),
  the SDK does not detect that and switch to the other one; it keeps retrying the same provider. Switching
  requires the host calling `AdManager().destroy()` then `initialize()` with a different `AdConfig.provider`
  itself.
- **AppLovin consent writes cannot be confirmed as successful .** `applyConsentToProviders()`
  calls `AppLovinMAX.setHasUserConsent`/`setDoNotSell` — both fire-and-forget `void` methods in the
  `applovin_max` package with no `Future` to await, unlike AdMob's `updateRequestConfiguration` which is
  properly awaited and only recorded as applied on success. If that platform-channel write silently fails
  (cold/backgrounded channel, transient native exception), AppLovin can keep serving personalised ads to a
  user who just withdrew consent, with no way for this SDK to detect it — a dependency-level gap, not
  something the Dart side alone can close. If the host app has real EEA/UK/California traffic on
  `AdProvider.appLovin`, do not treat the AppLovin branch of consent as a hard guarantee; verify
  regional consent withdrawal behavior on the target platform with QA inventory.

### 4.12 — Adaptive and in-feed placements (optional)

Use only when product approved these placements. Both can request real ads after consent/VIP/connectivity gates permit. Do not add every surface to the same screen just to exercise an API.

**Adaptive width:** configure both banner and MREC unit IDs first, then insert `const AdaptiveAdSurface()` into a bounded-width area with room for the selected format. Below 600 logical pixels it chooses banner; at/above 600 it chooses MREC, with debounced resizing. Override `mrecBreakpoint` only with an approved layout. It has no `active` parameter: do not leave it mounted in a hidden `IndexedStack` tab. Mount it only in the selected tab, or use direct Banner/MREC widgets with explicit `active` wiring.

**Feed:** configure the native unit before using this default native-ad list. Content indexes stay unchanged in `itemBuilder`; ad indexes are separate.

```dart
Widget buildArticleFeed(List<String> articles, {required bool selected}) {
  return InFeedAdListView.builder(
    itemCount: articles.length,
    firstAdIndex: 3,
    adInterval: 8,
    itemBuilder: (context, index) => ListTile(title: Text(articles[index])),
    adBuilder: (context, adIndex) => NativeAdWidget(
      key: ValueKey('article-ad-$adIndex'),
      active: selected,
    ),
  );
}
```

`firstAdIndex: 3` means three content rows before the first ad, not the third combined list row. Subsequent ads are separated by `adInterval` content items. Default `firstAdIndex` is `adInterval`; zero permits an ad before the first content item. `adInterval` must be positive and `firstAdIndex` non-negative. Leave `adBuilder` unset to use SDK-managed native creation/scroll-load deferral; a custom builder, as above for explicit tab visibility, owns its own activity/load policy. Verify empty/short lists, changing content length, scrolling off/back, and tab switches; a hidden feed must not keep loading native ads.

### 4.13 — Rewarded preload and host-controlled power (optional)

On a reward-heavy screen that already extends `AdScreenState`, add this override inside the State class:

```dart
@override
bool get preloadRewardedOnMount => true;
```

Default is false. It requests preload on mount through SDK gates, not a guarantee of fill. For an explicit trigger later, call the State helper `loadRewardedAd()`. Verify unavailable/offline and double-tap behavior; never grant a reward merely because a load succeeded.

The SDK defaults `keepScreenOnDuringSession` to true. The Android configuration above explicitly sets false to preserve normal host screen-sleep behavior. Product may opt in with `keepScreenOnDuringSession: true`, or change the SDK wake lock at runtime:

```dart
Future<void> updateSdkWakeLock(bool keepAwake) =>
    AdManager().setKeepScreenOn(keepAwake);

void reportHostLowPowerState(bool enabled) {
  AdManager().setLowPowerMode(enabled);
}
```

`setKeepScreenOn` controls a wake lock, not display brightness or refresh rate. `setLowPowerMode` affects AppLovin Banner/MREC auto-refresh only; it does not change AdMob or fullscreen formats. The SDK does not detect the OS power mode for the host. Do not add a battery plugin solely for an AdMob integration with no effect to observe. Verify screen sleep and restore behavior on device; if the host already controls wake locks, use one explicit owner.

### 4.14 — Sensitive screens, hidden tabs and inline controls

Wrap payment, camera/QR, OTP and password routes in `AdSensitiveScreen(child: ...)` when those are approved sensitive flows. Example: `AdSensitiveScreen(child: PaymentScreen())`, where `PaymentScreen` is the host's actual route. While mounted, the wrapper suppresses resume App Open ads; it does not suppress interstitial/rewarded calls or inline ads. For a custom non-Flutter-route overlay that the dialog observer cannot see, call `markCustomOverlayOnScreen(true)` when it appears and `markCustomOverlayOnScreen(false)` only after the last such overlay closes; this is a boolean, not a counter. Host must not trigger those formats on the sensitive screen itself. Verify background/resume before, during and after the route.

For Banner/MREC in `IndexedStack`, pass `active: selectedIndex == tabIndex`; Native requires its explicit `active` state too. Do not pass `active: false` together with an `InlineAdController`. To control one inline widget imperatively, create one controller in its owning State, attach it via `controller:`, call `pause()`/`resume()`/`refresh()` only for that widget, then `dispose()` the controller in State teardown. Never share a controller across simultaneous placements. These commands retain consent/VIP/cooldown gates; refresh is not a promise to bypass throttling. For AppLovin native refresh on the audited release, remount the widget with a new key until the SDK owner confirms the refresh issue is fixed; do not promise a new creative from `refresh()` alone.

### 4.15 — Local house-ad fallback (optional)

If the partner wants local promotional content when a banner has no fill or is offline, bundle the artwork in the host app (for example `assets/house_ad.png`) and declare it under `flutter: assets:` in the host's `pubspec.yaml`. Create the widget only for an approved placement. It does not call an ad network and is not counted as an ad impression/revenue event. Do not simulate clicks or disguise it as a paid network creative.

Inside a host build method:

```dart
BannerAdWidget(
  houseAd: HouseAdItem(
    assetPath: 'assets/house_ad.png',
    title: 'Explore more features',
    subtitle: 'Partner-approved local promotion',
    onTap: () => Navigator.of(context).pushNamed('/features'),
  ),
  houseAdDelay: const Duration(seconds: 5),
)
```

The asset and `/features` route are partner-owned prerequisites; localize text and provide accessible artwork. Configure route visibility/`active` as for an ordinary banner. Verify normal fill, offline/no-fill after the delay, missing asset handling during development, tap navigation and disposal. Never turn a house-ad tap into an artificial AdMob/AppLovin event.

### 4.16 — Advanced controls and monetization modules (choose individually)

These recipes are alternatives/options, not permission to enable every module. Android + AdMob does not require AppLovin, experimentation, remote configuration or monetization tuning. Product, privacy and monetization owners approve the selected modules and thresholds first. Use the SDK's normal load/show APIs; no observer may bypass consent, VIP, connectivity or safety gates.

Every Dart fence carrying `<!-- snippet: ... -->` below is a complete library. Create that file under the host's `lib/` (or adapt its name), import it from the single startup owner, and use the named functions. Inputs such as account-specific IDs, approved transport callbacks and analytics callbacks are explicit parameters, not undefined globals. All examples import only the public SDK barrel. They do not add packages or a backend.

#### PlacementRegistry, safety defaults and install-age ramp

**When:** product approved named placements and stricter limits. **Files:** `lib/ad_policy.dart`, plus the existing `AdConfig` construction and existing show trigger. Both providers use the same behavior map; ad-unit IDs remain in `AdMobConfig`/`AppLovinConfig`.

<!-- snippet: ad_policy.dart -->
```dart
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

const levelCompletePlacement = AdPlacement.custom('level_complete');

const partnerPlacements = PlacementRegistry({
  'level_complete': PlacementSpec(
    format: AdSlotType.interstitial,
    frequencyCapOverride: 3,
    minIntervalOverrideMs: 120000,
  ),
});

final partnerSafetyRamp = <Duration, AdSafetyParams>{
  Duration.zero: AdSafetyParams.auto.copyWith(maxFullscreenAdsPerDay: 2),
  const Duration(days: 7):
      AdSafetyParams.auto.copyWith(maxFullscreenAdsPerDay: 3),
};

AdConfig buildPolicyConfig(AdMobConfig admob) => AdConfig(
      provider: AdProvider.admob,
      admob: admob,
      placements: partnerPlacements,
      safety: AdSafetyParams.auto,
      safetyRampSchedule: partnerSafetyRamp,
      firstInstallVipGrace: FirstInstallVipGrace.disabled,
      keepScreenOnDuringSession: false,
    );
```

Use `buildPolicyConfig(yourAdMobConfig)` as the one config passed to startup. At the already-approved transition, pass `placement: levelCompletePlacement` to `showInterstitialAd(onDone: ..., placement: ...)` on `AdScreenState`, or to `AdManager().showInterstitial(...)` if the host owns the fullscreen flow. The string in `AdPlacement.id` must match the registry key. The `PlacementSpec.format` must match the actual show format; a mismatch silently falls back to the usual safety values. Registry entries do not select ad units.

`frequencyCapOverride` replaces that placement's daily cap for that format. `minIntervalOverrideMs` replaces that show call's interval since the last fullscreen ad of any format. Smaller intervals loosen protection; **zero removes this placement's interval check**. Do not use zero/negative values or enlarge caps just to make tests pass. The example is a product-controlled restriction, not a universally suitable policy.

The ramp selects the largest configured duration not greater than the age since the SDK's recorded first install, not session length or a user cohort. It is evaluated at initialization and when remote safety is refreshed; it is not a continuously ticking timer. A stage is a complete `AdSafetyParams` value, not a partial delta. With no applicable stage, `config.safety` remains the baseline. No extra ad requests are issued by the map or schedule. No disposal is required for these immutable config values.

**Verify:** same placement+format obeys its cap/interval, another placement stays on defaults, wrong-format reuse does not apply the override, new/older installs select the intended stages, and offline/VIP/consent still block as before. Use deterministic tests for install ages; do not change a user's clock/storage to test this. Safety limits reduce risk but do not certify network policy compliance.

#### Per-slot AdRetryPolicy and Backoff

**When:** the partner has measured provider errors and needs a deliberate retry strategy. **File:** `lib/ad_retry.dart`. Install only after successful SDK initialization; repeat after a genuine destroy/re-initialize because slots belong to that adapter instance.

<!-- snippet: ad_retry.dart -->
```dart
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

void installFullscreenRetryPolicy() {
  final adapter = AdManager().adapter;
  if (adapter == null || !AdManager().isInitialised) {
    throw StateError('Initialize the SDK before installing retry policy');
  }
  const policy = AdRetryPolicy(
    backoff: Backoff(baseMs: 15000, maxMs: 1800000),
    jitterFraction: 0.2,
    resetOnConnectivityRestored: false,
  );
  adapter.appOpenSlot.retryPolicy = policy;
  adapter.interstitialSlot.retryPolicy = policy;
  adapter.rewardedSlot.retryPolicy = policy;
  adapter.rewardedInterstitialSlot.retryPolicy = policy;
}

void restoreDefaultFullscreenRetryPolicy() {
  final adapter = AdManager().adapter;
  if (adapter == null) return;
  adapter.appOpenSlot.retryPolicy = null;
  adapter.interstitialSlot.retryPolicy = null;
  adapter.rewardedSlot.retryPolicy = null;
  adapter.rewardedInterstitialSlot.retryPolicy = null;
}
```

`Backoff` doubles the 15-second first-failure delay up to 30 minutes; jitter randomizes each failure's delay within the configured fraction. The SDK floors jitter so it cannot erase backoff. `null` policy preserves the slot's normal shared-backoff behavior. `isRetryable` can be supplied as a `bool Function(int?)` to reject permanent errors, but **numeric codes are provider-specific**; do not reuse AdMob code meanings for MAX. Returning false leaves that failed slot in cooldown until reset (normally a new SDK session), so an incorrect classifier can suppress ads indefinitely. The example retries all codes instead of guessing. `resetOnConnectivityRestored: true` permits early cooldown reset on a detected reconnect; this is not appropriate for every no-fill/invalid-request error. The flag does not itself start a load.

**Cleanup:** call `restoreDefaultFullscreenRetryPolicy()` if deliberately removing policy mid-session, or let SDK teardown dispose the slots. Never call slot transition/reset methods to bypass safety in application code. **Verify:** failures back off, repeated cooldown reads do not jitter unpredictably for the same failure, reconnect behavior matches the flag, success clears the failure cycle, and policy is reinstalled on the new adapter after re-init. Inline slots require their own per-instance key and ownership; do not configure them by inventing one shared key.

#### RemoteAdSafetyProvider — one initialization owner

**When:** an approved existing remote-config service supplies bounded safety overrides. **Files:** `lib/remote_ad_policy.dart` and the manual splash's single `initialize()` call. The SDK provides no HTTP/Firebase transport. Pass the host's existing authenticated fetch callback; do not add a new networking package merely for this sample.

<!-- snippet: remote_ad_policy.dart -->
```dart
import 'dart:convert';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

class PartnerRemoteSafetyProvider implements RemoteAdSafetyProvider {
  PartnerRemoteSafetyProvider(this.readApprovedJson);

  final Future<String?> Function() readApprovedJson;

  @override
  Future<Map<String, dynamic>?> fetchSafetyParamOverrides() async {
    final raw = await readApprovedJson();
    if (raw == null || raw.trim().isEmpty) return null;
    final value = jsonDecode(raw);
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Safety payload must be a JSON object');
    }
    return value;
  }
}

Future<void> initializeWithRemoteSafety({
  required AdConfig config,
  required PartnerRemoteSafetyProvider provider,
  required void Function(bool success, String gaid) onComplete,
}) =>
    AdManager().initialize(
      config: config,
      remoteSafetyProvider: provider,
      remoteSafetyAutoRefreshInterval: const Duration(minutes: 30),
      onComplete: onComplete,
    );

Future<void> refreshPartnerSafety() =>
    AdManager().refreshRemoteSafetyParams();
```

Replace the manual splash's `initialize(...)` with `initializeWithRemoteSafety(...)`; **do not call both**. The controller does not expose these remote-safety arguments, so use the manual splash for this branch. Keep ATT/UMP ordering, hard cap, init callback and buffered App Open logic from that branch. Module setup that needs an initialized SDK belongs in the successful init path, before the home screen uses it. `onComplete` must not log raw GAID; it is provided here only to match the SDK callback contract.

Example response from the partner's approved transport (JSON, not Dart):

```json
{"revision":12,"maxFullscreenAdsPerDay":3,"minTimeBetweenFullscreenAds":120000,"disabledFormats":["rewardedInterstitial"]}
```

Keys match `AdSafetyParams` names. Unknown/invalid individual values are skipped. SDK bounds counts/durations, protects release dry-run behavior, and merges overrides over local/ramp values. `disabledFormats` uses `AdSlotType.name` strings; an explicit empty list replaces a previous disabled set. A valid integer `revision` lower than the last applied revision rejects the whole payload; **equal revisions are allowed**. Omitting revision (or giving a non-integer) skips revision enforcement. This is configuration rollback protection, not a signature or authorization system. The host transport/authentication still matters.

At initialization, unavailable/null/throwing fetch preserves the local policy. Refresh fetch timeout/error/null leaves currently applied safety unchanged. A successful refresh re-evaluates the local install-age ramp then merges the payload; a missing key is not a promise to retain an earlier remote override. `remoteSafetyAutoRefreshInterval: null` means only the init fetch plus explicit refresh calls. SDK destroy owns its periodic timer; the provider itself must clean up any resources its host transport owns.

**Verify:** valid object applies, malformed JSON/array/null/error/offline retains safe expected behavior; negative/infinite/out-of-range fields do not crash init; lower revision is rejected, equal revision behavior is understood; concurrent refresh/destroy does not apply a previous session's response. Do not lower safety limits to zero to force a test ad.

#### Signed experimental feature flags

**When:** the SDK/operations owner supplies a signed payload and its separately trusted Ed25519 public key. **File:** `lib/ad_feature_flags.dart`. This is a kill switch for already-enabled experimental modules, not a remote-config service or a general ad enable switch. Private signing keys belong with the issuer, never the Flutter app or logs.

<!-- snippet: ad_feature_flags.dart -->
```dart
import 'dart:convert';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

Future<bool> applyPartnerFeatureFlags({
  required String responseJson,
  required String trustedPublicKeyBase64,
}) async {
  try {
    final decoded = jsonDecode(responseJson);
    if (decoded is! Map<String, dynamic>) return false;
    final payload = SignedFeatureFlags.fromJson(decoded);
    return await AdManager().applySignedFeatureFlags(
      payload,
      publicKeyBase64: trustedPublicKeyBase64,
    );
  } on FormatException {
    return false;
  } on TypeError {
    return false;
  }
}
```

The transport supplies JSON with `revision` (non-negative integer), `expiresAt` (UTC ISO-8601), `flags` (object with boolean values), and `signatureBase64` (Base64url Ed25519 signature). For example, the shape is:

```json
{"revision":12,"expiresAt":"2030-01-01T00:00:00.000Z","flags":{"arbitrator":false,"journeyPrefetcher":false},"signatureBase64":"<ISSUER_SIGNATURE>"}
```

This placeholder is not a valid payload and must not be used as a passing test. The signature covers UTF-8 bytes of `SignedFeatureFlags.canonicalPayload()`, whose object key order is `schemaVersion`, `revision`, `expiresAt`, `flags`; `schemaVersion` is fixed at 1. The issuer must preserve the `flags` map order and UTC formatting used by that method; a semantically equivalent JSON reordering is not necessarily byte-equivalent. To produce QA test data, authorized test code can create a temporary Ed25519 keypair and sign that canonical string; production issuer integration needs its own approved key custody. Do not ask a junior to improvise production signing.

Verification rejects expired timestamps, negative revisions, invalid signatures, malformed keys and a revision **lower** than the last accepted revision. Equal revision is accepted, so this is not a one-shot anti-replay protocol. Revision is persisted locally; it is not a server/global monotonic guarantee or tamper-proof against a device owner. The application must obtain the public key from its approved build/trust configuration, not from the same untrusted response as the signature. Clock accuracy affects expiry.

Recognized false flags call the corresponding disable methods: `arbitrator`, `waterfallTuner`, `journeyPrefetcher`, `selfHealingObserver`. `true` does **not** create/re-enable a module. Unknown keys do not configure other SDK behavior. Apply after approved modules are attached; do not immediately reattach a killed module in the same startup code. Invalid/stale/expired payload returns false and leaves modules unchanged; display an operations status, not a crash. Transport errors are the host's responsibility; retain current local module setup rather than silently applying unsigned data.

**Verify:** a disposable-key valid payload disables only named modules, tampering rejects, expired/lower revisions reject, equal revision is accepted as documented, and cold-start revision persistence is tested. Use `verify(...)` for preflight if desired; actual application must use `applySignedFeatureFlags(...)` to use the SDK's last accepted revision. Never put the signing private key in a client-side recipe.

#### CompatibilityMatrix — reviewed matrix, not Android minSdk

**When:** validating a planned test/toolchain combination. **File:** `lib/ad_compatibility.dart`. Read-only helper; no init/attach/dispose and no network requests.

<!-- snippet: ad_compatibility.dart -->
```dart
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

bool reviewedAndroidAdMobTarget({
  required String flutterVersion,
  required int androidApi,
}) =>
    CompatibilityMatrix.isSupported(CompatibilityTarget(
      flutter: flutterVersion,
      platform: CompatibilityPlatform.android,
      provider: CompatibilityProvider.admob,
      apiLevel: androidApi,
    ));

void validateReviewedTargets(List<CompatibilityTarget> targets) {
  CompatibilityMatrix.validate(targets);
}
```

`CompatibilityMatrix.minimum` is the package's reviewed test matrix. Current entries use exact Flutter `3.38.1`, Android API at least 34 and iOS API value at least 26 for both providers. **These values describe this helper's reviewed CI/test combinations, not the package's runtime Android minSdk or iOS deployment target.** A newer Flutter version may satisfy pubspec but fail this exact-reviewed-pin check; that is not proof it cannot compile. `validate` rejects an empty/unsupported list with `ArgumentError`. Do not mutate the SDK matrix to make a partner build pass. Record actual environment and escalate an unreviewed combination to the SDK owner. Verify known entry true, unknown/newer Flutter exact-pin result false, and separate actual platform builds/device tests.

#### One owner for optional observers

Create only selected observers after successful SDK initialization. Most constructors immediately subscribe to `AdManager().events`; do not create them during every widget build. `enable*` transfers lifecycle ownership to the singleton manager: replacement disposes the old instance, and `destroy()` disposes attached modules. Do not enable the **same** instance twice (most swap methods would dispose it), share one module across SDK sessions, or call direct module `dispose()` while leaving it registered in the manager. Reconstruct after re-initialization.

The public `disable*` methods are explicitly described in source as test/host seams but annotated `@visibleForTesting`. The helper snippets below suppress only that analyzer warning at those explicit host-owned teardown calls; they do not open a release debug seam or change policy. If partner lint policy forbids these annotated methods, use SDK-wide `destroy()` at the actual session teardown instead and obtain SDK-owner approval before adding a per-module disable control. Async persisted module disposal is bounded; manager disable methods return void, so they do not promise all writes have flushed before process termination.

#### MonetizationArbitrator — extra show veto, not AI

**When:** product has an approved alternative VIP/promotional offer and intentionally wants an extra fullscreen veto. It is a trailing eCPM threshold heuristic, not a learned predictor. **File:** `lib/ad_arbitrator.dart`.

<!-- snippet: ad_arbitrator.dart -->
```dart
import 'dart:async';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

class PartnerArbitrator {
  PartnerArbitrator(this.onNudge);
  final void Function(ArbitratorNudgeEvent) onNudge;
  StreamSubscription<AdEvent>? _events;
  bool _started = false;

  void start() {
    if (_started) throw StateError('Arbitrator already started');
    if (!AdManager().isInitialised) throw StateError('SDK not initialized');
    _started = true;
    final module = MonetizationArbitrator(
      ecpmThresholdMicros: 5000000,
      perSlotThresholdMicros: const {AdSlotType.interstitial: 5000000},
      maxVetoRate: 0.5,
    );
    AdManager().enableArbitrator(module);
    _events = AdManager().events.listen((event) {
      if (event is ArbitratorNudgeEvent) onNudge(event);
    });
  }

  Future<void> stop() async {
    await _events?.cancel();
    _events = null;
    if (!_started) return;
    _started = false;
    // ignore: invalid_use_of_visible_for_testing_member
    AdManager().disableArbitrator();
  }
}
```

Pass a host callback that safely offers approved localized UI; a nudge does not grant VIP, navigate or charge the user automatically. The SDK consults the attached arbitrator after ordinary safety gates at supported fullscreen show paths. The normal completion callback can report not shown after a veto. The sample threshold is illustrative, not revenue advice. `registerVipLikelihoodEstimator(() => value)` accepts a partner-defined 0–1 likelihood; omit it if no defensible signal exists, or pass null to clear it. Do not collect new personal data solely for a fake estimate.

Read `AdManager().arbitrator?.estimatedEcpmMicrosFor(type)` and `vetoRate` for non-mutating diagnostics. `decide`/`decideWithContext` **record a decision** and influence the rolling veto-rate guardrail; do not call them on every rebuild merely to display a label. `maxVetoRate` bounds excessive nudging by forcing show decisions when the rolling veto fraction is too high. No qualified samples means no justified low-value veto; currency/format buckets are separated. This module neither fetches new ads nor switches provider. Offline/consent/VIP gates still win first.

**Verify:** disabled has no effect, low/adequate samples produce expected decisions, nudge UI is optional and disposed safely, guardrail works, and disabling restores ordinary show behavior. Cancel the host stream subscription before the manager/session is destroyed or replaced.

#### FillRateMonitor — current-provider trailing fill

**When:** operations needs a load-success signal, not automatic ad control. **File:** `lib/ad_fill_monitor.dart`. Threshold must be strictly between 0 and 1; rolling window must be positive.

<!-- snippet: ad_fill_monitor.dart -->
```dart
import 'dart:async';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

class PartnerFillMonitor {
  StreamSubscription<FillRateAlert>? _alerts;
  bool _started = false;

  void start(void Function(FillRateAlert) onAlert) {
    if (_started) throw StateError('Fill monitor already started');
    if (!AdManager().isInitialised) throw StateError('SDK not initialized');
    final module = FillRateMonitor(
      lowFillRateThreshold: 0.3,
      rollingWindowSize: 20,
    );
    _started = true;
    _alerts = module.alerts.listen(onAlert);
    AdManager().enableFillRateMonitor(module);
  }

  double? read(AdSlotType type) =>
      AdManager().fillRateMonitor?.fillRate(type);

  Future<void> stop() async {
    await _alerts?.cancel();
    _alerts = null;
    if (!_started) return;
    _started = false;
    // ignore: invalid_use_of_visible_for_testing_member
    AdManager().disableFillRateMonitor();
  }
}
```

Alerts fire once per type after a full trailing window falls below threshold; continued low fill is not an alert per request, and recovery permits a later alert. A value of 1.0 with no observations means no evidence yet, not measured perfect fill. Failures observed while SDK connectivity is offline are excluded. Monitoring creates no extra requests and does not change loading/showing. Cancel host alert subscriptions at teardown, then disable through the owning manager.

**Verify:** fill/no-fill sequence reaches a full window, low fill alerts once, recovery clears suppression, another dip alerts again, offline failures do not pollute provider quality, and invalid thresholds fail during setup rather than silently doing nothing.

#### FillRateBaselineMonitor — local seven-day regression

**When:** compare an installation against its own history; privacy owner approves local metrics retention. **File:** `lib/ad_baseline.dart`. Do not call its constructor: it requires internal preferences. Use the public asynchronous manager factory.

<!-- snippet: ad_baseline.dart -->
```dart
import 'dart:async';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

class PartnerBaselineMonitor {
  StreamSubscription<FillRateRegressionAlert>? _alerts;
  bool _started = false;

  Future<void> start(void Function(FillRateRegressionAlert) onAlert) async {
    if (_started) throw StateError('Baseline monitor already started');
    if (!AdManager().isInitialised) throw StateError('SDK not initialized');
    await AdManager().enableFillRateBaselineMonitor(
      regressionThreshold: 0.2,
      minSamples: 5,
    );
    _started = true;
    _alerts = AdManager().fillRateBaselineMonitor?.alerts.listen(onAlert);
  }

  Map<AdSlotType, FillRateRegressionAlert> active() =>
      AdManager().fillRateBaselineMonitor?.activeAlerts ?? const {};

  Future<void> stop() async {
    await _alerts?.cancel();
    _alerts = null;
    if (!_started) return;
    _started = false;
    // ignore: invalid_use_of_visible_for_testing_member
    AdManager().disableFillRateBaselineMonitor();
  }
}
```

The baseline covers the previous seven calendar days, excluding today; it is not a fleet average. Both current and baseline need `minSamples`. Missing revenue history is represented by nullable revenue values; an empty alert map does not prove stable revenue. The stream does not replay alerts to late listeners; use `active()` for current state. Offline load failures are excluded. No network/extra ad requests are made by this observer. The same single startup owner must await start and serialize start/stop; do not race route disposal against asynchronous setup.

**Verify:** prior-day QA history with sufficient samples triggers the expected fill and/or average-revenue regression, insufficient data does not, invalid threshold/sample count is rejected, cancel/dispose prevents new UI alerts, and retained metrics follow the partner deletion policy.

#### Stable cohorts and CohortOptimizer ceiling

`AdManager().pickProviderCohort()` is the supported public stable per-install 50/50 provider chooser. `pickSessionProvider(...)` can optionally choose the other provider for a real exploration session. Pick before building `AdConfig`, once per SDK session; both provider accounts/native configuration/ad units must already be approved and valid. An Android + AdMob-only partner should leave provider fixed to `AdProvider.admob` and skip this branch.

<!-- snippet: ad_provider_choice.dart -->
```dart
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

Future<AdProvider> chooseApprovedProvider({
  required bool allowSessionExploration,
}) async {
  final stable = AdManager().pickProviderCohort(key: 'partner_provider_test');
  return AdManager().pickSessionProvider(
    installCohortProvider: stable,
    explorationRate: allowSessionExploration ? 0.05 : 0,
    minIntervalBetweenExplorations: const Duration(days: 1),
  );
}
```

Use the returned provider when constructing the one startup config with matching `admob` and `appLovin` configurations. The alternative provider is not a shadow request: that session serves real ads from it, possibly with worse results. Stable cohort choice is not a revenue optimizer. Persistent exploration rate limiting is local; VIP sessions do not consume the committed exploration slot once initialization determines VIP state. Do not swap a running adapter automatically on each recommendation.

**CohortOptimizer is exported but currently lacks a supported barrel-only host construction path.** Its constructor needs internal `AdPreferences`, which is not exported, and the SDK has no public manager factory/attach method for it. It records signed local `SessionCohortRecord`s and can recommend a provider for a later initialization, but an ordinary partner must not import `src/utils/ad_preferences.dart`, instantiate it via dynamic tricks, or pretend the cohort chooser is the same optimizer. Documenting this ceiling is the complete supported integration answer for this release. If the partner explicitly needs that optimizer, escalate an SDK public-API addition to the owner; do not silently ship an unsupported client integration.

**Verify:** stable selection across cold starts, only approved providers returned, exploration disabled returns stable cohort, interval respected and alternate-session assignment uses valid platform units. Unit tests can simulate selection; they do not measure earnings.

#### WaterfallTuner — observe quality, recommend for a later session

**When:** both provider sample histories are intentionally collected across approved sessions. **File:** `lib/ad_waterfall.dart`. The type compares local `(provider, format, placement)` fill rate × average revenue; it does not modify a provider dashboard waterfall or switch a live adapter.

<!-- snippet: ad_waterfall.dart -->
```dart
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

Future<WaterfallTuner> startPartnerWaterfallTuner() async {
  if (!AdManager().isInitialised) throw StateError('SDK not initialized');
  final module = WaterfallTuner(rollingWindowSize: 20, persist: true);
  try {
    await module.ready;
  } catch (_) {
    await module.dispose();
    rethrow;
  }
  AdManager().enableWaterfallTuner(module);
  return module;
}

WaterfallRecommendation? readPartnerWaterfall({
  required AdSlotType type,
  required AdPlacement placement,
}) {
  final manager = AdManager();
  final providerTag = manager.adapter?.tag;
  if (providerTag == null) return null;
  return manager.waterfallTuner?.recommendation(
    type: type,
    placement: placement,
    currentProvider: providerTag,
  );
}

void stopPartnerWaterfallTuner() {
  // ignore: invalid_use_of_visible_for_testing_member
  AdManager().disableWaterfallTuner();
}
```

`ready` means persisted state hydrated and event subscription attached; reads before it may see no history. `persist: true` retains bounded samples locally across SDK sessions; false is session-only. Query returns null with inadequate evidence or when the current provider is already at least as good. The recommended side needs revenue evidence (minimum sample size currently six), not just successful loads. Do not read a non-null recommendation as guaranteed revenue. The maps use provider tags such as `[AdMob]`, not `AdProvider.name` strings. One provider per install without exploration normally cannot supply the other provider's data.

The tuner itself makes no requests and works over cached local metrics offline. Selecting exploration/provider changes can generate real traffic, so those are a separate approved operation. **Verify:** missing/one-sided data returns null, adequate paired data yields expected format/placement recommendation, persistence survives a clean session boundary, corrupt storage does not crash serving, and disable stops observation. The returned module is manager-owned after enable; do not call its dispose separately while registered.

#### ProviderFailoverAdvisor — reliability for the next startup

**When:** both provider configurations are valid and operations approved a fallback on repeated current-provider failures. **File:** `lib/ad_failover.dart`. It does not require both providers' revenue data, unlike the tuner.

<!-- snippet: ad_failover.dart -->
```dart
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

Future<ProviderFailoverAdvisor> createPartnerFailoverAdvisor() async {
  final module = ProviderFailoverAdvisor(
    consecutiveFailureThreshold: 5,
    persist: true,
    cooldown: const Duration(minutes: 5),
  );
  try {
    await module.ready;
  } catch (_) {
    await module.dispose();
    rethrow;
  }
  return module;
}

AdProvider applyPartnerFailover(
  AdProvider candidate,
  ProviderFailoverAdvisor advisor,
) =>
    AdManager().applyProviderFailover(candidate, advisor: advisor);

void attachPartnerFailoverAdvisor(ProviderFailoverAdvisor advisor) {
  AdManager().enableProviderFailoverAdvisor(advisor);
}

void stopPartnerFailoverAdvisor() {
  // ignore: invalid_use_of_visible_for_testing_member
  AdManager().disableProviderFailoverAdvisor();
}
```

**Order:** before the next single initialization, construct/await a fresh advisor, choose stable/session provider, then call `applyPartnerFailover(candidate, advisor)` last. Build that provider's config, initialize once, then attach the same advisor for the live session. If startup aborts before attach, the host owns it and must `await advisor.dispose()`. After attach, manager owns it. Do not reuse an advisor that a previous `destroy()` disposed.

Consecutive failures open a circuit for the tracked provider; success resets the streak. Offline load failures do not count. Open means the helper selects the alternative when the candidate is the failing provider; half-open permits one probe decision, not arbitrary switches. `shouldFailoverNextSession` alone is insufficient because it does not encode the candidate provider or half-open probe. The helper can consume a probe claim, so do not call it repeatedly for display. No automatic concurrent dual adapter exists. `cooldown` must be positive. An incorrect/missing alternate configuration must not be selected merely to recover a test.

**Verify:** hydrate last session's circuit before choosing, five consecutive QA failures open it, intervening success resets, offline failures do not trip it, already-healthy candidate stays selected, half-open claims only one probe, and the next real startup uses the chosen units. This is reliability advice, not proof the other provider will fill.

#### SelfHealingObserver — observe-only prototype

**When:** operations wants an event describing what a future provider-switch system might do. **File:** `lib/ad_self_healing.dart`.

<!-- snippet: ad_self_healing.dart -->
```dart
import 'dart:async';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

class PartnerSelfHealing {
  StreamSubscription<AdEvent>? _events;
  bool _started = false;

  Future<void> start(void Function(AdSelfHealingObserveEvent) onObservation) async {
    if (_started) throw StateError('Self-healing observer already started');
    if (!AdManager().isInitialised) throw StateError('SDK not initialized');
    final module = SelfHealingObserver(
      rollingWindowSize: 20,
      persist: true,
      reobserveAfter: const Duration(days: 7),
    );
    try {
      await module.ready;
    } catch (_) {
      await module.dispose();
      rethrow;
    }
    _events = AdManager().events.listen((event) {
      if (event is AdSelfHealingObserveEvent) onObservation(event);
    });
    AdManager().enableSelfHealingObserver(module);
    _started = true;
  }

  Future<void> stop() async {
    await _events?.cancel();
    _events = null;
    if (!_started) return;
    _started = false;
    // ignore: invalid_use_of_visible_for_testing_member
    AdManager().disableSelfHealingObserver();
  }
}
```

The observer internally uses a waterfall tuner. It emits `AdSelfHealingObserveEvent`; it does not heal native errors, alter safety, switch providers or grant VIP. Without alternative-provider history it may never emit. Persistence preserves both samples and repeated-observation suppression; `reobserveAfter` bounds that suppression. Offline cached evidence may be read, but no requests are made by the observer. **Verify:** enough paired QA evidence yields one observation, repeated evidence is suppressed, expiry of the dedup window allows a new observation, disabled stops events, and no provider/config changes occur automatically. Do not treat “observer enabled” as a production recovery guarantee.

#### JourneyPrefetcher — explicit navigation signals may create real loads

**When:** host navigation predicts an already-approved fullscreen placement and request behavior has been reviewed. **File:** `lib/ad_journey.dart`. Unlike observers, this module may call `loadX()` after an explicit signal or opted-in named route event.

<!-- snippet: ad_journey.dart -->
```dart
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

Future<JourneyPrefetcher> startPartnerJourneyPrefetcher() async {
  if (!AdManager().isInitialised) throw StateError('SDK not initialized');
  final module = JourneyPrefetcher(
    maxHoldDuration: const Duration(minutes: 5),
    maxPendingSignalAge: const Duration(minutes: 5),
    persist: true,
  );
  try {
    await module.ready;
  } catch (_) {
    await module.dispose();
    rethrow;
  }
  AdManager().enableJourneyPrefetcher(module);
  return module;
}

void signalApprovedLevelStart() {
  AdManager().journeyPrefetcher?.notifySignal(
        'level_started',
        AdSlotType.interstitial,
      );
}

Duration? learnedLevelToAdDelay() =>
    AdManager().journeyPrefetcher?.averageTimeToShow(
          'level_started',
          AdSlotType.interstitial,
        );

void stopPartnerJourneyPrefetcher() {
  // ignore: invalid_use_of_visible_for_testing_member
  AdManager().disableJourneyPrefetcher();
}
```

Use stable non-PII signal names, not URLs containing identifiers, search text or tokens. First unknown signal/type has no learned delay, so it may preload immediately; a null average is “not learned”, not zero delay. `maxHoldDuration` stops eager preload when learned time to show would hold a creative too long. `maxPendingSignalAge` discards stale unmatched signal observations; these are different limits. All real requests still go through manager load gates. Persistence stores local timing history; privacy owner decides retention.

For automatic route signals, construct with `autoRouteSignalType: AdSlotType.interstitial` and add `module.routeObserver` to the host's navigator observer list in addition to the required SDK observers. It is null when no auto type was configured. Routes need `RouteSettings(name: ...)`; unnamed routes are ignored. Push/pop/replacement can signal, so do not simultaneously issue the same manual signal for that transition. Remove the observer from rebuilt navigator configuration when the owner disposes it. The manual-signal sample avoids rebuilding navigator observer configuration.

**Verify:** signal with no history can load; stale signal does not train timing; failed show does not train a successful time-to-show; hidden/sensitive/unapproved routes emit no host signals; consent/VIP/offline gates still block; disable cancels observation and stops signal work. This is not permission to preload unviewable inventory indiscriminately.

#### MonetizationDigitalTwin — read-only daily-cap forecast

**When:** analyst/product wants a local counterfactual over existing SDK history. **File:** `lib/ad_forecast.dart`. No attach, background task or dispose.

<!-- snippet: ad_forecast.dart -->
```dart
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

DigitalTwinForecast? forecastPartnerDailyCap(int hypotheticalCap) {
  final twin = AdManager().buildMonetizationDigitalTwin();
  return twin?.forecastDailyCap(hypotheticalCap);
}

DigitalTwinForecast forecastProvidedHistory(
  List<Map<String, dynamic>> sdkLogEntries,
  int hypotheticalCap,
) =>
    MonetizationDigitalTwin(sdkLogEntries).forecastDailyCap(hypotheticalCap);
```

Manager factory returns null before an SDK event log exists. Forecast supports the daily-cap axis only; fields include `daysObserved`, `meanDailyImpressions`, `medianDailyImpressions`, `meanDailyRevenueMicros`, and `meanBlockedRequestsRemaining`. It never changes live `AdSafetyConfig`, requests ads, proves income, or models every causal effect of changing placement/frequency. Existing capped logs cannot prove unlimited demand, and low `daysObserved` means weak evidence. Standalone input must use actual redacted SDK log schema, not arbitrary maps from a third-party analytics system. Works offline over retained history. **Verify:** known small history yields expected totals, empty history shows zero observed days, lower/higher caps change only the forecast, and live safety values/traffic remain unchanged.

#### RevenueIntegrityLedger — missing-callback investigation signal

**When:** support needs a local signal for a successful show without timely matching revenue. **File:** `lib/ad_revenue_integrity.dart`.

<!-- snippet: ad_revenue_integrity.dart -->
```dart
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

void startPartnerRevenueIntegrity() {
  if (!AdManager().isInitialised) throw StateError('SDK not initialized');
  AdManager().enableRevenueIntegrityLedger(
    RevenueIntegrityLedger(matchWindow: const Duration(seconds: 60)),
  );
}

int? pendingPartnerRevenueChecks() =>
    AdManager().revenueIntegrityLedger?.pendingCount;

int recentPartnerRevenueIncidents() =>
    AdManager().diagnostics().recentRevenueIntegrityIncidents;

void stopPartnerRevenueIntegrity() {
  // ignore: invalid_use_of_visible_for_testing_member
  AdManager().disableRevenueIntegrityLedger();
}
```

Start once, not per build. The ledger matches request IDs when present; otherwise it uses a format/provider/placement/time-window heuristic. `pendingCount` means waiting, not lost money. Missing matches are recorded through the manager's incident recorder, not uploaded. Timer/resume sweeps use wall-clock time; sleep and clock corrections can affect expiry. Late SDK/network callbacks, test creatives and provider differences can produce false positives. This module is not proof of fraud, settlement loss or a billing audit. No requests are made. Disable drops pending checks without turning teardown into a missing-revenue incident; SDK destroy cancels it as well.

**Verify:** paired QA show/revenue resolves a pending check, missing revenue after configured window creates an incident, a late callback does not cause duplicate business actions, mismatched request IDs do not incorrectly resolve other shows, and teardown cancels timers/subscriptions. Native event attribution needs device evidence, not just fake events.

#### RevenueAnomalyDetector — standalone analysis or manager query

**When:** investigate zero-revenue, spikes, mixed currencies or duplicate/colliding request IDs in existing logs. **File:** `lib/ad_revenue_analysis.dart`. No attach or dispose.

<!-- snippet: ad_revenue_analysis.dart -->
```dart
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

List<RevenueAnomaly> analyzePartnerRevenue() =>
    AdManager().revenueAnomalies(minimumSamples: 5);

List<RevenueAnomaly> analyzeProvidedSdkEntries(
  Iterable<Map<String, dynamic>> entries,
) =>
    const RevenueAnomalyDetector(minimumSamples: 5).analyze(entries);
```

`minimumSamples` must be positive. The manager uses its retained SDK event log; standalone maps require the SDK log schema (`eventType: 'AdRevenueEvent'`, integer `valueMicros`, `currencyCode`, optional `requestId`, `providerTag`, `slotType`). Treat any imported JSON as untrusted: validate its schema/types at the host import boundary before passing it to `analyze`, which is not a general JSON validator. Read `kind`, `message` and optional requestId without exporting identifiers. It returns an empty list for insufficient qualifying samples, not a clean audit verdict. It does not stop ads, write incidents itself or change the arbitrator. Offline use is arithmetic over local history. **Verify:** known zero/spike/mixed currency/duplicate test records produce intended kinds; insufficient samples return none; invalid minimum fails; no serving state changes.

#### AdDiagnostics — snapshot and bounded safe export

**When:** support needs a view of enabled module state. **File:** `lib/ad_diagnostics_snapshot.dart`. Query only; calling it does not enable monitors.

<!-- snippet: ad_diagnostics_snapshot.dart -->
```dart
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

AdDiagnostics readPartnerAdDiagnostics() => AdManager().diagnostics();

Future<String> exportPartnerAdDiagnostics() =>
    AdManager().exportSafeDiagnostics(maxBytes: 65536);

Future<bool> verifyPartnerAdDiagnostics(String encoded) =>
    AdDiagnostics.verifySafeJsonString(encoded);
```

Fields are `lastWaterfallBySlot`, `fillRateBySlot`, `arbitratorEstimatedEcpmMicros`, `arbitratorVetoRate`, `fillRateRegressionBySlot`, `pendingRevenueChecks`, and `recentRevenueIntegrityIncidents`. Empty/null values can mean the associated module was never enabled; do not render them as measured zero. Prefer bounded `exportSafeDiagnostics()` over raw `toJson()` in support sharing. The safe format redacts known operational identifiers and includes schema/checksum; that checksum is integrity checking, not authenticated identity. The host still owns consent, review/redaction, file location, retention, user approval and upload/share transport. Never add an automatic upload solely because export returns a string. `maxBytes` below the supported minimum is an argument error. Offline snapshots/exports work over available local state; storage/plugin failures should be shown as support-export errors, not a reason to erase data.

**Verify:** disabled-monitor nulls remain distinguishable, enabled metrics appear, bounded output checks verify, a changed payload fails its checksum, and support exports/logs contain no private key, entered VIP code or raw consent string.

#### Coherent startup and teardown for these recipes

For a normal local configuration with no remote safety, keep the controller startup from Step 4.2 and construct only the chosen observer owners in its successful init callback. For the remote-safety branch, use exactly one manual splash and replace its one init invocation with `initializeWithRemoteSafety`; module setup is serialized in that branch's successful init completion path. A provider-experiment/failover choice must finish before building the config; never call `initialize()` again merely to attach an observer.

Observer constructors listen to the current manager event stream. Creating them before initialization can miss/receive startup events unexpectedly; creating them after initialization intentionally begins their observation at that point, so do not claim the entire cold-start history was captured. UI-only routes do not own app-session modules. The app-session owner retains each start helper/owner object, prevents parallel start/stop calls, cancels its own alert/nudge subscriptions first, and calls the matching stop helpers if it disables a module mid-session. For an actual SDK teardown, cancel host subscriptions and `await AdManager().destroy()` once; manager owns attached module disposal. Do not follow that with a second direct `module.dispose()`.

The manager's asynchronous persisted modules expose `ready` to hydrate old history before read/use; an enable wrapper returning void does not await every later persisted write. Do not force-kill the process immediately after a metric event and claim persistence is guaranteed. No observers are a replacement for native ad/consent/device testing, and none certifies legal or provider-policy compliance.


### 4.17 — Custom native layouts (AdMob Android/iOS and AppLovin)

Use a custom layout only when the product needs it. The default `NativeAdWidget()` works without a host factory. These recipes assume the SDK, platform App IDs and UMP are already configured. Keep native ad containers visually separate from app navigation and other controls. An “Ad” label, visible AdChoices control, adequate media space and provider-managed click handling are not optional. Do not add your own click handlers or opaque overlays over a native ad.

#### N1 — AdMob custom layout on Android

1. Confirm the app's `android.namespace` in `android/app/build.gradle.kts` and the Kotlin package of its `MainActivity`. Replace `com.partner.app` below with those real package names. If namespace differs from the Activity package, import the namespace's `R` class in the factory.
2. Create the XML and factory below. Each XML ID must match the factory lookup.
3. Merge factory registration into the existing Activity; do not discard deep-link, engine, or other plugin setup. Register only after `super.configureFlutterEngine`; pair it with unregister at engine cleanup.
4. In Dart, use the same factory ID and enough height. A missing registration or wrong ID is a load/integration error; it does not fall back to the default Google template.

Host file: `android/app/src/main/res/layout/partner_native_ad.xml`.

<!-- snippet: partner_native_ad.xml -->
```xml
<?xml version="1.0" encoding="utf-8"?>
<com.google.android.gms.ads.nativead.NativeAdView
    xmlns:android="http://schemas.android.com/apk/res/android"
    android:layout_width="match_parent"
    android:layout_height="wrap_content">
  <LinearLayout
      android:layout_width="match_parent"
      android:layout_height="wrap_content"
      android:background="#FFFFFF"
      android:orientation="vertical"
      android:padding="12dp">
    <FrameLayout
        android:layout_width="match_parent"
        android:layout_height="wrap_content">
      <TextView
          android:layout_width="wrap_content"
          android:layout_height="wrap_content"
          android:background="#FCCC3C"
          android:padding="2dp"
          android:text="Ad"
          android:textColor="#111111"
          android:textSize="12sp" />
      <com.google.android.gms.ads.nativead.AdChoicesView
          android:id="@+id/partner_ad_choices"
          android:layout_width="24dp"
          android:layout_height="24dp"
          android:layout_gravity="top|end" />
    </FrameLayout>
    <LinearLayout
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:orientation="horizontal"
        android:paddingEnd="24dp">
      <ImageView
          android:id="@+id/partner_ad_icon"
          android:layout_width="40dp"
          android:layout_height="40dp"
          android:layout_marginEnd="8dp" />
      <TextView
          android:id="@+id/partner_ad_headline"
          android:layout_width="0dp"
          android:layout_height="wrap_content"
          android:layout_weight="1"
          android:textColor="#111111"
          android:textSize="16sp"
          android:textStyle="bold" />
    </LinearLayout>
    <TextView
        android:id="@+id/partner_ad_body"
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:layout_marginTop="4dp"
        android:maxLines="2"
        android:textColor="#333333"
        android:textSize="13sp" />
    <com.google.android.gms.ads.nativead.MediaView
        android:id="@+id/partner_ad_media"
        android:layout_width="match_parent"
        android:layout_height="180dp"
        android:layout_marginTop="8dp" />
    <Button
        android:id="@+id/partner_ad_cta"
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:layout_marginTop="8dp" />
  </LinearLayout>
</com.google.android.gms.ads.nativead.NativeAdView>
```

Host file: `android/app/src/main/kotlin/com/partner/app/PartnerNativeAdFactory.kt`.

<!-- snippet: PartnerNativeAdFactory.kt -->
```kotlin
package com.partner.app

import android.view.LayoutInflater
import android.view.View
import android.widget.Button
import android.widget.ImageView
import android.widget.TextView
import com.google.android.gms.ads.nativead.MediaView
import com.google.android.gms.ads.nativead.NativeAd
import com.google.android.gms.ads.nativead.NativeAdView
import io.flutter.plugins.googlemobileads.NativeAdFactory

class PartnerNativeAdFactory(private val inflater: LayoutInflater) : NativeAdFactory {
    override fun createNativeAd(
        nativeAd: NativeAd,
        customOptions: MutableMap<String, Any>?,
    ): NativeAdView {
        val view = inflater.inflate(R.layout.partner_native_ad, null) as NativeAdView
        view.mediaView = view.findViewById<MediaView>(R.id.partner_ad_media)
        view.headlineView = view.findViewById(R.id.partner_ad_headline)
        view.bodyView = view.findViewById(R.id.partner_ad_body)
        view.callToActionView = view.findViewById(R.id.partner_ad_cta)
        view.iconView = view.findViewById(R.id.partner_ad_icon)
        view.adChoicesView = view.findViewById(R.id.partner_ad_choices)

        (view.headlineView as TextView).text = nativeAd.headline
        view.bodyView?.visibility = if (nativeAd.body == null) View.GONE else View.VISIBLE
        (view.bodyView as TextView).text = nativeAd.body
        nativeAd.mediaContent?.let { view.mediaView?.mediaContent = it }

        val cta = view.callToActionView as Button
        cta.text = nativeAd.callToAction
        cta.visibility = if (nativeAd.callToAction == null) View.GONE else View.VISIBLE
        cta.isEnabled = false
        cta.isClickable = false

        val icon = view.iconView as ImageView
        icon.setImageDrawable(nativeAd.icon?.drawable)
        icon.visibility = if (nativeAd.icon == null) View.GONE else View.VISIBLE
        view.setNativeAd(nativeAd)
        return view
    }
}
```

Host file: merge into `android/app/src/main/kotlin/com/partner/app/MainActivity.kt`. This is the complete minimal Activity for a standard `FlutterActivity` host; retain the existing Activity base class and other methods if the app uses `FlutterFragmentActivity`, cached engines or custom embedding.

<!-- snippet: MainActivity.kt -->
```kotlin
package com.partner.app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugins.googlemobileads.GoogleMobileAdsPlugin

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        GoogleMobileAdsPlugin.registerNativeAdFactory(
            flutterEngine,
            "partnerNativeAd",
            PartnerNativeAdFactory(layoutInflater),
        )
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        GoogleMobileAdsPlugin.unregisterNativeAdFactory(flutterEngine, "partnerNativeAd")
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
```

Host file: `lib/ads/partner_native_placement.dart`. This widget must be mounted only in an approved visible placement. Supply `active: false` while its tab/route is hidden. The default template path remains available by omitting `factoryId`.

<!-- snippet: partner_native_placement.dart -->
```dart
import 'package:flutter/material.dart';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

class PartnerNativePlacement extends StatelessWidget {
  const PartnerNativePlacement({super.key, required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) => NativeAdWidget(
        factoryId: 'partnerNativeAd',
        height: 380,
        active: active,
      );
}
```

**Acceptance:** build an Android debug APK, load the Google native test unit on a QA device, confirm the custom layout rather than the default template appears, all available assets are readable, AdChoices is visible/tappable, no widget covers the ad, and route/tab disposal removes the placement. Exercise missing icon/body/CTA, large text and narrow windows. A Dart analysis or Gradle compile alone does not prove rendering or policy compliance. Offline/no-fill follows normal SDK retry/error handling; do not manufacture a fake “loaded” state.

#### N2 — AdMob custom layout on iOS

1. Add `PartnerNativeAdFactory.swift` to the Runner target in Xcode, not merely to a folder. The programmatic factory below needs no `.xib`.
2. Use the AppDelegate registration recipe matching the host's engine lifecycle. The sample below matches the modern implicit-engine setup used by the SDK example. Do not replace a host-owned engine or register plugins twice.
3. Use the same Dart `PartnerNativePlacement` above. Configure iOS ad-unit overrides; never request Android unit IDs from iOS.

Host file: `ios/Runner/PartnerNativeAdFactory.swift`.

<!-- snippet: PartnerNativeAdFactory.swift -->
```swift
import UIKit
import google_mobile_ads

final class PartnerNativeAdFactory: NSObject, FLTNativeAdFactory {
    func createNativeAd(
        _ nativeAd: NativeAd,
        customOptions: [AnyHashable: Any]?
    ) -> NativeAdView? {
        let adView = NativeAdView(frame: .zero)
        let badge = UILabel()
        badge.text = "Ad"
        badge.textColor = .black
        badge.backgroundColor = .systemYellow
        badge.font = .boldSystemFont(ofSize: 12)

        let choices = AdChoicesView()
        choices.translatesAutoresizingMaskIntoConstraints = false
        choices.widthAnchor.constraint(equalToConstant: 24).isActive = true
        choices.heightAnchor.constraint(equalToConstant: 24).isActive = true
        adView.adChoicesView = choices

        let header = UIStackView(arrangedSubviews: [badge, UIView(), choices])
        header.axis = .horizontal
        header.alignment = .top

        let icon = UIImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 40).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 40).isActive = true
        icon.contentMode = .scaleAspectFit
        adView.iconView = icon

        let title = UILabel()
        title.font = .boldSystemFont(ofSize: 16)
        title.textColor = .label
        title.numberOfLines = 2
        adView.headlineView = title
        let titleRow = UIStackView(arrangedSubviews: [icon, title])
        titleRow.axis = .horizontal
        titleRow.alignment = .center
        titleRow.spacing = 8

        let body = UILabel()
        body.font = .systemFont(ofSize: 13)
        body.textColor = .secondaryLabel
        body.numberOfLines = 2
        adView.bodyView = body

        let media = MediaView()
        media.translatesAutoresizingMaskIntoConstraints = false
        media.heightAnchor.constraint(equalToConstant: 180).isActive = true
        adView.mediaView = media

        let cta = UIButton(type: .system)
        cta.isUserInteractionEnabled = false
        cta.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        adView.callToActionView = cta

        let column = UIStackView(arrangedSubviews: [header, titleRow, body, media, cta])
        column.axis = .vertical
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        adView.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: adView.leadingAnchor, constant: 12),
            column.trailingAnchor.constraint(equalTo: adView.trailingAnchor, constant: -12),
            column.topAnchor.constraint(equalTo: adView.topAnchor, constant: 12),
            column.bottomAnchor.constraint(lessThanOrEqualTo: adView.bottomAnchor, constant: -12),
        ])

        title.text = nativeAd.headline
        body.text = nativeAd.body
        body.isHidden = nativeAd.body == nil
        icon.image = nativeAd.icon?.image
        icon.isHidden = nativeAd.icon == nil
        media.mediaContent = nativeAd.mediaContent
        cta.setTitle(nativeAd.callToAction, for: .normal)
        cta.isHidden = nativeAd.callToAction == nil
        adView.nativeAd = nativeAd
        return adView
    }
}
```

Host file: merge into `ios/Runner/AppDelegate.swift`. Preserve existing plugin registrations and application behavior. `releaseCustomNativeFactory()` is a host-callable teardown method, **not** an invented Flutter lifecycle callback: call it while the old registry is still alive if the host explicitly destroys/replaces its engine. A normal application-lifetime implicit engine keeps the registration for that engine's lifetime. Do not unregister when an individual Dart route closes; its ad widget owns the per-view disposal.

<!-- snippet: AppDelegate.swift -->
```swift
import Flutter
import UIKit
import google_mobile_ads

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
    private let nativeFactory = PartnerNativeAdFactory()
    private var nativeRegistry: FlutterPluginRegistry?
    private let nativeFactoryId = "partnerNativeAd"

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
        releaseCustomNativeFactory()
        GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
        nativeRegistry = engineBridge.pluginRegistry
        _ = FLTGoogleMobileAdsPlugin.registerNativeAdFactory(
            engineBridge.pluginRegistry,
            factoryId: nativeFactoryId,
            nativeAdFactory: nativeFactory
        )
    }

    func releaseCustomNativeFactory() {
        guard let registry = nativeRegistry else { return }
        _ = FLTGoogleMobileAdsPlugin.unregisterNativeAdFactory(
            registry,
            factoryId: nativeFactoryId
        )
        nativeRegistry = nil
    }
}
```

For an older non-implicit-engine Flutter host, the same plugin APIs take the host's already registered `FlutterPluginRegistry` (for example the AppDelegate/explicit engine). Register once immediately after `GeneratedPluginRegistrant.register(with: registry)`; pair unregister with that explicit engine owner's teardown. Do not add the implicit-engine callback to a host using a different lifecycle. If the pinned Flutter embedding does not expose these types, adapt the registry acquisition to that embedding rather than changing the SDK dependencies blindly.

**Acceptance:** resolve Pods, compile the target actually used by the host, then inspect a filled custom native test ad on the target device/simulator with accessible contrast, AdChoices, asset resizing and safe route disposal. Test ATT/UMP sequencing separately. Successful pod installation proves dependency resolution only; successful Xcode compilation does not prove an ad rendered, dismissal worked, or privacy policy was met.

#### N3 — AppLovin custom Flutter asset layout

This branch is only for an approved AppLovin build. AdMob's `factoryId` has no effect here. Native asset types come from `applovin_max`; the SDK barrel does not re-export them. If importing these types, declare the already compatible `applovin_max` dependency in the host rather than relying on an undeclared transitive import. Keep the version in the range permitted by the pinned SDK/native mediation graph; for the reviewed graph it is `applovin_max: ^4.6.4`. Do not upgrade the native graph for this recipe.

Host file: `lib/ads/partner_applovin_native.dart`.

<!-- snippet: partner_applovin_native.dart -->
```dart
import 'package:flutter/material.dart';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_max/applovin_max.dart';

class PartnerAppLovinNative extends StatelessWidget {
  const PartnerAppLovinNative({super.key, required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) => NativeAdWidget(
        height: 320,
        active: active,
        customNativeAdBuilder: (context) => const Padding(
          padding: EdgeInsets.all(8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MaxNativeAdTitleView(
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 4),
              MaxNativeAdBodyView(),
              SizedBox(height: 8),
              MaxNativeAdCallToActionView(),
            ],
          ),
        ),
      );
}
```

The SDK always overlays `MaxNativeAdOptionsView` and reserves 24 logical pixels at top/right. Do **not** put another options view in the builder or overlay host controls on that region. Height/width below the minimum attribution space cause fallback to the standard layout rather than an unsafe tiny custom layout. Available asset widgets additionally include icon, media, rating and advertiser views; use provider asset widgets, not copied ad text or host click handlers. Keep active/hidden-tab state explicit. SDK default layout, consent gates and AppLovin native view lifecycle still apply.

**Acceptance:** with a real QA AppLovin key/unit and test mode, confirm assets and mandatory options badge are readable, their touch targets are not covered, hidden tabs do not request ads, offline/no-fill does not leave host controls disabled, and disposal removes the view. The audited native `InlineAdController.refresh()` path must not be used as proof a new creative loaded; test actual remount/reload behavior for the pinned release.



### 4.18 — QA, runtime controls and custom-provider boundary

#### Offline scenario tests

**When:** test the host's event handling and scripted success/failure without native SDKs, credentials, auctions or network. This does not test `AdManager` consent/safety gates, native rendering, dismissal, or provider policy. `ScenarioRunner` runs directly against `FakeAdProviderAdapter`; `ScenarioResult.success` means the script completed without an exception, not that each ad loaded successfully. Assert the emitted outcomes separately.

**Host file:** `test/ad_scenarios_test.dart`. Add Flutter's standard `flutter_test` SDK development dependency if the host does not already have it. Run `flutter test test/ad_scenarios_test.dart` from the consuming app root. No internal imports or debug injection are needed.

<!-- snippet: ad_scenarios_test.dart -->
```dart
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('interstitial script emits a successful load and show', () async {
    final adapter = FakeAdProviderAdapter();
    final runner = ScenarioRunner(adapter: adapter);
    try {
      final result = await runner.run(const [
        ScenarioStep(action: ScenarioStepAction.initialize),
        ScenarioStep(action: ScenarioStepAction.loadInterstitial),
        ScenarioStep(action: ScenarioStepAction.showInterstitial),
      ]);
      expect(result.success, isTrue);
      expect(result.error, isNull);
      final load = result.events.whereType<AdLoadEvent>().single;
      final show = result.events.whereType<AdShowEvent>().single;
      expect(load.type, AdSlotType.interstitial);
      expect(load.success, isTrue);
      expect(show.type, AdSlotType.interstitial);
      expect(show.success, isTrue);
      expect(adapter.loadInterstitialCalls, 1);
      expect(adapter.showInterstitialCalls, 1);
    } finally {
      await adapter.dispose();
    }
  });

  test('rewarded load failure does not emit an earned reward', () async {
    final adapter = FakeAdProviderAdapter();
    try {
      final result = await ScenarioRunner(adapter: adapter).run(const [
        ScenarioStep(action: ScenarioStepAction.initialize),
        ScenarioStep(
          action: ScenarioStepAction.loadRewarded,
          shouldSucceed: false,
        ),
        ScenarioStep(action: ScenarioStepAction.showRewarded),
      ]);
      expect(result.success, isTrue);
      expect(result.events.whereType<AdLoadEvent>().single.success, isFalse);
      expect(result.events.whereType<AdShowEvent>().single.success, isFalse);
      expect(result.events.whereType<AdRewardEvent>(), isEmpty);
    } finally {
      await adapter.dispose();
    }
  });
}
```

`ScenarioStep.loadDelay` delays a fake load; `shouldSucceed` selects its result. Steps exist for initialize, load/show App Open, Interstitial, Rewarded, and Rewarded Interstitial. `placement`, `ssvUserId` and `ssvCustomData` are script inputs, not proof of a real server postback. Always dispose a runner's adapter when the test/harness owns it; the runner restores its prior event sink after a run but does not dispose it. Omit `eventLog` for this public-only standalone test: constructing the persistent `AdEventLog` requires internal preferences. For persisted replay in a real initialized app use the manager's export/digital-twin APIs, not a private `src/` import.

**Acceptance:** both tests pass offline, failure produces no earned event, and no real ad unit/native channel is contacted. If the host changes reward mapping, add a host assertion for its actual reward outcome rather than treating these adapter tests as integration proof.

#### Custom adapter boundary and a runnable test extension

`AdProviderAdapter` is public so tests and SDK extensions can implement its contract. Its required responsibilities are: event sink and `canReload` gate; one state-machine slot per fullscreen format; independently keyed Banner/MREC/Native slots/listenables; initialize/consent/discard/dispose; format-specific load/show callbacks and matching per-key inline disposal; adaptive/native view integration and inline route pause/resume hooks. Use slot transitions, do not invent parallel ready/showing booleans. Callbacks must respect disposed instances and the owning request/session; do not emit another instance's revenue or reward.

**Production ceiling:** the current `AdManager.initialize` constructs only built-in AdMob/AppLovin adapters. It has no production adapter-registration argument. `AdManager.debugAdapterFactory` is a static test hook, not an `initialize` named parameter; `debugSetAdapter` and debug factories are blocked in release. Do not ship a fake adapter, private import, or disabled release guard to bypass this ceiling. An actual new provider needs an SDK-owner-supported API/release, outside this integration document.

For a host reward regression, extending the fake in a test is supported and smaller than implementing every interface member. This extension simulates a shown rewarded ad that grants nothing; it deliberately tests host interpretation of `RewardResult`, not provider callback wiring.

**Host file:** `test/reward_without_grant_test.dart`.

<!-- snippet: reward_without_grant_test.dart -->
```dart
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

class RewardlessFake extends FakeAdProviderAdapter {
  @override
  Future<void> showRewarded({
    required void Function(RewardResult result) onDone,
    String? ssvUserId,
    String? ssvCustomData,
  }) async {
    onDone(const RewardResult(earned: false, shown: true));
  }
}

void main() {
  test('shown is not the same as earned', () async {
    final adapter = RewardlessFake();
    try {
      final result = await ScenarioRunner(adapter: adapter).run(const [
        ScenarioStep(action: ScenarioStepAction.initialize),
        ScenarioStep(action: ScenarioStepAction.loadRewarded),
        ScenarioStep(action: ScenarioStepAction.showRewarded),
      ]);
      expect(result.success, isTrue);
      expect(result.events.whereType<AdShowEvent>().single.success, isTrue);
      expect(result.events.whereType<AdRewardEvent>(), isEmpty);
    } finally {
      await adapter.dispose();
    }
  });
}
```

Run `flutter test test/reward_without_grant_test.dart`. A pass does not demonstrate that skipping a real creative produces the expected native callback; verify that separately with provider test inventory.

#### Runtime controls — use the public host hooks

#### Smart preload and App Open selection

**When:** choose this once while building the single `AdConfig` that the startup owner passes to the SDK. This example is a complete library, not an extra initialization call. The caller supplies the `AdMobConfig` from Step 4.2, with correct per-platform units.

**Host file:** `lib/ad_runtime_policy.dart`.

<!-- snippet: ad_runtime_policy.dart -->
```dart
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

AdConfig buildAdRuntimePolicy({
  required AdMobConfig units,
  AppOpenTrigger appOpenTrigger = AppOpenTrigger.resumeOnly,
  bool smartPreload = true,
}) => AdConfig(
      provider: AdProvider.admob,
      admob: units,
      firstInstallVipGrace: FirstInstallVipGrace.disabled,
      keepScreenOnDuringSession: false,
      appOpenTrigger: appOpenTrigger,
      smartPreloadEnabled: smartPreload,
    );

void onApprovedUserEngagement() {
  AdManager().markUserEngaged();
}
```

`AppOpenTrigger.both`, `.resumeOnly`, and `.splashOnly` select SDK-allowed trigger categories. The enum has no `none` value. The splash controller's `showAppOpenOnReady: false` disables its own splash attempt; it does not disable resume App Open. Do not make up an undocumented off switch. Omit ad triggers/units only according to the approved integration policy and test what the chosen combination actually does.

`smartPreloadEnabled` defaults true. It defers automatic secondary preload (interstitial/rewarded/rewarded-interstitial) until engagement. Source currently releases this after its timer/navigation signal or explicit `markUserEngaged()`. Call that method only for a real approved engagement action, not every build/frame. Host-called `loadInterstitial()` / `loadRewardedAd()` are explicit requests and are not this automatic-defer mechanism. `AdScreenState.preloadRewardedOnMount` defaults false; overriding it requests automatic preload but does not bypass consent, VIP, connectivity or smart-preload gates. Setting `smartPreloadEnabled: false` restores eager automatic behavior, not safety bypass.

**Acceptance:** one startup; no ad request before consent allows it; automatic secondary requests defer as configured; explicit load stays explicit; no earned reward from preloading. In a disposable QA build test offline startup/reconnect and consent withdrawal. Do not treat a configured preload as guaranteed fill.

#### Hidden tabs, overlays and local fallback

**When:** host uses an `IndexedStack`, custom overlay or wants a local promotion instead of a blank no-fill area. `AdScreenRouteLogger` observes routes, not arbitrary `OverlayEntry`s. One controller owns one mounted inline widget; do not combine `active` with a controller on Banner/MREC. Native also rejects `active: false` with a controller.

**Host file:** `lib/inline_ad_examples.dart`. `assetPath` must name a real local host asset declared under `flutter: assets:` in host `pubspec.yaml`; this API does not download one. The callbacks supplied here belong to the host's existing navigation. Do not give a local house ad the appearance of a Google/AppLovin creative.

<!-- snippet: inline_ad_examples.dart -->
```dart
import 'package:flutter/material.dart';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

class SelectedTabAd extends StatelessWidget {
  const SelectedTabAd({super.key, required this.selected});
  final bool selected;

  @override
  Widget build(BuildContext context) => BannerAdWidget(active: selected);
}

Widget localPromotionFallback({
  required String assetPath,
  required String title,
  required VoidCallback onOpenPromotion,
}) => BannerAdWidget(
      houseAd: HouseAdItem(
        assetPath: assetPath,
        title: title,
        subtitle: 'App promotion',
        onTap: onOpenPromotion,
      ),
      houseAdDelay: const Duration(seconds: 10),
    );

Future<T> withSingleCustomOverlay<T>(Future<T> Function() showOverlay) async {
  markCustomOverlayOnScreen(true);
  try {
    return await showOverlay();
  } finally {
    markCustomOverlayOnScreen(false);
  }
}

Future<void> openSafeSheet(BuildContext context) async {
  await showAdSafeModalBottomSheet<void>(
    context: context,
    builder: (_) => const SafeArea(child: Text('Partner sheet content')),
  );
}
```

Pass `selectedIndex == thisTabIndex` to each hidden tab's Banner/MREC and Native activity. MREC uses `MrecAdWidget(active: selected, houseAd: item)` with the same fallback type. The fallback is local content: it emits no ad impression/revenue event and is not network fill. Test missing assets, fallback delay/no-fill, real ad recovery, route changes and VIP suppression.

`withSingleCustomOverlay` is only for one overlay owner with no overlapping custom overlays. The SDK flag is a plain boolean, not a ref-count; when multiple owners exist, the host must coordinate its own true count and clear only after the last overlay closes. Never wrap it separately around two overlapping overlays. `AdSensitiveScreen(child: actualPaymentOrOtpScreen)` suppresses resume App Open while mounted; it does not suppress other ad formats. Nested navigators need their own `AdScreenRouteLogger()` and the root-safe sheet helper; do not share one RouteObserver instance across unrelated navigators without reviewing navigator ownership.

#### Owned inline controller

**Host file:** `lib/controlled_banner.dart`. Use when an imperative host UI, rather than `active`, owns one banner's pause/resume. The controller starts active, can remember an early command before attach, and reports `detached`/`active`/`paused`. `refresh()` remains gated by policy/cooldown; it does not guarantee a new ad. Use one controller per placement and dispose it after detaching through normal widget teardown. Do not reuse it for a second simultaneous widget.

<!-- snippet: controlled_banner.dart -->
```dart
import 'package:flutter/material.dart';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

class ControlledBanner extends StatefulWidget {
  const ControlledBanner({super.key});

  @override
  State<ControlledBanner> createState() => _ControlledBannerState();
}

class _ControlledBannerState extends State<ControlledBanner> {
  final InlineAdController _controller = InlineAdController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          BannerAdWidget(controller: _controller),
          Wrap(
            children: [
              TextButton(onPressed: _controller.pause, child: const Text('Pause')),
              TextButton(onPressed: _controller.resume, child: const Text('Resume')),
              TextButton(onPressed: _controller.refresh, child: const Text('Refresh')),
            ],
          ),
        ],
      );
}
```

Acceptance: pause stops owned banner activity, resume respects current gates, refresh while paused does not silently resume, and screen teardown leaves no controller callbacks into disposed state. Test corresponding MREC/Native behavior separately; Native pause disposes its live instance rather than merely suspending an auto-refresh ticker. This does not fix any provider-specific native-refresh issue in the audited SDK release.

#### Self-check, SDK state, debug overlay and revenue panel

**When:** an internal QA screen needs current gates/load diagnostics. Initialize the SDK first. Self-check can request real ads; only run against configured QA inventory/devices. It is skipped outside debug and does not erase VIP, reset consent, or destroy the SDK. `SelfCheckResult.allPassed` means no item has status `fail`; a result containing skipped items is not proof they ran.

**Host file:** `lib/ad_qa_panel.dart`. Mount under the host MaterialApp after SDK startup; do not mount duplicate event-consuming panels as production analytics.

<!-- snippet: ad_qa_panel.dart -->
```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

class AdQaPanel extends StatelessWidget {
  const AdQaPanel({super.key});

  @override
  Widget build(BuildContext context) {
    if (!kDebugMode) return const SizedBox.shrink();
    return Stack(
      children: [
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ValueListenableBuilder<AdSdkStateSnapshot>(
              valueListenable: AdManager().stateSnapshot,
              builder: (_, state, __) => Text(
                'init=${state.isInitialised} '
                'consentGate=${state.canRequestAds} '
                'offline=${state.isOffline} '
                'vip=${state.isVipActive} '
                'fullscreen=${state.fullscreenBusy}',
              ),
            ),
            const RevenuePanel(compact: true),
            ElevatedButton(
              onPressed: () async {
                final result = await AdManager().runIntegrationSelfCheck();
                if (!context.mounted) return;
                final rows = result.items
                    .map((item) => '${item.name}: ${item.status.name}')
                    .join('\n');
                await showDialog<void>(
                  context: context,
                  builder: (_) => AlertDialog(content: Text(rows)),
                );
              },
              child: const Text('Run QA load check'),
            ),
          ],
        ),
        const DebugAdOverlay(),
      ],
    );
  }
}
```

The panel widgets own their subscriptions. The host must remount/rebind them appropriately if it destroys and reinitializes the SDK. Do not set test overrides to expose them in release. Debug revenue totals are operational observations, not finance settlement. The state snapshot is a gate/state summary, not authoritative consent text or user geography. Accept only actual per-item results and separately test native show/dismiss/reward; a debug load check cannot establish those.

#### Consent preview and conservative fallback inspection

**When:** privacy reviewers need a pure mapping preview or support needs to know whether conservative fallback occurred. A simulated outcome does not collect user consent or invoke a CMP. Never call `setConsent(accepted)` based only on a simulation, locale, failed form or timeout.

**Host file:** `lib/consent_preview.dart`.

<!-- snippet: consent_preview.dart -->
```dart
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

ConsentSimulationResult previewRestrictedConsent(AdConfig config) {
  return simulateConsentOutcome(
    const AdConsent(
      hasUserConsent: false,
      isAgeRestrictedUser: true,
      doNotSell: true,
    ),
    config: config,
  );
}

String fallbackSummary() {
  final fallback = AdManager().consentManager?.fallback;
  if (fallback == null) return 'No recorded fallback';
  return '${fallback.reason.name}; policy=${fallback.policyRevision}';
}
```

Inspect `admobTagForChildDirectedTreatment`, `admobTagForUnderAgeOfConsent`, `appLovinHasUserConsent`, `appLovinDoNotSell` and `appLovinCoppaForwarded`. The last is false because MAX does not have a runtime COPPA setter. A restricted AppLovin integration must respect its init-time refusal/approved child policy, not infer supported child serving from the preview. `ConsentFallbackState` describes timeout/platform/offline/stale-revision evidence; it does not authorize requests. For reactive support UI, use `consentManager.fallbackListenable` after initialization; do not log raw TCF/GPP strings. `ConsentSettings.country` is not verified geolocation. `clearAskedAt` / `clearCountry` on `copyWith` explicitly clear nullable metadata; they do not replace a legal erasure workflow or revoke native consent themselves.

Add `const CcpaOptOutToggle()` on the approved Privacy screen, alongside the permanent UMP privacy-options entry. For Vietnamese use `strings: CcpaOptOutStrings.vi`; English uses `.en`; `.resolve(locale)` selects the SDK preset. These are localization conveniences, not substitutes for the partner's legal review. The toggle is disabled before the manager exists and updates the separate Do Not Sell axis. Confirm its stored choice and provider behavior after restart; it is not equivalent to UMP acceptance or ATT authorization.



## Step 5 — Scope of replacement (replace only approved ad call sites)

Migrate only the ad placements and triggers listed in the approved Step 3 touchpoint table. Do not run both old and new implementations for the same placement, because that can double-request or double-show ads. Do not remove another provider, mediation adapter, or unrelated feature unless the partner approved that scope and all callers were traced.

Before deleting any old SDK file/class, **grep-verify** nothing else still uses it:

- List the old SDK files that will be deleted (e.g. `lib/utils/ad_helper.dart`, `lib/services/admob_service.dart`, a custom `AdMobManager`, ...).
- For each file: `grep -r 'ClassName\|methodName' lib/` across the whole project, confirm 0 references, then delete.
- Remove old direct ad-SDK integrations from `pubspec.yaml` only after checking remaining callers and the approved architecture. Keep `google_mobile_ads`/`applovin_max` dependencies required by the SDK's public config types/native implementation; add `gma_mediation_applovin` only when the partner explicitly uses AppLovin as an AdMob mediation network, and verify its version against the pinning guidance.
- Don't add banner/interstitial/rewarded to any screen the old SDK wasn't already on.

## Step 6 — Resolve dependencies, build selected platforms, test selected features

### 6.1 — Resolve and build

From the consuming app root:

```bash
flutter pub get
flutter analyze --fatal-infos
flutter build apk --debug
# If targeting iOS, from the Flutter app root:
(cd ios && pod install)
flutter build ios --simulator --debug --no-codesign
```

On iOS, **running** on a simulator is a separate check from building: `flutter run -d <simulator id>` (list ids with `flutter devices`). A simulator can show test ads but cannot reliably show the App Tracking Transparency dialog or the Google consent form, so verify ATT and UMP on a physical iPhone, or record them in Step 12 as "not run: no physical iOS device". Building needs a Mac with a current Xcode that supports your Flutter version; the SDK itself requires iOS 13 or newer.

For release validation, also run `flutter build apk --release --analyze-size` and compare with an agreed baseline built using the same Flutter version, build flags, flavors, and architectures. If partner does not have a baseline, record “baseline unavailable”; do not claim a `<5MB` pass without measurement.

If `gma_mediation_applovin` or any native provider dependency changed, use this repo's `./tool/check_pinning_wall.sh` for resolution/pod-pin assertion and `--with-builds` for fixture builds. This does not replace builds from the consuming app.

### 6.2 — Run only in-scope tests

From the consuming app root:

```bash
flutter test
```

This runs the partner app's own unit/widget tests; it does not run tests hidden in a published SDK dependency. If working in this SDK source repository, separately run the SDK suite from `packages/ad_sdk/` and its integration suite from `packages/ad_sdk/example/` using a real/simulated device as CI requires. Do not tell a hosted-package consumer to run internal SDK repository tests they do not have.

1. Preserve/add host tests for existing ad triggers and callbacks.
2. For each selected format, run the matching available `example/integration_test/` case when source checkout is available, or write/evidence an equivalent partner test. Use test ad inventory and test devices, not live partner inventory.
3. Exercise offline → reconnect, background/resume, hard-cap, consent result, and repeated user action where applicable.
4. Review resource ownership for changed widgets: cancel timers, remove `SimpleEventBus` callback with `remove(callback)`, and dispose controllers/subscriptions in the owning `State`.
5. If custom AdMob native layout is selected, test native factory registration on Android and iOS; if custom AppLovin native layout is selected, test the Dart builder.
6. For optional SSV, test signature validation/replay protection on partner backend using provider test postbacks; SDK tests cannot validate the partner endpoint.
7. For optional diagnostics/exports, review fields, retention, access control, and consent basis before enabling in production.

Record command, exit status, device/provider, and output artifact for each run. Mark skipped/not configured cases “not in scope” or “not run”; do not infer PASS from compile alone.

## Step 7 — Ad policy and disclosure review

> **In a hurry (new Android + AdMob app)?** Only rows 1, 2 and 5 of the table below can fail from your code: banner not touching buttons, no fullscreen ad while the keyboard is open or scrolling, reward granted only when `earned == true`. Check those three on your own device and write PASS or FAIL beside each. The other rows need the partner's decision; ask for it, and do not guess legal text.

For each enabled placement, record PASS/FAIL and `file:line` evidence. These checks do not replace provider policy review or partner legal/privacy approval.

| # | Check | How to verify |
|---|---|---|
| 1 | Banner/native/MREC stay visually separate from app controls and do not shift content under a pending tap | On the target device, inspect every placement with the ad empty/loading and after it fills. Keep ads away from navigation buttons, scrollbars, floating actions, and frequently tapped controls; reserve the intended ad area before requesting/filling so content is not inserted under a finger mid-gesture. For list/feed ads, use `InFeedAdListView` where appropriate and test slow fill while scrolling. Compare placement against the selected network's current policy and the host's approved layout. The SDK cannot inspect arbitrary host sibling widgets or promise a universal safe margin; the host owns spacing and placement. Never cover a native ad with a transparent hit-test layer, intercept its touch events, or make app controls look like ad controls. Record screenshot and the ad container's top/height before and after fill; investigate visible movement that could redirect a tap. |
| 2 | Fullscreen ads do not interrupt active input or an unintentional transition | Host should wait for a deliberate transition point; do not trigger while a scroll gesture is active or a text-entry keyboard is open. Test app-open/interstitial triggers with the keyboard open, during scrolling, and on route changes. The SDK suppresses some modal/dialog cases, but only the host knows keyboard and scroll intent. |
| 3 | App Open never interrupts first-use navigation unexpectedly | Verify cold-start flow `loadAppOpenAd → showAdBuffer → showAppOpenAd(bypassSafety: true)` and resume behavior; confirm hard cap reaches app when no ad is ready |
| 4 | Interstitial respects configured frequency gates | Confirm `AdSafetyParams.auto` or an explicitly approved preset; record actual caps from selected SDK version/config |
| 5 | Rewarded appears only in approved user flow and reward is granted only when earned | Inspect each enabled placement and callback; do not reward from impression/show/dismiss alone |
| 6 | Partner-approved ad/disclosure text is shown at the agreed location, if required | Get exact copy/location from partner policy/legal owner; localize using host system; do not use this template's sample text as legal advice |

Do not mark a check PASS based on reading code alone when it needs device or owner verification.

## Step 8 — Consent (UMP + iOS ATT)

No built-in GDPR consent dialog. Use Google UMP for applicable consent requirements; handle ATT separately only when the partner's iOS tracking/measurement plan and privacy review call for it:

### 8.1 — Google UMP form (review for every selected provider/market)

By default, `autoRequestUmpConsent: true` runs Google UMP inside `initialize()` before the selected ad provider initializes. With the controller path, call only controller `start()`; it calls `initialize()` itself. With the manual path, request ATT after the first frame only if approved on iOS, then call `initialize()`. Neither path should call `requestUmpConsent()` separately while automatic UMP is enabled. A host-owned manual UMP flow must await `requestUmpConsent()` and set `autoRequestUmpConsent: false`; use the manual splash, not the controller. ATT-before-init on iOS also requires the manual splash.

Before testing UMP, the partner's AdMob owner must configure messages for **each AdMob App ID**, including separate Android/iOS apps:

1. Confirm the manifest/plist App ID belongs to the intended app in the partner's AdMob account; an App ID contains `~`, an ad-unit ID contains `/`.
2. In AdMob **Privacy & messaging**, create/select the required regional message for that app. Supply the partner-approved privacy-policy URL, language choices, consent/privacy options and configured ad partners.
3. Review with the privacy owner and publish the message; an unconfigured app may return `no form(s) configured`. Account/console configuration is not created by installing this SDK.
4. Test the EEA form on a normal device (next paragraph). Reset consent between runs only on a disposable QA install.
5. Run the acceptance cases below and record the actual UMP status plus `canRequestAds`. Publishing a message or seeing a form alone is not evidence that all regional or provider requirements are met.

**Test the EEA form on any device (debug builds only).** The automatic UMP flow reads two `AdConfig` fields and only uses them when the app runs in **debug mode**; in a release build they are ignored for the request but the SDK warns if `umpDebugGeography` is still set (a leftover value would force the EEA flow on real users, so remove it before release).

```dart
AdConfig(
  // ... provider config from Step 4.2 ...
  autoRequestUmpConsent: true,
  umpDebugGeography:
      kDebugMode ? DebugGeography.debugGeographyEea : null,
  umpTestIdentifiers:
      kDebugMode ? const ['<YOUR_HASHED_DEVICE_ID>'] : const [],
)
```

`DebugGeography` is re-exported by `package:applovin_admob_sdk/applovin_admob_sdk.dart`; no extra import is needed. Do **not** call `requestUmpConsent(...)` yourself as well: those two config fields are the whole test setup for the automatic flow.

**How to get your hashed device ID.** Run the debug app once on the device with `umpDebugGeography` set and watch the console (`adb logcat` on Android, the Xcode console on iOS). Google Mobile Ads prints a line that tells you to add the device as a test device and contains the hashed ID, for example `Use RequestConfiguration.Builder().setTestDeviceIds(Arrays.asList("33BE2250B43518CCDA7DE426D04EE231"))`. Copy the 32-character hex string into `umpTestIdentifiers`. Without a listed test ID, the debug geography is ignored on a real device (emulators are usually recognized automatically).

**Reset consent between tests.** Uninstalling the app is the simplest reset. To reset without reinstalling, call `ConsentInformation.instance.reset()` from `package:google_mobile_ads/google_mobile_ads.dart` in a debug-only button, then fully restart the app. Do this only in a QA build: it erases the user's stored UMP choice.

**What "UMP works" looks like.** On a first debug launch with the EEA geography, the form appears before any ad; after you choose, the app continues and ads can load. Restart: the form does not appear again. Temporarily print `AdManager().canRequestAds` (it is `false` until consent is settled, then `true`) and the `ConsentStatus` to confirm. On an emulator with no test ID listed or no AdMob message configured for the App ID, expect no form and a log containing `no form(s) configured`: that is a console-setup issue, not a code bug.

If UMP is enabled, add a permanent privacy-options entry point in your Settings/Privacy screen; do not make it splash-only. `showPrivacyOptions()` is safe to call at any time: when Google does not require a privacy-options form for this user (a non-EEA user or consent never collected) it returns immediately and shows nothing, so you can show the button to everyone. It returns a `PrivacyOptionsResult` (`canRequestAds`, `status`, an optional `error`, `formShown`) and re-applies the user's new choice to the ad provider for you.

**Behaviour to know about (SDK 3.6.1 and newer).** If the user changes consent from declined to granted, a banner that was missing comes back by itself about 1.5 seconds after the form closes. You do not need to do anything.

**If you are stuck on 3.6.0:** the banner can stay missing until the next background-to-foreground. The log shows `consent apply is still in flight on resume — skipping ad work until it has landed`. This costs only revenue; no ad is served without consent. Do **not** add your own retry or re-init in the host app (that could request ads under unconfirmed consent). For QA, background and reopen the app once, or upgrade to 3.6.1. Evidence: Pixel 7 Pro, Android 17, debug, EEA test geography, 5 cold-start rounds each: 3.6.0 loaded the banner 0 of 5 times, 3.6.1 5 of 5.

Complete screen, reachable from anywhere with `Navigator.push`:

<!-- snippet: privacy_screen.dart -->
```dart
import 'package:flutter/material.dart';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Privacy')),
        body: ListView(
          children: [
            ListTile(
              title: const Text('Ad privacy options'),
              subtitle: const Text('Review or change your ad consent'),
              onTap: () async {
                final result = await AdManager().showPrivacyOptions();
                if (!context.mounted) return;
                if (!result.formShown && result.error == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('No privacy options are required for your region.'),
                    ),
                  );
                }
              },
            ),
            // US state privacy law ("Do Not Sell or Share"): a separate switch from UMP.
            const CcpaOptOutToggle(),
          ],
        ),
      );
}
```

Open it from your settings with `Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PrivacyScreen()))`. Replace the English strings with your localization. `CcpaOptOutToggle` is a separate control for the US "Do Not Sell or Share" choice: it is not part of UMP and is not equivalent to ATT. Show it to all users unless your privacy owner limits it by region; it stays disabled until the SDK has initialized. Test reopening and withdrawing consent after initial acceptance: SDK and provider gating, not the fact that the button was tapped, determines whether later requests are allowed.

For each applicable target market/provider, execute and record these cases; do not mark a case passed because code was only reviewed:
- Region where UMP is not required: confirm form is skipped and record returned `status` + `canRequestAds`.
- EEA/UK first launch with network: in a dedicated debug build, configure `umpDebugGeography: DebugGeography.debugGeographyEea` and add the device's hashed UMP test ID to `umpTestIdentifiers`; use test ad units. Confirm form, user choice, persisted CMP state, and `canRequestAds` before ad requests.
- No network / UMP update error: record returned error/status and confirm the SDK consent gate controls ad requests; do not assume ads load just because initialization callback fires.
- Withdraw consent through CMP privacy options, resume app, and confirm subsequent requests obey returned UMP state and selected provider behavior.
- Before release, remove `umpDebugGeography`, test identifiers, and test ad units; run the release-config warnings and confirm release binary uses only partner-approved production values.

Do not ask a junior to change geo on a live production build or test with real inventory. If the partner cannot supply UMP test-device identifiers/market access, record the case as blocked/not run and ask the CMP owner for a test setup.

### 8.2 — Optional iOS ATT

ATT is already built into the SDK — do NOT call
`app_tracking_transparency` directly yourself. Use `AdManager().requestAtt()`.

- The `app_tracking_transparency` dependency is transitive from the SDK — do NOT add it at the app level.
- If the partner's iOS product/privacy review approves showing ATT, add a truthful, localized `NSUserTrackingUsageDescription` to `Info.plist`; without it, iOS suppresses the system prompt:
  ```xml
  <key>NSUserTrackingUsageDescription</key>
  <string>PARTNER_APPROVED_LOCALIZED_TRACKING_PURPOSE</string>
  ```
- In the manual fallback, call `requestAtt()` after the first frame and before `initialize()`. The default `AdReadinessSplashController` does not provide custom ATT-before-init ordering. It is no-op on Android and does not replace Google UMP. Calling before `runApp()` prevents showing the system prompt until UI is available.
  ```dart
  final att = await AdManager().requestAtt();   // no-op on Android
  // att.status: notSupported | notDetermined | restricted | denied | authorized
  // att.idfa: String? (only when authorized); att.allowsTracking: bool
  ```
- `requestAtt()` handles this internally: non-iOS → `notSupported`; already decided before →
  returns the cached status, no re-prompt; error/missing plugin → `denied` (never throws).
- ATT does NOT touch the GDPR consent flag — native AppLovin/AdMob read ATT for IDFA on their own.
- If an iOS user picks "Ask App Not to Track", it falls back to non-personalized ads / SKAdNetwork.

### 8.3 — COPPA (`isAgeRestrictedUser`) — AppLovin/AdMob asymmetry

**Decision rule (no one needs to be asked): if any part of the audience is children under the applicable age of consent, use `AdProvider.admob`.** AdMob can tag requests as child-directed. AppLovin MAX 4.x has no child-directed switch, so for a child-directed audience the SDK refuses to initialize AppLovin at all: every AppLovin ad surface stays empty for that session. That is intentional and stricter than a tag, so do not try to force AppLovin to serve such users another way. Whether the audience counts as child-directed is a legal question the partner answers; if the partner has not told you, treat the app as **not** child-directed only if it is clearly aimed at adults, and otherwise stop and record the question in Step 12 instead of guessing.

How to apply it:

1. **Always child-directed app (whole app is COPPA-scoped):** choose `provider: AdProvider.admob` in `AdConfig` (Step 4.2). Never configure AppLovin. Then tell the SDK before any ad request, from `main()` or the splash `initState`, **before** the controller starts the SDK. The flag is remembered and applied when the SDK initializes:

   ```dart
   await AdManager().setConsent(
     const AdConsent(isAgeRestrictedUser: true),
   );
   ```

   This sets AdMob's child-directed tag for every request. Do this once per install and after any consent reset; do not wait for the user to be asked.
2. **Age gate inside an adult app (user enters a birth date):** call the same `setConsent(AdConsent(isAgeRestrictedUser: true))` as soon as the gate decides the user is under the age. On AdMob the tag applies from the next request. On AppLovin there is no runtime switch: a flag set after initialization hard-stops ad requests for the session and the SDK re-initializes and refuses AppLovin, so the user sees no ads until restart. A mid-session switch back to an adult is not supported on AppLovin.
3. **Verify** with a debug build: with the flag set and `AdProvider.appLovin`, the log contains `initialize ABORTED: isAgeRestrictedUser=true` and no ad loads; with `AdProvider.admob` ads load as child-directed test ads. This is a log check on a device; there is no UI for it.

On a brand-new install of an always-child-directed app that still configures AppLovin, AppLovin attempts to initialize once on the very first launch because there is nothing yet to gate on. The only protection is rule 1: do not configure AppLovin for such an app.

## Step 9 — Optional first-install VIP grace + anti-uninstall-bypass guard

Skip this step and Step 10 if the product does not use VIP. If VIP is enabled, confirm with the partner's product and security owners which grant types are allowed and whether the host's backup policy permits persisting the first-install marker.

### 9.1 — Grace config (SDK built-in, do NOT reimplement)

**Do NOT** store a manual `pref_first_launch_vip_granted` flag, and **do NOT** call `vip.addVip(...)` in `main()` to grant a day. The SDK defaults `firstInstallVipGrace` to `auto` (30s debug / 24h release); for an integration where VIP grace is not approved, explicitly configure `FirstInstallVipGrace.disabled`.

```dart
AdConfig(
  // firstInstallVipGrace: FirstInstallVipGrace.auto,  // default; use only if approved
  // firstInstallVipGrace: FirstInstallVipGrace.disabled, // if grace is not approved
  // firstInstallVipKey: '__FIRST_INSTALL__',
)
```

### 9.2 — Anti-uninstall-bypass guard (only if VIP grace is enabled; verify against this SDK version)

This guard attempts to prevent repeated first-install grants after reinstall; it is not paid-license or account-level enforcement.

| Platform | Mechanism | Limit |
|---|---|---|
| **iOS** | SDK stores a marker in Keychain via `flutter_secure_storage`. | Keychain persistence is device-local and can be affected by device erase/restore behavior. |
| **Android** | Host backup rules may preserve the marker across backup-enabled restores. | Clear-data, backup settings, account/device changes, and timing can bypass it; this is best-effort only. |

### 9.3 — Android backup config (OPTIONAL; security/privacy owner approval required)

Do not enable backup or change existing backup policy solely to support VIP grace. The proposed rule includes the entire `FlutterSharedPreferences.xml` file, not only the SDK marker; that file may also contain host-app or plugin preferences. Review its contents and the partner's backup/data-retention policy with the app security/privacy owner before adding the rules. If approval is absent or the host disallows backup, preserve the existing policy and disable first-install VIP grace rather than weakening host controls.

Only after approval, merge the SDK's required preference file into the host's existing backup rules; never overwrite existing Firebase, database, or other app-specific rules. Do not claim that this makes VIP grants single-use or tamper-proof.

**(a) `android/app/src/main/AndroidManifest.xml`** — only after owner approval, configure the existing backup policy to reference the appropriate rule files:

```xml
<application
    android:allowBackup="true"
    android:fullBackupContent="@xml/full_backup_content"
    android:dataExtractionRules="@xml/data_extraction_rules"
    ...>
```

Do not change an existing `android:allowBackup="false"` without explicit approval. An approved integration may instead retain its current backup policy and disable the VIP grace feature.

**(b) `android/app/src/main/res/xml/data_extraction_rules.xml`** — Android 12+ (target SDK ≥ 31). Create or merge only after approval:

```xml
<?xml version="1.0" encoding="utf-8"?>
<data-extraction-rules>
    <cloud-backup>
        <include domain="sharedpref" path="FlutterSharedPreferences.xml" />
    </cloud-backup>
    <device-transfer>
        <include domain="sharedpref" path="FlutterSharedPreferences.xml" />
    </device-transfer>
</data-extraction-rules>
```

**(c) `android/app/src/main/res/xml/full_backup_content.xml`** — Android 6–11 (API 23–30). Create or merge only after approval:

```xml
<?xml version="1.0" encoding="utf-8"?>
<full-backup-content>
    <include domain="sharedpref" path="FlutterSharedPreferences.xml" />
</full-backup-content>
```

Both files may be needed across supported Android versions. The explicit include backs up the entire `FlutterSharedPreferences.xml` file; it cannot select only the SDK marker. Never overwrite existing Firebase/database/app backup rules—merge deliberately and re-review the resulting scope. Android lint rejects an `<exclude>` outside an included path, so do not add an unrelated `FlutterSecureStorage.xml` exclude.

### 9.4 — iOS — no additional config needed

The SDK handles the Keychain itself. The default `flutter_secure_storage` settings (`kSecAttrAccessibleAfterFirstUnlock`, no `synchronizable`, no `kSecAttrAccessGroup`) are correct for anti-bypass. Do NOT override them.

### 9.5 — Optional anti-bypass smoke test (only if VIP grace is approved)

Skip this test when VIP grace is disabled. Never enable a free entitlement solely to run the test on a partner build; use a dedicated non-production test application/configuration, then retain the approved production setting.

**Android (Play Store internal track)**:
```bash
# 1. Build a signed AAB
flutter build appbundle --release

# 2. Upload to Play Console Internal Testing, install via Play Store
# 3. Wait > 24h OR trigger a backup immediately:
adb shell bmgr backupnow <package_name>

# 4. Uninstall + reinstall via Play Store
# 5. Verify the log: NO "🎁 first-install VIP grace granted" line → the block worked
#                Or the app has no __FIRST_INSTALL__ VIP entry → it was skipped
```

**iOS (TestFlight or an Xcode-signed Ad Hoc build)**:
```
1. Temporarily set firstInstallVipGrace = FirstInstallVipGrace.debugShort (30s) for a fast cycle
2. Build a release IPA, install via Xcode/TestFlight
3. Verify the log "🎁 first-install VIP grace granted (30s, mode=release)"
4. Wait 30s → log "⏰ VIP entry expired"
5. Uninstall the app
6. Reinstall via Xcode/TestFlight
7. Verify the log "🛡️ Keychain flag present — prior install detected on this device"
8. Verify the log "🛡️ first-install VIP grace SKIPPED"
9. Restore the partner-approved setting; use `FirstInstallVipGrace.disabled` unless the entitlement was explicitly approved
```

## Step 10 — Optional VIP management screen UI/UX

Skip this step unless product scope explicitly includes VIP and the partner has approved its entitlement, promotion, and privacy behavior. If approved, reuse an existing screen or the SDK's `VipRedeemScreen`; do not create an entitlement UI by default.

### 10.1 — Optional file structure (adapt to the host app)

Use the host app's existing feature/config layout. If it has no established location, a small optional VIP feature can use:

```
lib/<DART_PACKAGE_NAME>/
├── config/ad_config.dart       # selected provider config; Section 0
└── features/vip/
    ├── vip_screen.dart         # only if using a custom screen
    └── vip_config.dart         # public signing key only
```

Do not create a new global state base class or logger just for VIP. Keep the private signing key out of this tree, the app binary, and source control.

### 10.2 — Add the public VIP key (only if VIP promotions are approved)

Generate the Ed25519 key pair once with the SDK tools (exact commands in **Step 10.6a, "VIP operator quick start"**). The private key stays with the authorized minting operator in an approved secret manager; the app receives only the public key. Example config file:

`lib/vip_config.dart`:

```dart
abstract final class VipConfig {
  /// The PUBLIC key printed by `vip_keygen.dart` (a 44-character base64url string
  /// ending in `=`). Safe to commit and ship.
  static const publicKeyBase64 = '<PARTNER_VIP_PUBLIC_KEY_BASE64>';
}
```

An empty or wrong public key does not crash the app: every redemption simply fails verification and returns `VipRedeemStatus.invalid`. Never leave the placeholder in a shipped build. Do not put promo codes, key-to-duration maps or private signing material in app config. Ad-provider credentials are configured separately (Section 0 and Step 4.2).

### 10.2b — Or skip 10.3 entirely: wrap the SDK's `VipRedeemScreen`

If the project has no existing VIP screen to reuse (Step 2's audit found none), **prefer this over building
the 13-component screen in Step 10.3 from scratch** — the SDK ships a complete, ready-to-use screen (status
header, redeem field, watch-ad-to-extend, revoke, Do Not Sell toggle) that its own example app uses verbatim:

```dart
Navigator.push(
  context,
  MaterialPageRoute<void>(
    builder: (_) => VipRedeemScreen(
      publicKeyBase64: VipConfig.publicKeyBase64,
      onPrivacyPolicyTap: () => launchPartnerPrivacyPolicy(),
      onPrivacyOptionsTap: () => AdManager().showPrivacyOptions(),
    ),
  ),
);
```

**Where to put this code (a junior needs this).** **Do Step 10.2 first**: `lib/vip_config.dart` must exist or this code does not compile. Put the `Navigator.push` call in the callback of a widget on a screen that already exists: `onTap` for a `ListTile`, `onPressed` for a `TextButton`/`ElevatedButton`. In the guide's own app, add a `ListTile(title: const Text('VIP code'), onTap: () { ...push... })` to the `ListView` in `lib/privacy_screen.dart` (Step 8.1). The file that contains it needs two imports: `import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';` and `import 'vip_config.dart';` (adjust the path to where you saved `lib/vip_config.dart` in Step 10.2). `launchPartnerPrivacyPolicy` is a name for the host's own function; if the project has none, pass `onPrivacyPolicyTap: () {}` while you test and replace it before release. Verified on a device (Android, debug): online redeem returns `success`, the same token again returns `alreadyUsed`, a token with a flipped signature character returns `invalid` (signature invalid), a token minted for another bundle id returns `invalid` (key bound to a different app), and a new token while offline is rejected with `isOffline == true`. An already-active VIP survives killing and reopening the app, also offline.

Replace `launchPartnerPrivacyPolicy()` with the host app's approved privacy-policy launcher. `publicKeyBase64` is required; other callbacks/localized `VipRedeemStrings` are optional. This screen handles signed promotion redemption; activation requires network. Do not wire a private signing key or plaintext promo validator. If the built-in screen meets the partner UI requirements, stop here and skip the custom UI, animation, and translation design sections below. See `packages/ad_sdk/README.md` → “Pre-built redeem screen (`VipRedeemScreen`)” for the complete current constructor.

### 10.3 — Optional custom VIP UI (only if approved and `VipRedeemScreen` does not meet host requirements)

Use this as a sequence of UI requirements only when the partner approved VIP and needs a custom screen. These details are not reasons to add a state-management, animation, or localization package: use existing host-app patterns and omit visual extras the product does not need.

| # | Optional idea | Detail |
|---|---|---|
| 1 | Status header / Hero card | Observe `vip.activeListenable` through the host app's reactive pattern after checking `vip != null`. Active state can show approved localized status/expiry; inactive state shows the host's normal free-user state. The `.tr` names in older examples are GetX-specific, not SDK API. |
| 2 | Activation date row | `'Activated: ${DateFormat('dd/MM/yyyy HH:mm').format(entry.grantedAt)}'` (hidden if free). Uses `package:intl`. Confirm the field name against the pinned release's `VipEntry`; do not assume legacy names such as `startedAt`. |
| 3 | Expiry date row | `'Expires: ${DateFormat('dd/MM/yyyy HH:mm').format(entry.expiresAt)}'` (hidden if free) |
| 4 | Progress bar (elapsed) | `LinearProgressIndicator` with `value = (now − entry.grantedAt) / (entry.expiresAt − entry.grantedAt)`, clamped to `[0.0, 1.0]`. **3 points on the horizontal timeline**: `start = entry.grantedAt` (left edge, 0%), `end = entry.expiresAt` (right edge, 100%), `current = now` (fill position). The bar starts **empty right after activation and fills up toward expiry** (elapsed semantics — matches the user's mental model of "progression toward expiry"). Absolutely do NOT invert the formula to `remaining/total` (full → empty) — that's confusing UX. Only show this when VIP is active. **No need for `TweenAnimationBuilder`** — a per-second tick from `_now` is smooth enough (Δ ≪ 0.001%/s for a 24h+ VIP window); `TweenAnimationBuilder` would only add overhead and slow rebuilds. Edge case `total ≤ 0` (clock skew / already expired) → default to `value = 1.0` (full = expired) |
| 5 | Countdown text | Format like `12d 03h 24m 15s` — updated via `Timer.periodic(Duration(seconds: 1), ...)` in `initState`, `cancel()`'d in `dispose`. State goes through `ValueNotifier<Duration>`, never `setState` |
| 6 | Signed VIP code field (if promotions are in scope) | `TextEditingController` with `autocorrect: false`, `enableSuggestions: false` and the default capitalization (**never** `TextCapitalization.characters`: a signed token is case-sensitive, so upper-casing it makes it unredeemable); trim whitespace only; redeem with `redeemSignedKey` or the SDK screen. Handle statuses explicitly; activation requires network. Never check user-entered codes against an app-bundled plaintext/Base64 key map. |
| 7 | "Watch ad → N days VIP" button | Tap → `showRewardedAd(onEarnedReward: (earned) {...})`. **Only grant VIP when `earned == true`** (the user watched the rewarded ad to completion). **Do NOT** fall back to an interstitial to grant the reward — granting VIP for watching an interstitial violates Google/AppLovin's rewarded policy (it blurs the rewarded/interstitial line). If rewarded isn't ready → show "try again later". **Stacking**: grant via the fixed key `REWARDED_VIP` + `addVip(..., stack: true)` (collapses into one entry). To let an active VIP extend their window this way, keep the button visible even while `active` and use `showRewardedAd(bypassVipGuard: true, ...)` (see 4.7). Pulse animation #1 |
| 8 | Purchase tiers | Show purchase/restore controls only if partner billing scope is approved and a real purchase integration exists. Do not ship disabled “coming soon” purchase promises copied from the demo. |
| 9 | Additional tiers | Add only the products actually configured in partner billing; omit speculative tiers. |
| 12 | List of active entries | Observe the host-supported VIP entries stream/listenable; each entry may show grant source and expiry. Mask or omit key material in UI and logs. |
| 13 | Restore purchase | If paid VIP is in scope, use the partner's verified billing restore flow; the SDK does not implement app-store purchase validation. Omit otherwise. |
| — | Revoke VIP | If product policy permits user revocation, confirm in host UI then call `await vip.revokeAll()`; omit otherwise. |
| — | VIP status indicator | Optional; observe `activeListenable` after initialization using the host's existing reactive pattern. |
| — | Privacy Policy footer | `InkWell` → `url_launcher.launchUrl(Uri.parse(AdKey.privacyPolicyUrl), mode: LaunchMode.externalApplication)` |

For any custom screen, required behaviors are: validate via the signed redemption API, show success/failure status, reflect active/expired state, and avoid logging the entered key. Keep the host's existing state-management and design system; confetti, haptics, gradients, countdown animations, and Material 3 are optional presentation choices.

#### Optional progress-bar implementation for row #4 (elapsed semantics)

```dart
/// 3 points on the horizontal timeline [grantedAt ─── expiresAt]:
///   start   = entry.grantedAt   (left edge, value 0.0)
///   end     = entry.expiresAt   (right edge, value 1.0)
///   current = now               (fill position)
///
/// progress = (current − start) / (end − start)
/// The bar is EMPTY right after activation, FILLS UP toward expiry.
Widget _buildProgressBar(VipEntry entry) {
  return ValueListenableBuilder<DateTime>(
    valueListenable: _now,  // 1s ticker, drives the elapsed update
    builder: (context, now, _) {
      final total = entry.expiresAt.difference(entry.grantedAt);
      final elapsed = now.difference(entry.grantedAt);
      final progress = total.inMilliseconds <= 0
          ? 1.0  // expired / clock skew → render full
          : (elapsed.inMilliseconds / total.inMilliseconds)
              .clamp(0.0, 1.0)
              .toDouble();
      return ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: LinearProgressIndicator(
          value: progress,
          minHeight: 10,
          backgroundColor: Colors.white.withValues(alpha: 0.18),
          valueColor: AlwaysStoppedAnimation<Color>(
            Colors.white.withValues(alpha: 0.95),
          ),
        ),
      );
    },
  );
}
```

Visualization for a 30-day VIP:
```
T+0      [░░░░░░░░░░░░░░░░░░░░░░░░░░░]   0% — just redeemed
T+1d     [█░░░░░░░░░░░░░░░░░░░░░░░░░░]   3.3%
T+15d    [██████████████░░░░░░░░░░░░░]   50%
T+29d    [██████████████████████████░]   96.7%
T+30d    [███████████████████████████]  100% — expired
```

### 10.4 — Optional animation examples (skip unless approved by product/design)

| # | Animation | Implementation | Trigger |
|---|---|---|---|
| 1 | Pulse on the "Watch ad" button | `AnimationController? _pulseController;` initialized in `initState` with `duration: 1600ms` `..repeat(reverse: true)`. Local copy pattern: `final c = _pulseController; if (c != null) ... ScaleTransition(scale: Tween(1.0, 1.05).animate(c), ...)` | `initState` starts it, `dispose` cancels it |
| 2 | Slide-in from below when opening the screen | `AnimationController? _entryController;` init `duration: 1100ms` `..forward()`. 3 sections share one controller, each with its own `Interval(0.0, 0.4)`, `Interval(0.3, 0.7)`, `Interval(0.6, 1.0)` — fade-slide in sequentially | `initState` |
| 3 | Crown icon shimmer | `AnimationController? _shimmerController;` init `duration: 3000ms` `..repeat()`. Either `RotationTransition` ±5° OR a `ShaderMask` with a shimmer `LinearGradient` | `initState` repeats it, `dispose` cancels it |
| 4 | Number count-up for the countdown | `TweenAnimationBuilder<double>` runs only when the value changes meaningfully (once per minute) — NOT every second, to avoid a build hot loop | Whenever `Timer.periodic` crosses a new minute |
| 5 | Confetti on successful activation | `package:confetti`: `ConfettiController? _confettiController;` init `duration: 1000ms`. In `dispose`: `_confettiController?.dispose()`. On successful `redeemSignedKey` or `onEarnedReward == true` → `_confettiController?.play()` + `HapticFeedback.heavyImpact()` (Flutter built-in, no need for the `vibration` package) | After success |

Bonus (nice-to-have, not mandatory): default ripple effect for both buttons (comes with Material 3), an animated gradient background for the status header.

### 10.5 — Lifecycle checklist for custom VIP UI

The following fragments are ownership patterns, not complete classes: keep only fields actually declared by the host screen. `late` and `setState` are valid when used safely; the “DO NOT” labels below refer to unchecked examples, not SDK bans. For entered promotion codes use `redeemSignedKey` in Step 10.6, not a `redeemVip(...)` placeholder. Prefer the built-in screen when custom UI is not required.

Use patterns that fit the host app; the important requirement is that resources cannot outlive their owner and nullable SDK state is handled. Examples below are Dart/Flutter options, not style mandates.

- A nullable `AnimationController` is one option when initialization is conditional:
  ```dart
  // Uninitialized/undisposed controller is unsafe; late itself is not banned.
  late AnimationController _pulseController;
  // ✅ CORRECT
  AnimationController? _pulseController;
  // When using it:
  final c = _pulseController;
  if (c == null) return const SizedBox.shrink();
  return ScaleTransition(scale: Tween(1.0, 1.05).animate(c), ...);
  ```
- For reactive countdown/status, use the host app's existing state mechanism. A `ValueNotifier<T>` + `ValueListenableBuilder` is one Flutter-native option:
  ```dart
  // ❌ DO NOT
  setState(() => _remaining = newDuration);
  // ✅ CORRECT
  final ValueNotifier<Duration> _remaining = ValueNotifier(Duration.zero);
  // ...
  _remaining.value = newDuration;     // does not trigger setState
  // Build:
  ValueListenableBuilder<Duration>(
    valueListenable: _remaining,
    builder: (_, d, __) => Text(_format(d)),
  )
  ```
- `AdManager().vip` is nullable before SDK initialization and after teardown, so never write `AdManager().vip!`. Use a local copy or Dart 3 pattern matching, and re-read it for each action instead of caching a manager across destroy/re-initialize:
  ```dart
  if (AdManager().vip case final vip?) {
    // use vip here, e.g. the signed redemption in Step 10.6
  }
  // or
  final vip = AdManager().vip;
  if (vip == null) return;
  ```
  Entered promotion codes use `redeemSignedKey` (Step 10.6), never the legacy `redeemVip(...)` plaintext validator.
- **NO `Future.delayed` for a countdown** — use `Timer.periodic` instead, with `cancel()` in `dispose`.
- **Don't hold a rewarded callback as an anonymous closure capturing `this`** when the screen could be `dispose()`d before the callback fires — check `if (!mounted) return;` at the top of the callback.
- **Don't forget to call `.dispose()`** on every `AnimationController`, `TextEditingController`, `FocusNode`, `Timer`, `StreamSubscription`, `ValueNotifier`, `ConfettiController` in `dispose()`. Pattern:
  ```dart
  @override
  void dispose() {
    _keyController.dispose();
    _keyFocus.dispose();
    _shimmerController?.dispose();
    _entryController?.dispose();
    _pulseController?.dispose();
    _confettiController?.dispose();
    _tickTimer?.cancel();
    _activeSubscription?.cancel();
    _isProcessing.dispose();
    _entriesNotifier.dispose();
    _remaining.dispose();
    super.dispose();
  }
  ```

### 10.6 — Signed VIP redemption + special entries (only if VIP is approved)

Use signed AVP2 promotions, never an app-bundled plaintext/Base64 key-to-duration map. The operator generates a key pair once, ships only the public key in the app, and mints one signed token per promotion. A user pastes that token into the redeem screen. Everything below this paragraph is app code; the operator commands are in **Step 10.6a**.

On the screen, first check that SDK initialization has completed (`AdManager().vip` is nullable), then handle all result statuses:

```dart
final vip = AdManager().vip;
if (vip == null) {
  showMessage('VIP is not ready yet');
  return;
}

final result = await vip.redeemSignedKey(
  userInput.trim(),
  publicKeyBase64: VipConfig.publicKeyBase64,
  stack: true,
);
if (!mounted) return;
if (result.isOffline) {
  // Not a rejected code: there was no network. Tell the user to reconnect and retry.
  showMessage('No internet connection. Try again when you are online.');
  return;
}
switch (result.status) {
  case VipRedeemStatus.success:
    showMessage('VIP activated');
    break;
  case VipRedeemStatus.alreadyUsed:
    showMessage('This code was already redeemed on this device');
    break;
  case VipRedeemStatus.invalid:
    // Covers a bad signature, an expired token and a token for another app.
    showMessage('Code invalid, expired, or for another app');
    break;
}
```

`result.isOffline` must be checked **before** the `switch`: an offline attempt reports `status == invalid` (so older hosts keep working) and would otherwise show the user a misleading "invalid" message for a perfectly good code. `result.entry` holds the granted `VipEntry` on success and `result.error` a short diagnostic string otherwise (log it only in debug; never show or log the entered token).

Replace `showMessage` with the host app's existing UI. Signature verification is local, but redemption requires network; activated VIP remains usable offline. These are transferable promotions, not globally single-use paid licenses: Android clear-data/reinstall can replay a leaked still-valid key. For paid entitlements with material loss, use server-verified purchases; never use this client-side grant as an authorization boundary for sensitive data/features.

**Special entries** (auto-managed by the SDK, do NOT delete manually; omit this UI section if VIP is not in product scope):

| Key prefix | Source | UI label (i18n key) |
|---|---|---|
| `__FIRST_INSTALL__` | `firstInstallVipGrace.auto` (Step 9) | `'vip_entry_first_install'.tr` ('New install gift') |
| `LEGACY_<gaid>` | Auto-migrated from `vipDeviceGaids` (if set) | `'vip_entry_legacy'.tr` ('QA device') |
| `REWARDED_VIP` (prefix `REWARDED_`) | Watch-ad reward (fixed key + `stack: true`) | `'vip_reward_entry'.tr` ('Ad-watch reward') |
| Anything else | User redeem or programmatic `addVip` | `entry.key` raw (mask the first 3 characters) |

### 10.7 — Localize VIP strings (only if VIP UI is in scope)

Add these meanings to the host app's existing localization files/system; file names and key syntax below are examples from one integration, not SDK requirements:

```dart
// VIP
'vip_active', 'vip_free_user', 'vip_until',
'vip_activated_at', 'vip_expires_at', 'vip_remaining',
'vip_redeem_label', 'vip_redeem_hint', 'vip_redeem_button',
'vip_watch_ad_3d', 'vip_buy_30d_locked', 'vip_buy_90d_locked',
'vip_buy_1y_locked', 'vip_buy_lifetime_locked', 'vip_restore_locked',
'vip_revoke_all_button', 'vip_revoke_all_confirm_title',
'vip_revoke_all_confirm_message', 'vip_entry_first_install',
'vip_entry_legacy', 'vip_verifying_title', 'vip_success_title',
'vip_failed_title',

// Consent
'consent_title', 'consent_message', 'consent_allow', 'consent_reject',
'consent_privacy_label',

// Splash
'splash_ads_notice',

// Common
'privacy_policy', 'cancel', 'confirm', 'ok',
```

Other languages (zh / ja / ko / es / fr, etc.) can be added in a later pass — don't add them for this integration.

### 10.8 — Optional entry point from the host UI

Add an entry point only if the partner approved a VIP user-facing feature. Reuse the host app's existing navigation and rebuild/listenable pattern; do not add GetX or allocate a new `ValueNotifier` during `build()`. For example, route a button to the screen through the app's existing Navigator/router and observe `AdManager().vip?.activeListenable` after SDK initialization.

### 10.9 — Optional modules beyond ad surfaces (navigation and SSV recipe)

Do not implement these during core ads setup unless Step 0/3 selected them. If selected, use the recipe named below, record owner/configuration, and add the matching check to the integration record.

| Optional module | Complete in-file recipe | Required approval/owner |
|---|---|---|
| Revenue / `AdEvent` analytics | Step 10.11 | Analytics owner; approved fields and retention |
| Remote safety policy | Step 4.16 | Monetization/policy owner and remote-config owner |
| Monetization arbitrator, monitors, waterfall, failover, self-healing, journey prefetch, digital twin, revenue ledger/anomaly, diagnostics | Step 4.16 | Named monetization owner; each module chosen separately |
| Cohort/provider selection | Step 4.16 (`CohortOptimizer` limit explained) | Monetization owner; both providers configured |
| Flight recorder, event/compliance exports, provenance, dispute kit, verifiers | Step 10.12 | Privacy, security and support owners |
| SDK data erasure | Step 10.10 | Privacy/account-deletion owner |
| Signed feature flags | Step 4.16 | SDK/operations issuer owns private signing key |

Rewarded SSV is backend-owned. The client only passes identifiers; it does not verify the provider postback. Configure the provider dashboard callback, then pass a stable partner reward-account ID (never raw PII) and an opaque server-issued nonce when showing the ad:

```dart
void showServerVerifiedReward({
  required String rewardAccountId,
  required String serverIssuedRewardNonce,
}) {
  AdManager().showRewardedAd(
    ssvUserId: rewardAccountId,
    ssvCustomData: serverIssuedRewardNonce,
    onEarnedReward: (earned) {
      if (!earned) return;
      // Update UI optimistically only. The partner backend postback is authoritative.
    },
  );
}
```

`AdScreenState.showRewardedAd` takes the same `ssvUserId`/`ssvCustomData` arguments and the same `onEarnedReward` callback, with the screen lifecycle guard. This guide does not prescribe the partner's postback URL, signature-validation code, identity schema, database or reward policy. Those are backend-owned: follow the selected network's current SSV documentation, validate signature, timestamp, replay and user/custom data, then grant server-side. Never grant a valuable entitlement solely from the client callback when SSV is the approved source of truth.

If no row was selected, record “not in scope”; do not add packages, backend endpoints, storage, network calls or UI for these modules.

### 10.10 — SDK-scoped data erasure (optional, destructive)

Use only from the partner-approved privacy/deletion workflow. Never use `SharedPreferences.clear()` to erase SDK data: it also deletes unrelated host data. Decide whether entitlement records must survive. Show an explicit user confirmation before any destructive call; the code below assumes that decision has already been made.

```dart
Future<void> eraseSdkOperationalData() => AdManager().clearSdkData(
      scope: SdkDataErasureScope.everythingExceptEntitlements,
    );

Future<void> eraseSdkDataIncludingVip() => AdManager().clearSdkData(
      scope: SdkDataErasureScope.allIncludingEntitlements,
      confirmedEntitlementErasure: true,
    );
```

The second call permanently removes SDK VIP entitlement data; do not call it for an ordinary sign-out or ad reset. Both scopes retain the consent-provenance journal unless `purgeConsentProvenanceJournal: true` is explicitly selected by the privacy owner. Compliance-signing keys and anti-abuse exceptions are not a promise of total device erasure. The SDK call does not delete data held by Google/AppLovin, a backend, analytics, or OS backups. Test both scopes on disposable QA data: ordinary erasure preserves VIP, entitlement erasure updates live VIP UI, host preferences remain intact, and retained journal/anti-abuse behavior matches the approved policy.

### 10.11 — Events and safe diagnostics (optional)

For event analytics, own one `StreamSubscription<AdEvent>` per consumer. Subscribe to `AdManager().events` after initialization, map only approved fields, cancel when the consumer is disposed, and resubscribe after SDK destroy/re-initialize if that lifecycle is used. Example inside a State (add `import 'dart:async';`):

```dart
StreamSubscription<AdEvent>? _adEvents;

void attachAdEvents(void Function(AdEvent) onApprovedEvent) {
  _adEvents?.cancel();
  _adEvents = AdManager().events.listen(onApprovedEvent);
}

// In this State's dispose(): _adEvents?.cancel(); then super.dispose().
```

`AdRevenueEvent` is a native provider signal, not proof of settled revenue. Do not log every event with `toString()` or export raw consent/key identifiers. For support, `await AdManager().exportSafeDiagnostics()` returns a bounded diagnostic string; preview/redact it, obtain approval, then store/share through the host's approved channel. Signed compliance/incident exports prove content integrity against their bundled key, not publisher/device identity without a separately trusted key. Verify load/show/reward/revenue mapping with test ads and duplicate/subscription teardown behavior before enabling analytics.

### 10.12 — Evidence and compliance recipes (optional, local by default)


Select these features only after privacy/security owners approve collected fields, purpose, retention, export recipients, access control and storage. They support troubleshooting; they do not grant legal consent or certify ad-network policy compliance. The recorder may include active TCF consent strings, placement names and geometry. Never dump them into ordinary logs or analytics by default.

#### E1 — SDK event history and redacted compliance report

`AdManager.initialize()` internally owns `AdEventLog` and persistence. The default log retains a rolling window (current implementation: up to 5,000 entries), not an indefinite archive. Do not instantiate `AdEventLog` or call its internal-prefs attach/load APIs from the partner app. `exportComplianceReport(from:, to:)` is the public reader; before init it can legitimately contain no events. A zero-entry report is not proof no ad traffic occurred.

Host file: `lib/ads/support_evidence.dart`. The class below provides the operations used by E1–E5. `approvedPrivateDirectory` must be supplied by the host's approved private-file/storage layer; the SDK does not choose a destination or upload anything. `approveShare` must present a private preview or pass through the partner's review procedure; return false to cancel. It receives sensitive content intentionally and must not log it.

<!-- snippet: support_evidence.dart -->
```dart
import 'dart:convert';
import 'dart:io';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

typedef EvidenceApproval = Future<bool> Function(String label, String json);

class SupportEvidence {
  SupportEvidence({
    required this.approvedPrivateDirectory,
    required this.approveShare,
    this.maxArtifactBytes = 1024 * 1024,
  });

  final Directory approvedPrivateDirectory;
  final EvidenceApproval approveShare;
  final int maxArtifactBytes;

  Future<File?> _saveApproved(String label, String fileName, String json) async {
    final bytes = utf8.encode(json);
    if (bytes.length > maxArtifactBytes) {
      throw StateError('Evidence exceeds the approved artifact size limit');
    }
    if (!await approveShare(label, json)) return null;
    await approvedPrivateDirectory.create(recursive: true);
    final session = await approvedPrivateDirectory.createTemp('ad-evidence-');
    final file = File('${session.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  Future<File?> saveRedactedCompliance({DateTime? from, DateTime? to}) async {
    final report = AdManager()
        .exportComplianceReport(from: from, to: to)
        .redacted(ReportRedactionProfile.supportSafe);
    final signed = await signComplianceReport(report);
    return _saveApproved(
      'Redacted compliance report',
      'compliance.json',
      signed.toJsonString(pretty: true),
    );
  }

  Future<File?> saveBypassTrail() async {
    final signed = await AdManager().exportSignedBypassAuditTrail();
    return _saveApproved(
      'Bypass audit trail',
      'bypass.json',
      signed.toJsonString(pretty: true),
    );
  }

  Future<File?> saveIncidents() async {
    final signed = await AdManager().exportSignedIncidentBundle();
    return _saveApproved(
      'Incident timeline',
      'incidents.json',
      signed.toJsonString(pretty: true),
    );
  }

  Future<File?> saveFlightRecorder() async {
    final signed = await AdManager().exportSignedFlightRecorderBundle();
    if (signed == null) return null;
    return _saveApproved(
      'Sensitive flight recorder',
      'flight.adproof',
      signed.toJsonString(pretty: true),
    );
  }

  Future<File?> saveConsentProvenance() async {
    final signed = await AdManager().exportSignedConsentProvenanceJournal();
    if (signed == null) return null;
    return _saveApproved(
      'Consent provenance journal',
      'consent-provenance.json',
      signed.toJsonString(pretty: true),
    );
  }

  Future<File?> saveUnredactedDisputeKit({DateTime? from, DateTime? to}) async {
    final kit = await AdManager().exportDisputeKit(from: from, to: to);
    return _saveApproved(
      'Unredacted dispute kit: explicit privacy approval required',
      'dispute-kit.json',
      kit.toJsonString(pretty: true),
    );
  }

  Future<File?> saveSafeDiagnostics() async {
    final json = await AdManager().exportSafeDiagnostics(maxBytes: 65536);
    return _saveApproved('Safe diagnostics', 'diagnostics.json', json);
  }
}
```

Call the selected method from an authorized support action, await it, then check for `null` (cancelled or optional recorder absent). Catch I/O/signing failures at that UI boundary and show a localized failure without discarding existing evidence. A successful save is not permission to email/upload the file: transfer only through the host's approved share flow after review. Delete exported files per retention policy; SDK erasure does not know which host files were saved.

`ReportRedactionProfile.supportSafe` removes per-event `consentCountry` and `placement` only. It does **not** redact top-level consent/safety/VIP fields, timestamps, arbitrary identifiers or every future event field. Preview the result and choose a stricter `ReportRedactionProfile(name, fields)` when policy requires it. Signing must happen **after** redaction; altering signed JSON afterwards invalidates the signature. `exportSignedComplianceReport()` is useful for a private full report but does not apply redaction automatically.

**Acceptance:** make one test request, export a narrow time range, confirm the expected format/provider events, confirm the two support-safe event keys are absent, verify the signed envelope, then change one signed payload byte and confirm verification fails. Exercise cancellation, size-limit failure, disk write error and offline export. No network is required to build/sign a report, but native secure storage must be available; signing/storage failures must not be reported as valid evidence.

#### E2 — Incident timeline and bypass history

`AdManager().incidentRecorder` is a bounded process-level recorder (current default 200 entries). The host can add a short stable observation label at an existing diagnostic checkpoint without overriding SDK state. Labels must not contain user identity, codes or consent strings. The following function is a complete helper for `lib/ads/incident_checkpoint.dart`:

<!-- snippet: incident_checkpoint.dart -->
```dart
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

void recordSupportCheckpoint() {
  final manager = AdManager();
  manager.incidentRecorder.record(
    'support_checkpoint',
    manager.stateSnapshot.value,
  );
}
```

Do not claim that the SDK automatically records every app or SDK lifecycle transition. The recorder has explicit `record` call sites; only recorded observations exist in the exported timeline. Deltas are relative observations; clock rollback is flagged, not silently corrected into a guaranteed monotonic timeline. `saveIncidents()` above exports a signed snapshot and config fingerprint. A config fingerprint is for diagnosis, not app identity attestation.

`AdManager().bypassAuditTrail` records supported safety/VIP bypass call sites. It is evidence, not permission or enforcement: keep `bypassSafety: true` at the approved splash App Open path only, and `bypassVipGuard: true` only for a VIP voluntarily watching a real rewarded ad. The trail can remain across destroy/re-initialize and is persisted after SDK attachment. Do not call `.record()` to fabricate an impression or use `.clear()` merely to hide undesirable history. `saveBypassTrail()` exports its signed snapshot.

**Acceptance:** exercise an approved splash flow and, if enabled, a rewarded VIP-extension action. Confirm the trail kinds/call-site labels, export/verify, and confirm host checkpoint order in the incident bundle. Missing timestamps, no records, or a watchdog outcome must be recorded honestly; none proves a real ad was dismissed by a person.

#### E3 — Flight recorder / `.adproof`

`AdFlightRecorder` is opt-in, bounded and local. Enable one instance before the selected startup owner initializes the SDK, so initial transitions can be recorded. Do not call its `attach(AdPreferences)` yourself. If enabled after init, the manager also attaches it to available SDK persistence. The record includes visibility fraction, geometry, provider/placement, click flag, elapsed visible-to-interaction duration and potentially raw TCF consent. It does not measure native finger-down duration or every rendered frame.

Host file: `lib/ads/flight_recorder_control.dart`.

<!-- snippet: flight_recorder_control.dart -->
```dart
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

void enableApprovedFlightRecorder() {
  AdManager().enableFlightRecorder(AdFlightRecorder(capacity: 2000));
}

Future<bool?> checkRetainedFlightChain() async {
  final recorder = AdManager().flightRecorder;
  if (recorder == null) return null;
  await recorder.flush();
  return verifyFlightRecorderChain(recorder.entries);
}
```

The manager owns an enabled instance; replacing it with another `enableFlightRecorder` call retires the old one. Do not retain or write to an old instance after replacement. **Current API ceiling:** the only disable method, `disableFlightRecorder()`, is annotated `@visibleForTesting`, so this recipe does not call it from production host code or suppress the analyzer warning. Source inspection of `destroy()` shows it does **not** clear the enabled recorder, so `destroy()` plus re-initialize is not a supported way to turn recording off. Decide before shipping: enable the recorder only for builds/users with approved evidence collection; a shipped enabled recorder stays enabled for that process. To stop it, ship a build/config that never calls `enableApprovedFlightRecorder()` and restart the app. Do not directly dispose the manager-owned recorder while attached. Stopping future collection is **not** a privacy purge; the retained ring may persist and load later. Use the approved scoped-erasure workflow when deletion is intended.

Use `SupportEvidence.saveFlightRecorder()` for the manager-coordinated signed export; it awaits that recorder's queued manager writes. `null` means disabled/not available, not failed signature. `verifySignedFlightRecorderBundle(json)` checks both Ed25519 envelope and retained hash chain. `verifySignedJsonPayload(json)` alone checks only the envelope and is insufficient for the full `.adproof` check. `.adproof` is this SDK's JSON format, not an ad-network evidence standard.

A ring truncates old entries; a valid retained window does not prove all history since installation. Hash chaining detects inconsistent edits inside the retained sequence; a fully rewritten/re-signed history by someone controlling the device/key is outside the guarantee. Exporting raw TCF/geometry to support requires explicit review; there is no generic redact-and-keep-the-same-chain operation.

**Acceptance:** enable recorder, display and hide a QA ad placement, export immediately after route disposal, verify signature plus chain, and inspect the visible/hidden pair. Confirm a process that never enables the recorder adds no new recorder entries. Test a modified entry and a broken previous-hash link fail verification. Compile-only results do not prove geometry or viewability reflect actual screen presentation; inspect on device.

#### E4 — Consent provenance journal

Choose retention and who may export/purge before enabling. Add `enableConsentProvenanceJournal: true` to the **one existing `AdConfig`**, not to a second initialization call. An optional `onConsentProvenanceEntryAppended` callback may notify an approved local workflow; it must not forward raw entries to analytics without permission. Normal consent mutations already record provenance through the manager-owned journal. Do not construct it through internal `AdPreferences` or duplicate every automatic consent record by appending again.

Host file: `lib/ads/consent_evidence.dart`.

<!-- snippet: consent_evidence.dart -->
```dart
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

List<ConsentProvenanceEntry> readConsentEvidencePage({
  int offset = 0,
  int limit = 100,
}) {
  if (offset < 0 || limit < 1 || limit > 500) {
    throw ArgumentError('offset must be >= 0; limit must be 1..500');
  }
  return AdManager().consentProvenanceJournal?.entriesPage(
            offset: offset,
            limit: limit,
          ) ??
      const <ConsentProvenanceEntry>[];
}

Future<bool?> checkLiveConsentEvidenceChain() async {
  final journal = AdManager().consentProvenanceJournal;
  if (journal == null) return null;
  return journal.verifyChain();
}

Future<void> appendApprovedPolicyAcknowledgement({
  required String approvedPolicyRevision,
}) async {
  final manager = AdManager();
  final journal = manager.consentProvenanceJournal;
  if (journal == null) throw StateError('Consent journal is not enabled/ready');
  final current = manager.consent;
  await journal.append(
    source: 'host_policy_acknowledgement',
    policyRevision: approvedPolicyRevision,
    hasUserConsent: current.hasUserConsent,
    isAgeRestrictedUser: current.isAgeRestrictedUser,
    doNotSell: current.doNotSell,
  );
}
```

The append helper is only for a real separately approved host acknowledgement. It records current SDK flags; it does not request legal consent or make a user consented. Pass a real policy revision, not a guessed region or a fabricated decision. Do not use country strings to bypass UMP.

`verifyChain()` checks the current journal's self-consistency, not identity, completeness or an external trust anchor. Use signed export via `SupportEvidence.saveConsentProvenance()` for transfer; verify the envelope with `verifySignedJsonPayload`. Ordinary `clearSdkData()` keeps this journal unless `purgeConsentProvenanceJournal: true` is explicitly approved; its legal retention may differ from operational ad history. A direct `await journal.clear()` is destructive and must only follow that same approved retention/deletion decision.

**Acceptance:** record a real QA consent choice and revisit/withdraw via privacy options; page through with limits 1..500, compare flags to observed mutations, verify chain and signed export, tamper a signed payload, and confirm explicit purge behavior. Journal entries alone do not establish legal compliance for every country.

#### E5 — Dispute kit, generic signing and verification

`exportDisputeKit(from:, to:)` aggregates signed compliance, bypass and incident envelopes, plus flight recorder when enabled. It does not create a new outer signature and does not include provenance automatically. Its components are not uniformly time-filtered or redacted: `from`/`to` filter the compliance part; other components retain their own recent windows. `saveUnredactedDisputeKit()` intentionally names the privacy risk and requires separate approval. Export provenance separately when required.

Host file: `lib/ads/evidence_verifier.dart`. This complete verifier accepts a supplied artifact string; it does not read arbitrary paths or upload files.

<!-- snippet: evidence_verifier.dart -->
```dart
import 'dart:convert';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

Future<bool> verifyDisputeKitJson(String json) async {
  try {
    final root = jsonDecode(json) as Map<String, dynamic>;
    if (!await verifySignedComplianceReportJson(jsonEncode(root['compliance']))) {
      return false;
    }
    if (!await verifySignedJsonPayload(jsonEncode(root['bypassAuditTrail']))) {
      return false;
    }
    if (!await verifySignedJsonPayload(jsonEncode(root['incidentBundle']))) {
      return false;
    }
    if (root.containsKey('flightRecorderBundle')) {
      if (!await verifySignedFlightRecorderBundle(
        jsonEncode(root['flightRecorderBundle']),
      )) {
        return false;
      }
    }
    return true;
  } catch (_) {
    return false;
  }
}

Future<bool> verifySupportCompliance(String json) =>
    verifySignedComplianceReportJson(json);

Future<bool> verifySupportPayload(String json) => verifySignedJsonPayload(json);

Future<bool> verifySupportFlightRecorder(String json) =>
    verifySignedFlightRecorderBundle(json);

Future<bool> verifySupportDiagnosticsChecksum(String json) =>
    AdDiagnostics.verifySafeJsonString(json);

Future<SignedPayload> signApprovedHostJson(String approvedJson) async {
  jsonDecode(approvedJson);
  return signJsonPayload(approvedJson);
}
```

`signJsonPayload` and `signComplianceReport` generate/load the on-device Ed25519 seed through secure storage. They do not mint VIP tokens and must never receive the VIP signing private key. If secure storage cannot persist a signing key, key continuity may not survive future exports. Device-generated signing keys and VIP issuer keys are separate trust domains. A public key travelling inside an envelope is untrusted metadata until compared with an independently trusted expected key. A valid signature proves consistency with that key, not publisher identity, non-repudiation, legal consent, or the truth of the logged events. Never reconstruct the signed payload with different JSON whitespace/key order before verifying it; verify the exact `reportJson` or `payloadJson` string carried by the envelope.

**Offline operator verification using the shipped SDK tools:** these commands run from the downloaded pinned SDK package root (the folder containing `pubspec.yaml` and `tool/`). They do not contact a verification server. Install dependencies first with `flutter pub get` in that root if needed. Replace path placeholders with approved local evidence files; do not upload them to a public paste site.

```bash
dart run tool/verify_compliance_report.dart /approved/path/compliance.json
dart run tool/verify_adproof.dart /approved/path/flight.adproof
dart run tool/incident_replay.dart /approved/path/incidents.json
dart run tool/bypass_audit_replay.dart /approved/path/bypass.json
```

- Compliance/adproof verifier: `VALID`, exit 0 only when its full check succeeds; `INVALID`, exit 1 on invalid signature/format/chain; missing file or usage error exits 2.
- Incident/bypass replay: prints `signature: VALID` or `signature: INVALID` and a timeline. Invalid signatures exit 1 **but still print parsed entries**; treat that timeline as untrusted. Usage/missing file/malformed envelope errors use exit 2. Check process exit status, not merely whether text was printed.
- A toolchain may print build-hook output before tool output. Do not depend on stdout being exactly one line; use the exit code plus expected validity result. An infrastructure failure before tool execution is not `VALID` or `INVALID` evidence.
- `exportSafeDiagnostics()` returns a bounded, redacted diagnostics JSON with a SHA-256 checksum, not an Ed25519 signature. `AdDiagnostics.verifySafeJsonString(json)` only checks accidental/modified payload consistency against that embedded checksum; it is not identity or tamper-proof evidence. Use the signed exports above for evidence requiring signature.
- No standalone provenance CLI is shipped. Use `verifySignedJsonPayload` above for the signed journal. No single dispute-kit CLI is shipped; verify each nested component with the in-file helper. Do not claim an absent tool exists.

**Acceptance:** valid artifacts pass their appropriate verifier; edited payloads and wrong signatures fail; malformed input returns false/invalid without executing data. Check absent optional flight/provenance exports explicitly. Do not overwrite/share the original evidence merely to test corruption—tamper a separate copy. Confirm no credentials, entered VIP tokens, unexpected user identifiers or raw consent strings leave the approved channel.

#### E6 — Retention and teardown checklist for these recipes

| Artifact | Owner / storage | Stop vs. delete |
|---|---|---|
| Event log | Manager-owned rolling SDK preference log | SDK teardown flushes; approved SDK-scoped erasure is the deletion route. Do not clear host preferences broadly. |
| Flight recorder | Host opts in; manager owns active recorder and attachment | Replacement retires the old recorder; production disable is not public and `destroy()` does not clear it. Persisted retained evidence is not automatically a purge; use explicit approved erasure. |
| Consent provenance | Manager-owned opt-in journal | Retained by ordinary erasure; purge separately only after privacy-owner decision. |
| Bypass history / incident timeline | Manager getters; bounded recent windows | Can outlive a destroy/re-init in process; do not present them as an infinite complete history. |
| Exported files | Host private directory/share workflow | The host must delete these files under its retention policy; SDK preference erasure does not find them. |
| On-device compliance signing key | SDK secure storage | Signing proves bytes, not identity; erasure behavior intentionally differs from ordinary event data. Never distribute its private seed. |

Every acceptance row must distinguish Dart analysis, native compile, device render and privacy/legal approval. None substitutes for another. Native offline/no-fill is not a failed signature test, and a valid evidence signature does not prove ad presentation or consent behavior.


### 10.13 — VIP status, promotion results and revocation (optional)


#### Reactive status without a second entitlement store

**When:** show an ad-free badge or hide the host's ad UI while VIP is active. `AdManager().vip` is nullable before successful startup; SDK-owned ad surfaces already suppress themselves while active. Do not implement a parallel `isVip` preference.

**Host file:** `lib/vip_status_badge.dart`. This widget rebinds after SDK init revision and uses the SDK listenable. It only renders active/inactive status; entry/expiry details must also refresh after the host completes a grant/revoke because stacking can change expiry without changing the active boolean.

<!-- snippet: vip_status_badge.dart -->
```dart
import 'package:flutter/material.dart';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

class VipStatusBadge extends StatelessWidget {
  const VipStatusBadge({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: AdManager().initRevision,
        builder: (_, __, ___) {
          final vip = AdManager().vip;
          if (vip == null) return const Text('VIP not ready');
          return ValueListenableBuilder<bool>(
            valueListenable: vip.activeListenable,
            builder: (_, active, __) => Text(active ? 'VIP active' : 'Free'),
          );
        },
      );
}
```

Replace user-visible strings through existing localization. Never dispose SDK-owned `VipManager` or its listenable from a screen; dispose only subscriptions/controllers the screen created. `vip.entries` is an immutable snapshot, not a stream; `expiresAt` is the latest active expiry and should not be polled every frame because it advances the persisted clock high-water mark. Use normal UI refresh after actions or a modest timer for display only. SDK expiry state, not the UI countdown, controls ad suppression.

Optional SDK notice signals are `vip.firstInstallGrantDueListenable` with `vip.lastFirstInstallGrantDuration`, and `vip.graceNudgeDueListenable` near expiry. If product approves showing such a notice, display approved localized copy once, then call `acknowledgeFirstInstallGrant()` or `acknowledgeGraceNudge()` after the notice is consumed. Do not call `notifyFirstInstallGrant` to grant entitlement: it is only a notice-state hook; actual trial entitlement belongs to SDK initialization. Listenables do not grant/revoke time themselves. A host-owned listener must be detached on teardown; never dispose the SDK notifier.

#### A complete promotion/revocation service

**When:** partner approved signed promotions and has an existing approved network/config transport for a signed CRL. This library takes that transport as a callback; it adds no HTTP dependency or endpoint. `fetchSignedCrl` must return raw `CRL1...` text, never an unsigned list of key IDs. The runtime app holds a public key only. Provide the callback when creating the service in the host's existing composition/startup owner.

**Host file:** `lib/vip_promotions.dart`. Call `refreshRevocations()` after successful startup and on the host's approved resume/manual refresh schedule. It is not another SDK initializer. Avoid overlapping timer fetches. This example has no timer to dispose; a host adding one must cancel it when its owner stops. Use the live `AdManager().vip` for each action, not a manager cached across destroy/reinitialize.

<!-- snippet: vip_promotions.dart -->
```dart
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

class PartnerCrlProvider implements VipRevocationProvider {
  PartnerCrlProvider(this.fetch);
  final Future<String?> Function() fetch;

  @override
  Future<String?> fetchSignedCrl() =>
      fetch().timeout(const Duration(seconds: 10));
}

class VipPromotions {
  VipPromotions({
    required this.publicKeyBase64,
    required Future<String?> Function() fetchSignedCrl,
  }) : crlProvider = PartnerCrlProvider(fetchSignedCrl);

  final String publicKeyBase64;
  final PartnerCrlProvider crlProvider;

  Future<void> refreshRevocations() async {
    final vip = AdManager().vip;
    if (vip == null || vip.isDisposed) return;
    await vip.refreshRevocationList(
      publicKeyBase64: publicKeyBase64,
      revocationProvider: crlProvider,
    );
  }

  Future<String> redeem(String enteredCode, {bool allowLegacyV1 = false}) async {
    final vip = AdManager().vip;
    if (vip == null || vip.isDisposed) return 'notReady';
    await refreshRevocations();
    if (vip.isDisposed || !identical(AdManager().vip, vip)) return 'notReady';
    final result = await vip.redeemSignedKey(
      enteredCode.trim(),
      publicKeyBase64: publicKeyBase64,
      stack: true,
      allowLegacyV1: allowLegacyV1,
    );
    if (result.isOffline) return 'offline';
    return switch (result.status) {
      VipRedeemStatus.success => 'success',
      VipRedeemStatus.alreadyUsed => 'alreadyUsed',
      VipRedeemStatus.invalid => 'invalid',
    };
  }

  Future<void> revokeOneAfterConfirmation(String existingEntryKey) async {
    final vip = AdManager().vip;
    if (vip == null || vip.isDisposed) return;
    await vip.revokeVip(existingEntryKey);
  }

  Future<void> revokeAllAfterConfirmation() async {
    final vip = AdManager().vip;
    if (vip == null || vip.isDisposed) return;
    await vip.revokeAll();
  }
}
```

The result strings are **host localization keys**, not raw token/error output. The UI maps each key to approved localized text and checks `mounted` after awaiting. Treat `offline` separately: the key was not verified/rejected merely because activation had no network. `invalid` includes malformed, expired, wrong-app, signature and other rejection cases; show a safe message without logging the entered token. Do not uppercase the signed token. Default `allowLegacyV1` stays false; opt in only for actually issued legacy promotions. `VipRedeemScreen` does not expose that option, so legacy support needs this approved custom branch.

Revoke actions remove local grants, not globally issued codes. `revokeAll()` does not reset the redemption ledger; revoking a grant is not permission to redeem the same one again. A signed CRL rejects revoked IDs and can clamp corresponding grants; current manager behavior narrows matching existing grants to a short grace (up to 24 hours), rather than guaranteeing instant removal on every device. Transport/verification failures preserve the last known verified CRL; offline devices cannot receive a new revocation immediately. CRL ordering uses signed `issuedAt`: an older/equal list does not replace the newer cache. It is not a separate `--revision` CLI parameter. Do not claim worldwide single-use licensing or guaranteed immediate revocation without a backend.

### 10.6a — VIP operator quick start (no SDK checkout needed)

The SDK ships its operator scripts inside the pub.dev package, so a partner with only pub.dev access can run them. These steps were run end to end against SDK 3.6.2 (replace `<VERSION>` below with the version you pinned).

**1. Get the scripts (once).** Do this in a scratch folder **outside** your app and outside `~/.pub-cache`:

```bash
mkdir -p ~/vip_tools && cd ~/vip_tools
dart pub unpack applovin_admob_sdk:<VERSION>   # for example 3.6.1, or the version you pinned
cd applovin_admob_sdk-<VERSION>
```

`dart pub unpack` downloads the package and runs `pub get` for you, so the scripts are ready. Use the same version as your app. Always run the scripts with **bare `dart`** (`dart tool/vip_mint.dart ...`), never `dart run ...`: on Dart 3.10+ `dart run` prints "Running build hooks..." before the token and corrupts anything you capture.

**2. Generate the key pair (once per issuer, ever).**

```bash
mkdir -p ~/secure   # keygen fails with "could not write private-key file" if this folder is missing
umask 077
dart tool/vip_keygen.dart --private-out ~/secure/vip-private-key
```

Real output:

```text
Ed25519 VIP signing key pair
PUBLIC  (embed in app, safe to commit): iBTlcV6HgC7HQUDSZBu58Vikg4fumy7qop5xSeM2KoE=
PRIVATE stored in 0600 file: /Users/you/secure/vip-private-key (never commit)
```

Copy the value after `PUBLIC ... :` into `VipConfig.publicKeyBase64`. The private file is created with owner-only permissions. Without `--private-out` it writes `.vip-private-key` in the current folder (inside the unpacked SDK folder), which you do not want. The script refuses to overwrite an existing private file; do **not** pass `--force` to an issuer key you still use: every code already minted would stop verifying.

**3. Mint a promotion token.**

```bash
dart tool/vip_mint.dart --priv-file ~/secure/vip-private-key --days 30 --valid-days 14 --bundle com.partner.app,com.partner.app.ios --kid PROMO30-001
```

It prints exactly one line, the token. Send that line to the user unchanged (email, support chat). The user pastes it into the app's redeem field:

```text
AVP2.MjU5MjAwMHxQUk9NTzMwLTAwMXwxNzk0...<payload>.<signature>
```

| Flag | Required | Default | Meaning |
|---|---|---|---|
| `--priv-file PATH` | yes (or `--priv-stdin`) | none | The private key file from step 2. `--priv` (key on the command line) is rejected on purpose. |
| `--days N` or `--seconds N` | one of them | none | How long the VIP window lasts **after** the user redeems. |
| `--valid-days N` | no | 30 | How long the **token** stays redeemable. Must be at least 1. |
| `--bundle IDS` | no | any app | Comma-separated bundle IDs the token works in. List every platform ID: Android `applicationId` and iOS `PRODUCT_BUNDLE_IDENTIFIER` usually differ. Matching is exact and case-sensitive; add a debug `applicationIdSuffix` ID too if you test a debug build. Omitting it makes a token that works in **any** app that holds your public key. |
| `--kid ID` | no | auto (`K` plus a number) | Label for this promotion. It is upper-cased (`promo30-001` becomes `PROMO30-001`) and is what a revocation list names. Always set one so you can revoke it later. |
| `--v1` | no | off | Old AVP1 format with no expiry and no app binding. Avoid. |

Record every `kid`, who received it and when, in your own ledger: the SDK has no server and cannot list issued tokens.

**4. Revoke tokens (publish a signed revocation list).**

```bash
dart tool/vip_crl_mint.dart --priv-file ~/secure/vip-private-key --kids PROMO30-001,PROMO30-002
```

It prints one line starting with `CRL1.`. Each run produces a **replacement** list that is stamped with the current time: always include **all** revoked kids, not just the new one. Host that text file anywhere reachable by your app over HTTPS (a static file on your site or a cloud storage object is enough) and return its raw contents from the `fetchSignedCrl` callback in Step 10.13. An empty `--kids` produces a valid empty list, which does not un-revoke anything already applied. A revoked grant is shortened to a short grace (up to 24 hours), not cut instantly, and a device that is offline will not see the list until it reconnects.

**5. Test every outcome without a server.** Use throwaway keys, never your real issuer key. `verifySignedVipKey` checks a token fully offline, so you can prove each failure mode in a Flutter test (Dart-only, no device). Mint a token for your own app id as in step 3 (the `applicationId` in `android/app/build.gradle.kts`). The test below uses `com.partner.app` as a stand-in: **replace it with your own app id in every place it appears in the test**, or the bundle checks fail. Save the file as `test/vip_offline_verify_test.dart` in your app (or in the unpacked SDK folder), then run `flutter test test/vip_offline_verify_test.dart`. Then:

<!-- snippet: vip_offline_verify_test.dart -->
```dart
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

const publicKey = '<PUBLIC KEY PRINTED IN STEP 2>';
const token = '<TOKEN PRINTED IN STEP 3>';

Future<Object?> verify({String bundle = 'com.partner.app', DateTime? now, String? code}) async {
  try {
    await verifySignedVipKey(code ?? token,
        publicKeyBase64: publicKey, currentBundleId: bundle, now: now);
    return null;
  } catch (e) {
    return e;
  }
}

void main() {
  test('valid token verifies for its app', () async {
    expect(await verify(), isNull);
  });
  test('wrong app is rejected', () async {
    expect(await verify(bundle: 'com.other.app'), isA<VipKeyException>());
  });
  test('expired token is rejected (move the clock past --valid-days)', () async {
    expect(await verify(now: DateTime.now().add(const Duration(days: 30))),
        isA<VipKeyException>());
  });
  test('tampered token is rejected (flip one signature character)', () async {
    final p = token.split('.');
    final sig = p[2];
    final flipped = '${sig.substring(0, 10)}${sig[10] == 'A' ? 'B' : 'A'}${sig.substring(11)}';
    expect(await verify(code: '${p[0]}.${p[1]}.$flipped'), isA<VipKeyException>());
  });
}
```

This was run with a real minted token: all four tests pass. A real redemption (`redeemSignedKey`) additionally needs network and a running SDK, so test that on a device or emulator: redeem once (expect `success`), redeem the same token again on the same install (expect `alreadyUsed`), and turn on airplane mode before redeeming (expect `isOffline == true`, not `invalid`). "Network" means ordinary internet connectivity; the signature check itself never leaves the device. To prove expiry on a real device you cannot mint a zero-day token (`--valid-days` must be at least 1): either mint with `--valid-days 1` and wait a day, or rely on the clock-moved test above.

**Key rotation.** `publicKeyBase64` also accepts several public keys in a single comma-separated string, for example `'<OLD_PUB>,<NEW_PUB>'`. Tokens signed by either verify. Keep an old key in the list only as long as you still need its tokens: a compromised key keeps validating forged tokens for as long as it stays in the list.

**Acceptance using disposable keys/data:** valid/invalid signature, expired/wrong-app, legacy rejected/default versus explicit allow, already-used, offline, entry expiry, stacked cap, revoke-one/all, malformed/null/timeout/old CRL, newer valid CRL and restart/offline cache. Confirm active UI and ad suppression follow SDK state. Test Android clear-data/reinstall/backup limitations separately; no test or local ledger makes these paid-license enforcement. Production release and keys must remain independent of this test workflow.


## Step 11 — Partner readiness review & update `<PROJECT_PATH>/doc/AD.MD`

> **Read in this order.** Do 11.0a (release build and the three leak checks) first, because it catches the most expensive mistakes: test IDs or Google's test App ID shipped to production. Then 11.1 (native config), then 11.6 (device tests). 11.2 to 11.5 are checklists to tick; each box names the Step that explains it. Gate rows you cannot verify yourself (legal, consent by market) go to the partner owner and are recorded as "pending owner", never as PASS.

Before handoff or production rollout, complete this checklist with the partner's owners. Put the completed evidence in `<PROJECT_PATH>/doc/AD.MD` (created in Step 3) under “Partner readiness”. For each test row, record: test case, device/model + OS, build mode, provider/region, expected result, observed result, log/screenshot path, and PASS/FAIL. A passing emulator build is not device compatibility evidence.

### 11.0 — Partner release gates

- [ ] Product owner approved provider, ad formats/placements, launch triggers, VIP/grace scope, and all user-facing ad disclosures. On target devices, verify each placement has clear separation from navigation buttons, scroll controls, and other tappable app content; review real layout after ad fill to catch shifts that could redirect a pending tap. Avoid showing fullscreen ads during active scrolling, with the keyboard open, or outside an intentional transition/approved user flow.
- [ ] Privacy/legal owner approved target markets, consent/CMP flow, ATT purpose text, age-directed behavior, privacy-policy URL, data purposes, retention, and any permitted diagnostics
- [ ] Security/privacy owner reviewed Android backup policy before any change; backup include rules are merged, not replaced, and scope is understood to include all keys in `FlutterSharedPreferences.xml`
- [ ] Tested consent granted, denied/withdrawn, unavailable/offline, app resume, and re-initialization for each enabled provider; record provider-specific limitations, including AppLovin consent writes being fire-and-forget
- [ ] Ran on real partner-target devices/OS versions, including at least one low-memory/low-end device and one current flagship per supported platform; add OEM-specific devices (Samsung, TECNO, Huawei, etc.) from the partner's launch matrix. Record device model, OS, architecture, provider, build mode, network, and outcome
- [ ] Verified cold start, splash timeout/ad success/ad unavailable, fullscreen dismiss/reward, background/resume, rotation/window resize where supported, no-network/reconnect, and VIP/consent paths that are in scope
- [ ] Release build uses production app IDs/ad unit IDs only in approved release configuration; debug/test builds use test inventory. Confirm no test geography, test IDs, verbose logs, private VIP signing key, or unapproved diagnostics are shipped
- [ ] Reviewed merged manifest permissions, exported components, backup rules, iOS privacy declarations/ATT text, SKAdNetwork configuration, and dependency lockfiles against partner policy
- [ ] Captured final analyze/test/build results and signed-off known limitations, rollback owner/path, monitoring owner, and escalation contacts



One review pass only, do NOT repeat it 3 times. Checklist:

### 11.0a — Building and checking a release (copy-paste, verified)

Production IDs are passed at build time so no real ID is committed. Real command (replace the values with the partner's production AdMob **ad unit** IDs; an ad unit ID contains `/`):

```bash
flutter build apk --release \
  --dart-define=ADMOB_ANDROID_BANNER_ID=ca-app-pub-XXXXXXXXXXXXXXXX/NNNNNNNNNN \
  --dart-define=ADMOB_ANDROID_INTERSTITIAL_ID=ca-app-pub-XXXXXXXXXXXXXXXX/NNNNNNNNNN \
  --dart-define=ADMOB_ANDROID_APP_OPEN_ID=ca-app-pub-XXXXXXXXXXXXXXXX/NNNNNNNNNN \
  --dart-define=ADMOB_ANDROID_REWARDED_ID=ca-app-pub-XXXXXXXXXXXXXXXX/NNNNNNNNNN
```

Every ad format you ship needs its own define (`ADMOB_ANDROID_REWARDED_INTERSTITIAL_ID`, `ADMOB_ANDROID_MREC_ID`, `ADMOB_ANDROID_NATIVE_ID`, and the `ADMOB_IOS_*` equivalents; copy the exact names from the `String.fromEnvironment` calls in your `lib/ad_config.dart`). A missing define means that format is silently not configured.

For a Play Store upload build with `flutter build appbundle --release`, use the same `--dart-define` flags. For iOS use `flutter build ipa --release` with the same flags. iOS needs an Apple Developer team and distribution profile from the app owner: ask for the team ID, and use `--no-codesign` until you have them. For production you also need a separate **iOS app** created in AdMob to get an iOS AdMob App ID; the Google test iOS App ID is for debug only.

**Why a missing define is dangerous.** A forgotten `--dart-define` does not fail the build: the ID silently becomes an empty string and, in release, that ad format never loads and nothing visibly breaks. In release the SDK logs a warning such as `banner ad-unit id is empty in a RELEASE build` at start-up (log level `warning` is on by default in release), but you must also verify before shipping.

**Checks that must all pass before you ship** (these commands were run against a real release APK):

```bash
# 1. No Google TEST ad-unit IDs inside the compiled Dart code. Expect: 0
rm -rf /tmp/apk_check   # a stale folder from an earlier build would fool check 1
unzip -q -o build/app/outputs/flutter-apk/app-release.apk -d /tmp/apk_check
strings /tmp/apk_check/lib/arm64-v8a/libapp.so | grep -cE "ca-app-pub-3940256099942544/[0-9]+"

# 2. Your production IDs ARE present. Expect: one line per configured format
# (or, without knowing your publisher id: ... | grep "ca-app-pub-" | grep -v 3940256099942544)
strings /tmp/apk_check/lib/arm64-v8a/libapp.so | grep "ca-app-pub-XXXXXXXXXXXXXXXX/"   # replace XXXXXXXXXXXXXXXX with your own publisher id

# 3. The AdMob APP ID in the shipped manifest is yours, not Google's test App ID.
#    Expect your ca-app-pub-...~... value, NOT ca-app-pub-3940256099942544~3347511713
# If ANDROID_HOME is empty: run `flutter doctor -v`, read the "Android SDK at ..." path,
#   and use the newest folder under <that path>/build-tools/ as <version>
#   (example: ls ~/Library/Android/sdk/build-tools | sort -V | tail -1).
"${ANDROID_HOME:-<ANDROID_SDK_PATH>}"/build-tools/<version>/aapt2 dump xmltree --file AndroidManifest.xml \
  build/app/outputs/flutter-apk/app-release.apk | grep -A1 APPLICATION_ID
```

Pass criteria: check 1 prints `0`, check 2 lists every format you ship, check 3 shows your own App ID. Check 3 matters because the manifest `meta-data` is a literal: the SDK's release guard protects against Google test **ad unit** IDs in Dart, but it cannot see the manifest, so a forgotten Google test **App ID** there ships silently. A release build that is signed with the debug key (the Flutter default) can be installed for testing but cannot be uploaded to Google Play: create an upload keystore and a `signingConfigs.release` block in `android/app/build.gradle.kts` before store submission (follow Google's "Sign your app" guide; this is Android tooling, not part of this SDK).

**What the SDK does for you in release.** If any Google **test** ad-unit ID is still configured when the app runs as a release build, the SDK blocks all ad requests for that session (the app still runs, `canRequestAds` stays false) instead of serving test ads. If you see no ads in a release build, the first thing to check is that guard and the empty-ID warning above, before suspecting your code. A leftover `umpDebugGeography` also produces a warning in release (Step 8.1).

### 11.1 — Native config

- [ ] `pubspec.yaml`: add `applovin_admob_sdk: ^3.6.2` (or the pub.dev version you selected in Step 4.0) and keep unrelated dependencies unchanged. Do not add provider plugin dependencies manually unless required by the selected integration.
  - `gma_mediation_applovin` is **optional**, app-level, and only for AppLovin as an AdMob mediation network. Current source fixture pins `2.6.2` and asserts AppLovinSDK `13.6.3`; read `packages/ad_sdk/CLAUDE.md` and `tool/check_pinning_wall.sh` before changing this combination.
  - `google_mobile_ads` is constrained to `>=9.0.0 <9.1.0` in current package metadata; do not upgrade across that cap until the iOS regression is resolved and the source constraint changes.
  - `app_tracking_transparency` is a **transitive dependency of the SDK** — do NOT add it at the app level.
  - Do not add GetX, `intl`, `url_launcher`, `confetti`, or other packages solely because optional examples use them.
- [ ] `AndroidManifest.xml` permission whitelist: `INTERNET` + `ACCESS_NETWORK_STATE` + `AD_ID`. Any ad-related permission beyond these 3 needs a clear justification. Any non-ad permission → ask the user first.
- [ ] If AdMob is selected, `AndroidManifest.xml` has the matching AdMob `APPLICATION_ID` (test ID for debug only; production ID for release)
- [ ] `MainActivity` does **NOT** have `android:taskAffinity=""` (pitfall #1)
- [ ] If targeting iOS, configure `GADApplicationIdentifier` required by `google_mobile_ads`/UMP, `AppLovinSdkKey` if AppLovin is enabled, and partner-approved `NSUserTrackingUsageDescription` only if ATT is approved/in scope. AdMob ad-unit IDs are needed only if serving AdMob ads.
- [ ] Merge required `SKAdNetworkItems` for enabled networks/mediation from current official provider lists. The example `example/ios/Runner/Info.plist` is a reference list; merge it with existing partner entries rather than replacing the array, and re-check provider documentation at release time. Do not rely on a dated ID count.
- [ ] Android app uses Kotlin Gradle plugin `>=2.3.0` with GMA 9.0.0. In `android/settings.gradle.kts`, set the plugin version (check current example `example/android/settings.gradle.kts`); in `android/app/build.gradle.kts`, replace removed `kotlinOptions { jvmTarget = ... }` with:
  ```kotlin
  kotlin {
      compilerOptions {
          jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) // must equal compileOptions
      }
  }
  ```
- [ ] If AppLovin is selected, match AppLovin SDK key/platform ad-unit IDs to partner dashboard. If AdMob is selected, register correct App ID per platform in manifest/Info.plist.
- [ ] (If iOS) Podfile deployment target is at least 13.0; run `(cd ios && pod install)` and then an actual `flutter build ios --simulator --debug --no-codesign`. Successful `pod install` alone does not prove Xcode compile/link succeeds.

### 11.2 — Bootstrap

- [ ] `main.dart`: `AdManager().setNavigatorKey` before `runApp`, navigator observers complete (`adRouteObserver` + `AdScreenRouteLogger()`)
- [ ] If ATT is in scope on iOS, `AdManager().requestAtt()` is called after first frame; then `initialize()` runs. SDK auto UMP is enabled by default and runs before provider init. If host explicitly calls `requestUmpConsent()` itself, set `autoRequestUmpConsent: false` to avoid duplicate consent flow.
- [ ] Splash: use `AdReadinessSplashController` (default), or implement the manual equivalent with `SimpleEventBus().listen` registered BEFORE `initialize`, hard-cap (default 8s), `markSplashActive/Inactive` paired correctly, hot-restart guard `countInitSplashScreen > 1`, and the App Open flow `loadAppOpenAd → showAdBuffer → showAppOpenAd(bypassSafety: true)` in the right order
- [ ] If disclosure is required/approved, splash shows the exact owner-approved localized copy before the relevant ad surface; approval/copy/location recorded in `doc/AD.MD`
- [ ] `AdConfig.onLog` is wired to the project's logger

### 11.3 — Slot integration

- [ ] For widget/helper integration, screens use `AdScreen` + `AdScreenState` when practical; if using direct widgets/APIs, document equivalent route/visibility/disposal wiring for each placement
- [ ] Banner is wrapped edge-to-edge if the app uses `UIUtils.initEdgeToEdge()`
- [ ] Every ad slot has been replaced (grepping the old SDK's name no longer matches anything)
- [ ] Remove superseded direct integrations only; retain the selected provider dependencies, and include `gma_mediation_applovin` only when the partner uses AppLovin as AdMob mediation
- [ ] Both build targets from Section 0 are green (debug + release)
- [ ] `flutter analyze --fatal-infos` → 0 issues

### 11.4 — Consent + optional VIP

- [ ] Consent flow and provider-specific behavior reviewed for target regions, age groups, and partner-approved CMP/policy requirements; execute and record grant, deny/withdraw, no-network/update-failure, privacy-options revisit, resume, and re-init paths for enabled flows
- [ ] iOS ATT prompt is present only where applicable, with partner-approved purpose text and correct ordering before UMP/first ad request
- [ ] If VIP is approved: ship only the public signing key; use signed redemption and handle invalid, expired, wrong-app, already-used, and offline cases; document Android reinstall/clear-data replay limitation
- [ ] If first-install grace is approved: verify the configured duration and backup policy with the partner security/privacy owner; otherwise set `FirstInstallVipGrace.disabled`
- [ ] If VIP is out of scope: no VIP UI, plaintext key map, signing material, or unapproved grace entitlement is added

### 11.5 — Host conventions and lifecycle

- [ ] New code follows the host app's state-management, localization, and logging conventions; no framework/package was added solely to match this template
- [ ] Contexts, nullable SDK state, timers, controllers, and subscriptions are used/disposed safely in each changed integration file
- [ ] Raw user-entered VIP codes and IAB consent strings are absent from logs and diagnostics

### 11.6 — Smoke and device-matrix tests (mandatory before partner handoff)

Run the debug smoke test on an emulator, then run the agreed real-device/OS matrix from 11.0. Record each result; emulator success does not replace physical-device testing.

```
1. Cold-start the app.
   Verify: no fatal exception, splash renders, initialization completes or hard-cap exits without a stuck state.

2. Exercise the configured consent path.
   Verify: consent form behavior for applicable region; record granted/denied/withdrawn and unavailable/offline results before any ad request.

3. Exercise enabled ad formats with test inventory in debug.
   Verify: load/show/dismiss or reward callbacks, safety gate behavior, and no crash during background/resume or reconnect.

4. Inspect release configuration and logs.
   Verify: no test ad IDs/geography, private VIP signing key, user-entered VIP key, consent string, or unapproved personal data in shipped config/log output.

5. If VIP is approved, redeem test AVP2 keys only.
   Verify: valid, invalid, expired, wrong-app, already-used, and offline redemption behavior; never use a production promotion/license key for testing.

6. Verify Android backup behavior only if partner security/privacy owner approved enabling it.
   Verify: merged backup rules and observed restore scope; otherwise confirm existing backup policy remains unchanged and VIP grace is disabled.

7. Attach the device/OS/provider/build/network matrix, test evidence, known limitations, and sign-off owners to the partner handoff record.
```

If any item FAILs → fix it → re-check only that item (don't re-check items that already PASSed).

## Step 12 — Partner handoff report

> **Shortest honest report:** a table with one row per item below and one of three values: `PASS (evidence path)`, `FAIL (reason)` or `NOT RUN (reason)`. Do not write PASS without a log, screenshot or command output you can point to. If you did only the Fast path, the report is: build modes tried, device model and OS, and what you saw. Everything else is `NOT RUN`.

Report only verified results; do not mark a gate PASS without evidence. Include:

- SDK, Flutter, Dart, Android Gradle/Kotlin, iOS/Xcode, and provider SDK versions
- `flutter analyze`, unit/widget tests, platform builds, and real-device matrix with model/OS/provider/build/network/results
- Enabled formats and placements; approved consent/CMP/ATT behavior by market and provider
- Release-config checks (test IDs/geography absent, logging/privacy review, manifest/permissions, backup policy)
- VIP/grace scope and approved behavior, if applicable; disclose Android replay limitation
- Known failures, accepted limitations, rollback/monitoring owners, and outstanding partner sign-offs

Never include real credentials, private VIP signing keys, raw user-entered keys, or raw consent strings in the report or attached logs.

---

## Appendix A — API mapping (Android Kotlin → Flutter Dart)

If the user is migrating from a native Android project using an `_AdmobWrapper`, here's a quick mapping:

| Android (Kotlin) | Flutter (Dart) |
|---|---|
| `AdManager.setConfig(...)` | `AdManager().initialize(config: AdConfig(...))` |
| `AdManager.requestConsentInfoUpdate(...)` | `AdManager().requestUmpConsent(...)` |
| `AdManager.awaitSplashComplete()` | `SimpleEventBus().listen` + `loadAppOpenAd` + `showAppOpenAd(bypassSafety: true)` |
| `AdManager.loadBanner(view, R.id.banner_container)` | `class _XxxState extends AdScreenState<Xxx>` → `buildBanner()` inside `build()` |
| `AdManager.showInterstitial { ... }` | `showInterstitialAd(onDone: (shown) {...})` |
| `AdManager.loadRewarded` + `showRewarded` | `showRewardedAd(onEarnedReward: (earned) {...})` |
| Legacy app-local VIP map | `AdManager().vip` (null-safe) → `redeemSignedKey(code, publicKeyBase64:)` or `VipRedeemScreen` (only if VIP is approved; requires network) |
| `AdSafetyLimits(interstitialMinIntervalSec: 60, ...)` | `AdSafetyParams.production.copyWith(...)` (defaults to `auto`, do NOT override) |
| `BuildConfig.IS_ENABLE_ADMOB` flag | Select `AdConfig.provider` at init (`AdProvider.appLovin` or `AdProvider.admob`); changing later requires explicit `destroy()` + reinitialize and partner approval |
| `Application.onCreate { AdManager.initialize() }` | `main()` only calls `setNavigatorKey`; init happens in `SplashScreen.initState()` |
| `ProcessLifecycleOwner` for App Open resume | SDK auto via `WidgetsBindingObserver` — do NOT subscribe yourself |
| Fragment + `onDestroyView` | `StatefulWidget` + `dispose()` |
| `ObjectAnimator`, `ValueAnimator`, `CountDownTimer` | `AnimationController`, `TweenAnimationBuilder`, `Timer.periodic` |
| `SharedPreferences.edit().putBoolean(...)` | `package:shared_preferences` `prefs.setBool(...)` |
| `DateFormat.getDateInstance(MEDIUM)` | `package:intl` `DateFormat('dd/MM/yyyy')` |
| `VibrationEffect.EFFECT_CLICK` | `HapticFeedback.heavyImpact()` (Flutter built-in) |
| Material You (`com.google.android.material`) | Material 3 (`ThemeData(useMaterial3: true)`) |
| Kotlin `lateinit var` | Use the host's normal Dart initialization pattern; ensure nullable SDK values (e.g. `AdManager().vip`) are checked before use |
| Kotlin `!!` | Prefer null-aware access/pattern matching for values that can be absent |
| `viewModel.observe { ... }` | Use the host app's existing reactive/state-management pattern; `ValueListenableBuilder` + `ValueNotifier` are Flutter-native options |

## Appendix B — Where to find more detail

If you have the SDK's source available (either the monorepo at `packages/ad_sdk/` or a clone of it), these are worth reading directly:

- `packages/ad_sdk/README.md` — full SDK API reference (Quick start + Configuration reference + Public API)
- `packages/ad_sdk/CHANGELOG.md` — version-by-version feature history
- This file's Appendix D — existing-app upgrade checks, current compatibility and troubleshooting; historical migration recipes must not be copied as current setup.
- `packages/ad_sdk/example/lib/main.dart` — a demo app with one page per feature, useful as a working reference for bootstrap, splash, banner/interstitial/rewarded, and VIP wiring
- `lib/src/vip/vip_redeem_screen.dart` in the unpacked package — the SDK's own `VipRedeemScreen` implementation, useful if you're wrapping it directly instead of building the 13-component screen from scratch (see the note in Step 10.2)

If you only have the hosted `applovin_admob_sdk` package (no source access), the equivalent material ships with the package itself:

- The package's README and CHANGELOG on pub.dev (`https://pub.dev/packages/applovin_admob_sdk`)
- The same files under your local `.pub-cache`, e.g. `~/.pub-cache/hosted/pub.dev/applovin_admob_sdk-<version>/README.md` and `CHANGELOG.md`
- The package's own `example/` directory (also mirrored into `.pub-cache`) for a working demo of every integration point covered in this document

---

## Appendix D — Current compatibility and troubleshooting

Use the exact pinned release's CHANGELOG for version-to-version migration steps. This appendix contains current compatibility constraints and partner troubleshooting only.

### Table of contents

- [Existing-app upgrade checks](#d4--existing-app-upgrade-checks-do-not-skip-when-replacing-an-older-sdk)
- [Current compatibility](#d1--current-compatibility)
- [Common issues](#d2--common-issues)
- [FAQ](#d3--faq)

---

The upgrade checks below restate still-relevant behavior changes as current actions. The verbatim historical release notes are retained separately in Appendix E and are not current setup instructions.

### D.4 — Existing-app upgrade checks (do not skip when replacing an older SDK)

These are migration checks, not permission to restore obsolete APIs or weaken safety defaults. A new integration skips the legacy-only rows; an existing app must record each row as migrated, not applicable, or blocked.

| Existing behavior | Current action | Verification |
|---|---|---|
| Host requests UMP itself | Keep exactly one UMP owner. With a manual request use `autoRequestUmpConsent: false`; otherwise remove the manual call and use automatic UMP. Older defaults were different. | One consent sequence per cold start; withdrawal and offline/error paths still gate requests. |
| Unlimited VIP stacking | Current default `maxVipStackDuration` is 90 days. Product must approve the cap; `null` explicitly removes it and is not a default migration fix. | Redeem/watch twice and check the latest expiry and cap; test existing grants before changing policy. |
| Previously issued AVP1 promotion codes | New integrations use AVP2. Current `redeemSignedKey`/`verifySignedVipKey` reject AVP1 by default. Set `allowLegacyV1: true` only in the legacy redemption branch when the partner really issued those codes. AVP1 lacks AVP2's expiry/bundle-binding guarantees. | Old signed code accepted only with explicit opt-in; invalid signatures remain rejected. |
| `addVIPMember` / GAID-based entitlement data | Do not recreate a GAID entitlement whitelist. The SDK retains legacy compatibility APIs and an initialization migration path. Keep a copy of test entitlement state and verify upgrade on the same QA device; do not assume all previous identifiers remain applicable. | A previously entitled QA install stays entitled as intended; expired/unrelated entries do not gain VIP. Use `vip.addVip` only for trusted grants and `redeemSignedKey` for entered codes. |
| Global `bannerLoaded` / `bannerHasError` or unkeyed inline state | Prefer `BannerAdWidget`/`MrecAdWidget`/`NativeAdWidget` or `AdScreenState` helpers. Lower-level adapter state is keyed per widget instance; never share one key between simultaneous placements. | Two placements load/dispose independently and hidden tabs stop work. |
| A second entry-point import | Use only `package:applovin_admob_sdk/applovin_admob_sdk.dart`. Do not copy internal `src/` imports into a partner integration. | Analyzer resolves public APIs without private-file imports. |

**Legacy AVP1 redemption:** `VipRedeemScreen` does not expose an `allowLegacyV1` option. If existing AVP1 users must remain supported, implement the approved legacy input branch using the manager API rather than claiming the built-in screen accepts them:

```dart
Future<SignedVipRedeemResult> redeemLegacyPromotion(
  VipManager vip,
  String code,
  String publicKeyBase64,
) => vip.redeemSignedKey(
      code,
      publicKeyBase64: publicKeyBase64,
      allowLegacyV1: true,
    );
```

Do not uppercase or rewrite the entire signed token: preserve its Base64url payload/signature. Activation still requires network, even for AVP1. Never put a signing private key in this function. New minting uses AVP2; do not follow historical `--v1` mint commands.

**Android task/foreground regression:** check the existing `MainActivity` declaration for `android:taskAffinity=""`. An empty affinity can return a user to the launcher when an ad Activity closes after background/resume, leaving the app alive but apparently gone. Remove the empty override only after checking the host's deliberate task/deep-link requirements; retain normal app task affinity. Verify on a QA device with test inventory:

1. Show an interstitial and close it; the original app screen returns.
2. Show again when safety permits, press Home while it is visible, then reopen the app from the launcher.
3. Close the ad; the app screen, not the launcher or a duplicate task, must be visible. Repeat for the enabled fullscreen formats.

**Test APK overwritten by an integration test:** `flutter test integration_test/...` and a normal debug build may write the same `build/app/outputs/flutter-apk/app-debug.apk`. Rebuild the normal app explicitly before manually installing that path; otherwise the installed entry point may be a test harness and look like a stuck splash. A demo app sharing the partner app's Android package ID also cannot be installed side-by-side as a separate app. Use a separate QA application ID deliberately; do not uninstall a real app with valuable data to resolve the conflict.

### D.1 — Current compatibility

Fetch the latest stable version from pub.dev when integrating; do not assume this guide describes every release. Read that exact version's README and CHANGELOG, run `flutter pub get`, and validate native dependency resolution/builds for every target platform.

The package metadata currently sets Flutter `>=3.38.1` and Dart `>=3.10.0`. It constrains `google_mobile_ads` to `>=9.0.0 <9.1.0` because `9.1.0` has a documented iOS build regression. Verify these values against the selected release. On Android, GMA 9.0.0 requires the consuming app's Kotlin Gradle plugin to be `>=2.3.0`; Kotlin 2.3 removes the old `kotlinOptions { jvmTarget = ... }` DSL. Confirm these constraints against the actual published version selected for the partner.

For an Android app on Kotlin below 2.3.0:

1. In `android/settings.gradle.kts`, raise `id("org.jetbrains.kotlin.android")` plugin version to at least `2.3.0` (see `example/android/settings.gradle.kts` for this SDK's current pattern).
2. In `android/app/build.gradle.kts`, remove the old `android { kotlinOptions { jvmTarget = ... } }` block and use:
   ```kotlin
   kotlin {
       compilerOptions {
           jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) // must equal compileOptions
       }
   }
   ```
3. Run `flutter clean`, `flutter pub get`, and `flutter build apk --debug`. If Gradle/Kotlin fails, record the complete error and check Android Gradle Plugin/Gradle compatibility before changing further versions.

`gma_mediation_applovin` is optional and belongs at the consuming-app level only when using AppLovin as an AdMob mediation network. The checked-in known-good fixture pins `gma_mediation_applovin: 2.6.2` with `applovin_max: ^4.6.4` and asserts CocoaPods resolves `AppLovinSDK 13.6.3`. In this repository run `./tool/check_pinning_wall.sh` for Dart/pod resolution + pod version assertion, or `./tool/check_pinning_wall.sh --with-builds` to additionally compile the fixture APK and iOS Simulator app. This fixture validates dependency compatibility, not partner app configuration. When versions change, also run `flutter pub get`, `(cd ios && pod install)`, and real Android/iOS builds in the consuming app; dependency resolution alone is not compile proof.

For behavior changes between SDK releases, read the full CHANGELOG entry and this guide's corresponding integration sections. Do not treat a version bump as automatically source-compatible; confirm breaking changes and migration steps first.

---

### D.2 — Common issues

**"Build failed — `applovin_admob_sdk` is not in the dependency cache"**

A newly published version may be available in pub.dev metadata before a CDN listing refreshes. Check the exact version exists, then retry `flutter pub get` after propagation. If it still fails, inspect the resolver error, SDK floor, package source and network access. Do not clear the global pub cache as a default fix; that affects every Dart/Flutter project and does not fix an unpublished version or native dependency conflict.

**"Build failed — `Unexpected token` in `build.gradle.kts`"**

Likely the `minSdk` or `targetSdk` is set with Groovy syntax (`minSdk 24`) in a Kotlin DSL file. Use Kotlin syntax (`minSdk = 24`).

**"App crashes when user backgrounds during an ad"**

Most likely you have `android:taskAffinity=""` on `MainActivity` (Flutter's template adds it). Remove it as in Step 4.0(a2) item 4.

**Ads not loading on iOS**

Verify `Info.plist` contains `GADApplicationIdentifier` for bundled Google Mobile Ads/UMP, partner-approved `NSUserTrackingUsageDescription` only if ATT is in scope, and current merged `SKAdNetworkItems` for enabled networks. Verify Podfile targets iOS 13 or newer; run `pod install` and an iOS Simulator/device build.

**"Inter ad doesn't show — `canShow=false`"**

Run with `AdConfig.logLevel = AdLogLevel.verbose` and check the log for `⏭️ showInterstitial blocked by safety: <reason>`. The reason tells you exactly which gate denied the show:

- `Suspended: Xs remaining` — progressive cooldown active because of a recent CTR/click anomaly. Wait it out or call `AdSafetyConfig.resetSession()` in QA.
- `Session too young: wait Xs` — `minSessionDurationBeforeAd` not yet elapsed.
- `Session limit: N ads` — hit `maxFullscreenAdsPerSession`.
- `Hourly cap: N ads` — hit `maxFullscreenAdsPerHour`.
- `Daily limit: N ads` — hit `maxFullscreenAdsPerDay` (persisted across launches).
- `Throttle: wait Xms` — too soon after the previous fullscreen ad.

**"VIP grace not expiring in dev"**

With `firstInstallVipGrace: FirstInstallVipGrace.auto` explicitly selected for QA, debug grace is 30 seconds. The main integration recipe disables it, so no trial is expected there. The following command permanently erases all data for that package: use only a disposable QA install after confirmation, never a partner's live app or paid entitlement store.

```bash
adb shell pm clear com.your.package
flutter run
```

Watch the log for `🎁 first-install VIP grace granted (30s, mode=debug)` and `⏰ VIP entry expired — purging + refreshing` 30 seconds later.

**Banner shows but no banner widget visible**

Check that the banner is not being clipped by an oversized `Column` or `SafeArea` somewhere in the tree. The default banner height is 50–90dp depending on the device's adaptive size.

If the banner truly never loaded, you'll see `[BannerAdWidget] _initBanner ⏭️ <reason>` in the log:

- `⏭️ VIP` — VIP user, banner suppressed by design
- `⏭️ cooldown` — recent banner load failure, waiting for backoff
- `⏭️ already cached` — preloaded banner exists, will be reused on next mount

---

### D.3 — FAQ

**Which version should I integrate?**

Use the latest stable release shown by pub.dev at integration time, then read that version's README and CHANGELOG before changing `pubspec.yaml`. See D.1 for current 3.x compatibility constraints.

**How do I roll back?**

Pin the previous known-good version in `pubspec.yaml`, run `flutter pub get`, and read the CHANGELOG between the two versions first. Persisted SDK state (VIP entries, consent settings, daily ad counters) is not guaranteed to be readable by an older release; test rollback on a build with existing app data before relying on it.

**Can two apps in one monorepo use different SDK versions?**

Yes, if each app pins its own version in `pubspec.yaml`; verify each app builds with its own native dependency resolution.

**Why is `flutter analyze` failing right after I upgrade to a freshly-published version?**

pub.dev takes up to 10 minutes to index a new release. Wait a few minutes and re-run.

**Need help?**

- Collect SDK debug output by filtering the console for the SDK's own log prefix `roy93~` (for example `adb logcat | grep "roy93~"`, or Flutter's `flutter logs`). The prefix is the SDK's fixed `debugPrint` marker, not a project tag you must add. Redact advertising IDs, consent strings and entered VIP codes before sharing.
- Open an issue on [GitHub](https://github.com/royt93/FlutterBase2026/issues) with the redacted log output, your SDK version and which provider (AdMob / AppLovin). Include the failing Step number from this guide.
- The unpacked package's `README.md` has the SDK's own walkthrough (optional)
- Provide the SDK owner with this file, pinned version, platform logs, and the failing Step number so they can inspect internals.

## Appendix E — Historical migration record (verbatim; not current setup)

These sections are retained from the pre-restructure guide so partners upgrading from old SDK generations do not lose version-specific warnings. They are historical records, not current copy/paste setup: APIs, defaults and recommended flows in Steps 4–10 and Appendix D override them. Do not copy legacy GAID whitelists, plaintext `redeemVip(...)` validators, built-in consent dialogs or old logger patterns into a new partner app. Examples mentioning `README.md`, `MIGRATION.md`, `doc/architecture.md` or an old package version describe files/releases that are not part of the one-file handoff; ignore those pointers unless the SDK owner supplies the matching release material separately.

### E.1 — 1.0.20 → 1.0.21 → 1.0.22 → 1.0.23

**No breaking changes.** Bump the version and `flutter pub get` — nothing else is
required. (Heads-up: 1.0.21/1.0.22 are documented but were never published to
pub.dev; the public line jumped 1.0.20 → 1.0.23, which carries all the changes
below.)

**1.0.21** refreshes dependencies (`google_mobile_ads` → `^7.0.0`,
`flutter_secure_storage` → `^10.0.0`, `applovin_max` → `^4.6.4`) and drops the
deprecated `encryptedSharedPreferences` AndroidOptions flag (flutter_secure_storage
10 auto-migrates). No public-API change.

**1.0.22** adds three opt-in knobs (all default to the pre-1.0.22 behaviour):
- `VipManager.addVip` / `redeemVip` gained a `stack` flag. With `stack: true` the
  grant **accumulates onto the latest expiry across all active entries** (global
  stacking) instead of the default latest-expiry-wins replacement.
- `AdConfig.maxVipStackDuration` (default `null` = uncapped) clamps the total
  stacked window to `now + maxVipStackDuration`.
- `AdManager().showRewardedAd` gained `bypassVipGuard` (default `false`): a VIP
  member can voluntarily watch a **real** rewarded ad. The slot is loaded on
  demand behind a blocking dialog; tune the wait with `onDemandLoadTimeout`
  (default 15 s).

**1.0.23** is automatic (no action): the App Open ad now **skips while any dialog
or modal is on top** (`AdScreenRouteLogger.isDialogOnTop` + `AdLoadingDialog.isShowing`),
and the `_retryRefillAds` periodic scan bails early for VIP members.

### E.2 — 1.0.18 → 1.0.19 → 1.0.20

**No breaking changes.** Bump the version and `flutter pub get`.

**iOS action needed (1.0.19):** to use App Tracking Transparency,
1. Add `NSUserTrackingUsageDescription` to `ios/Runner/Info.plist`.
2. In your splash (after the first frame, **before** `requestUmpConsent` and
   `initialize`), call:
   ```dart
   final att = await AdManager().requestAtt(); // no-op on Android, never throws
   ```
   `requestAtt()` returns `AttResult { status, idfa, allowsTracking }`. It is
   decoupled from the GDPR consent flag — the native SDKs read ATT directly.

Also in 1.0.19: the iOS App-Open watchdog fix and AppLovin reload-after-display-fail
fix are automatic (no action). The rewarded-ad reward is now granted **only** when
a rewarded ad completes (`earned == true`) — if your code relied on an
interstitial-as-reward fallback, remove it.

**1.0.20** is example-only (no library change).

### E.3 — 1.0.15 → 1.0.16

**Documentation-only release.** No runtime code changes. Upgrading is a one-line version bump:

```diff
 dependencies:
-  applovin_admob_sdk: ^1.0.15
+  applovin_admob_sdk: ^1.0.16
```

```bash
flutter pub get
```

That is the entire upgrade. Public API surface and bundled assets are byte-for-byte identical to 1.0.15.

**What changed:**

- `README.md` — full English rewrite, restructured into 13 sections with copy-paste quick start
- `MIGRATION.md` (now this appendix) — full English rewrite
- `doc/architecture.md` — full English rewrite, deeper coverage of the 1.0.15 changes
- `CHANGELOG.md` — added 1.0.16 entry

If you previously copy-pasted snippets from the old README in your own internal documentation, you may want to refresh from the new version. Otherwise nothing to do.

---

### E.4 — Historical: 1.0.14 → 1.0.15 (not current guidance)

**No breaking changes.** All public API in 1.0.14 continues to compile and behave the same way in 1.0.15. The new features are opt-in and the new defaults are designed to be conservative.

**Step 1 — Bump the dependency**

In your app's `pubspec.yaml`:

```diff
 dependencies:
-  applovin_admob_sdk: ^1.0.14
+  applovin_admob_sdk: ^1.0.16
```

Then:

```bash
flutter pub get
```

**Step 2 — Audit your AndroidManifest.xml**

If your `MainActivity` declaration contains `android:taskAffinity=""`, **remove it**. This is the most important change in this upgrade.

```diff
 <activity
     android:name=".MainActivity"
     android:exported="true"
     android:launchMode="singleTop"
-    android:taskAffinity=""
     android:theme="@style/LaunchTheme"
     ...>
```

**Why this matters**: AppLovin's `AppLovinFullscreenActivity` inherits the application's default task affinity (the package name). With `android:taskAffinity=""` on `MainActivity`, the two activities live in different Android tasks. When the user presses HOME during an ad and reopens the app, then dismisses the ad, Android cannot find a previous activity to return to and drops the user to the launcher. Users perceive this as a crash even though the process is still alive.

This bug was masked in 1.0.14 because few users actually backgrounded mid-ad. We added detailed lifecycle logging in 1.0.15 that surfaced the issue in our QA, and the fix is removing this one attribute.

If you do not have `android:taskAffinity=""`, you have nothing to do for this step.

**Step 3 — Verify nothing regressed**

Run your app, navigate to a screen that shows an interstitial, and:

1. Tap "Show ad"
2. Watch the ad fully (do not press HOME)
3. Tap the ad's close (×) button

The app should return to your screen seamlessly. If it does, you are done.

If you want to also verify the new background/foreground robustness:

1. Tap "Show ad"
2. Press HOME button (background the app while ad is showing)
3. Wait 30+ seconds
4. Reopen the app via launcher
5. Tap (×) to dismiss the ad

The app should return to your screen, not the launcher. If it drops you to the launcher, recheck Step 2 above.

**Step 4 (optional) — Adopt new features**

The following are opt-in and disabled by default for backwards compatibility, except where noted:

*Historical built-in consent dialog — removed in current releases.* Older versions described a plain Allow/Reject sheet (`autoShowConsentDialog`, `consentDialogStrings`, and related fields). Do not carry that flow forward as a CMP. Current integration uses Google UMP (`autoRequestUmpConsent: true` by default) or a partner-approved CMP wired with `setConsent`; see Step 8 and README → Consent & compliance.

*First-install VIP grace (SDK default ON, partner opt-in by policy).* This historical release default grants 30 seconds in debug and 24 hours in release. For a partner integration, set `firstInstallVipGrace: FirstInstallVipGrace.disabled` unless the entitlement is explicitly approved; see Step 9 for the Android backup/privacy decision.

To customize:

```dart
AdConfig(
  // Force 12 hours in both modes
  firstInstallVipGrace: const FirstInstallVipGrace(Duration(hours: 12)),
)

// Or disable entirely
AdConfig(
  firstInstallVipGrace: FirstInstallVipGrace.disabled,
)
```

*Google UMP wrapper (opt-in).* If your app targets EEA users, you must integrate Google's UMP form. The SDK now wraps the API:

```dart
// In your splash, BEFORE AdManager().initialize:
final result = await AdManager().requestUmpConsent(
  testMode: kDebugMode,
  debugGeography: kDebugMode ? DebugGeography.debugGeographyEea : null,
);

if (!result.canRequestAds) {
  // User did not consent. Skip ad init or init in non-personalized mode.
  return;
}

// Continue with AdManager().initialize(...) as normal
```

This requires no extra dependency since `google_mobile_ads` 6.x ships UMP support.

*Smart App-Open timeout (default ON).* The fixed 10-second timeout has been replaced with a lifecycle-aware polling timeout (5-second tick, 90-second hard cap). **No code change required.** This eliminates false-positive force-dismisses when users click an ad and are sent to a browser for 20+ seconds.

*Slot-state dismiss watcher (default ON).* The SDK now records the dismiss timestamp from slot-state transitions instead of adapter callbacks. **No code change required.** This fixes a subtle bug where the rewarded ad's onDone callback fired at reward-earned time (not dismiss time), causing the resume-guard window to leak through and an app-open ad to show right after the rewarded.

---

### E.5 — Historical: 1.x → 2.x (migration record, not current integration sample)

The examples in this historical section show the API surface available during 1.x → 2.x. Do not copy legacy GAID, `redeemVip` plaintext-validator, or logger patterns into a new partner app. For current integrations use the selected release's API instructions above (signed VIP promotions where VIP is approved).

The 2.x series was mostly source-compatible with 1.x. Existing call sites compile and behave the same; old methods that no longer fit the architecture are deprecated rather than removed (will be removed in 3.0).

**1. Update the import.** The 1.x package exposed two identical entry points; 2.x keeps only one:

```diff
- import 'package:applovin_admob_sdk/ad_sdk.dart';
+ import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
```

**2. Logger configuration.**

```diff
- SafeLogger.setEnabled(true);
+ // Configured automatically via AdConfig.logLevel — no manual call needed.
```

The new logger supports four levels with lazy interpolation (zero CPU cost when the level is suppressed):

```dart
AdConfig(
  logLevel: AdLogLevel.warning,                 // verbose | warning | error | none
  logTagFilter: ['AdManager', 'AdSafety'],      // optional allow-list
  onLog: (level, tag, message) {
    Sentry.captureMessage('[$tag] $message');   // pipe into your observability stack
  },
);
```

**3. VIP API.** The 1.x VIP API used the device's GAID as the identity. The 2.x API uses arbitrary keys with explicit expiry, allowing per-user, per-purchase, or per-promo-code grants.

1.x:

```dart
AdManager().addVIPMember(['gaid-1', 'gaid-2']);
final isVip = AdManager().isVIPMember();
```

2.x / 1.0.15:

```dart
// Programmatic add — for purchase / restore flows
await AdManager().vip!.addVip(
  key: 'PURCHASED_PREMIUM_${transactionId}',
  duration: const Duration(days: 365),
);

// Cupertino dialog redeem — for user-input promo keys
await AdManager().vip!.redeemVip(
  context,
  key: userInputKey,
  duration: const Duration(days: 30),
  validator: (key) => myServer.verifyVipKey(key),
  strings: AdManager().config?.vipDialogStrings ?? const VipDialogStrings(),
);

// Check
if (AdManager().vip?.isActive ?? false) {
  // user is VIP
}

// Reactive UI
ValueListenableBuilder<bool>(
  valueListenable: AdManager().vip!.activeListenable,
  builder: (_, active, __) => active ? VipBadge() : SizedBox.shrink(),
);
```

**Auto-migration**: any existing 1.x GAID list is automatically converted to `VipEntry` records (year-2099 expiry) on the first 2.x init. You do not need to write migration code. Only entries whose GAID matches the current device's GAID are preserved as active VIP — this matches the 1.x behavior exactly. The legacy methods (`addVIPMember`, `isVIPMember`) remain available but emit `@Deprecated` warnings.

**4. Consent flags.** The 1.x SDK had no first-class consent support. 2.x introduces `AdConsent` which is forwarded to both providers:

```dart
await AdManager().setConsent(AdConsent(
  hasUserConsent: true,        // GDPR
  isAgeRestrictedUser: false,  // COPPA
  doNotSell: false,            // CCPA
));
```

The default before any `setConsent` call is `AdConsent.conservative` (all flags false), which yields non-personalized ads everywhere — a safe default that does not require user action.

**5. State machine — banner refactored.** If you previously read banner state via raw bool getters (`bannerLoaded`, `bannerHasError`, etc.), switch to the listenables:

```diff
- if (AdManager().bannerLoaded) { ... }
+ ValueListenableBuilder<bool>(
+   valueListenable: AdManager().adapter!.banner(myBannerWidgetKey).isLoaded,
+   builder: (_, loaded, __) => loaded ? BannerView() : Skeleton(),
+ );
```

`banner(Object key)` is keyed per `BannerAdWidget` instance (`myBannerWidgetKey` above stands in for that widget instance), since multiple banners can be mounted at once — it is not a bare property. In practice, prefer the simpler option below over wiring this by hand.

Or simpler: extend `AdScreen` and use `buildBanner()` which handles all this automatically.

**6. Project conventions — no `late` / `!` / `setState`.** If your host app extends `BaseStatefulState` and follows the same convention, replace `late` and force-null with nullable:

```diff
- late final FooController controller;
- @override void initState() { controller = FooController(); }
- @override Widget build(_) => Text(controller.value);

+ FooController? controller;
+ @override void initState() { controller = FooController(); }
+ @override Widget build(_) {
+   final c = controller;
+   if (c == null) return const SizedBox.shrink();
+   return Text(c.value);
+ }
```

This is a project policy, not an SDK requirement. The SDK itself follows it but does not enforce it on host apps.

**7. 2.0.0 breaking changes (defaults changed).** Three defaults changed in 2.0.0. Existing code still compiles — nothing was removed — but behavior differs from 1.x if you relied on the old default.

`AdConfig.autoRequestUmpConsent`: `false` → `true`. 2.0.0+ runs UMP's consent flow automatically inside `initialize()` unless you opt out:

```diff
  AdConfig(
+   autoRequestUmpConsent: false, // restore the 1.x behavior — you call
+                                 // requestUmpConsent() yourself
  );
```

If your splash already calls `requestUmpConsent()` manually and you didn't set this flag, 2.0.0 now runs consent **twice** on cold start (once automatically, once from your call) — set `autoRequestUmpConsent: false` to avoid the duplicate, or delete your manual call to use the new automatic flow.

Signed VIP key format: AVP1 → AVP2 by default. `tool/vip_mint.dart` mints `AVP2.<payload>.<signature>` keys by default now (was `AVP1` before). `verifySignedVipKey` still accepts both formats — **already-issued AVP1 keys keep working**, this only affects newly-minted keys. Pass `--v1` to `vip_mint.dart` if you specifically need the old format (no expiry, no bundle-id binding — AVP2 added both).

`AdConfig.maxVipStackDuration`: `null` (uncapped) → `Duration(days: 90)`. If you use `stack: true` on `addVip`/`redeemVip` (see E.1 above) and relied on unlimited stacking, set it back explicitly:

```diff
  AdConfig(
+   maxVipStackDuration: null, // restore uncapped stacking
  );
```

---


## Appendix F — Semantic-preservation record for the one-file restructure

This record lists what happened to the original guide's blocks (line ranges are from the pre-restructure revision, `HEAD` before this work). It exists so a reviewer can check that useful content was kept, moved or deliberately retired — not silently dropped. The final file is not smaller because of a size target; some sections were retired, some rewritten against the current API and some were retained verbatim in Appendix E.

| Original lines | Original content | Disposition | Where it is now / reason |
|---|---|---|---|
| 1–16 | Title and "how to use" prose, manual-user mapping | Rewritten | Opening section and Quick start; example classes referenced by name, not line numbers |
| 20, 32, 38, 74 | Maintenance, source-reading and release-check prose | Rewritten | Opening section, Section 0 and Hard rule 5; wording made self-contained |
| 50 | iOS debug build command | Rewritten | Section 0 and Step 6 use one `--simulator --debug --no-codesign` command |
| 82–111 | Feature coverage matrix (README-pointing) | Rewritten | Coverage matrix now names an in-file recipe for every family; two reference-only pointers replaced by recipes |
| 123 | "Do not re-read a file" instruction | Retired | Replaced by a rule against treating an earlier build as proof after a change |
| 136–168 | Step 1/2: read README, CHANGELOG, source | Rewritten | Step 1 retained as optional reviewer map; Step 2 audit questions now cover controller or manual splash |
| 227, 266 | Dependency and resolve-before-build notes | Rewritten | Step 4.0 and Step 6; Appendix D.1 replaces the old D.6 pointer |
| 294–396 | Manual splash flow (hard rule) | Moved | Step 4.2 keeps the controller as default and the manual flow as the fallback with its own config and `ManualSplashScreen` |
| 340–380 | Per-provider config block inside the manual splash | Moved | `lib/ad_config.dart` (AdMob) and the direct AppLovin config in Step 4.2 |
| 431–440 | `bootstrap(...)` note | Rewritten | Step 4.2 now states that bootstrap requests UMP itself and needs `autoRequestUmpConsent: false` |
| 468–493 | Banner screen sample | Rewritten | Step 4.4 complete `home_screen.dart` |
| 556, 583, 637 | Headings tagged with audit-round numbers | Rewritten | Same headings without round numbers |
| 609–612 | Native custom layout pointers | Rewritten | Step 4.9 and Step 4.17 embed Kotlin, XML, Swift, AppDelegate and AppLovin builder |
| 652, 659, 666–667 | Known-limitation prose citing audit documents | Rewritten | Step 4.11 keeps the limitation, drops pointers to unshipped audit files |
| 736–745 | Consent intro, UMP ownership, console setup, privacy options | Rewritten | Step 8 states one startup owner and gives console steps and a privacy-options snippet |
| 767, 778 | ATT call-site and COPPA heading | Rewritten | Step 8.2 and 8.3 |
| 931, 959, 1029, 1039 | VIP UI section headings and cells | Rewritten | Step 10; legacy placeholders replaced by `redeemSignedKey` guidance |
| 1062–1075 | Null-check guidance for the VIP manager | Rewritten | Step 10.5 uses the current signed redemption API |
| 1178–1207 | Optional-modules table and SSV snippet | Rewritten | Step 10.9 navigation table; SSV helper verified against the real callback names |
| 1256 | Splash readiness checklist line | Rewritten | Step 11.2 allows controller or manual |
| 1326–1359 | Appendix A and B pointers | Rewritten | Appendices A and B updated |
| 1371–1437 | Appendix C internal audit log (four dated rounds) | Retired | Internal chronology, scores and orchestration details; the partner-relevant findings (build-path collision, test APK overwrite, taskAffinity, consent ownership) are restored in Appendix D.4 |
| 1438–1454 | Appendix D heading and table of contents | Rewritten | Appendix D now covers current compatibility and troubleshooting |
| 1455–1778 | Historical 1.0.x and 1.x→2.x migration notes | Retained verbatim | Appendix E; the still-relevant behavior changes are restated as current actions in Appendix D.4 |
| 1779–1800 | 3.x compatibility, Kotlin 2.3 steps, pinning wall | Retained | Appendix D.1; Kotlin `compilerOptions` snippet present |
| 1801–1860 | Common issues | Retained and corrected | Appendix D.2; the cache-clean advice was removed because it is unsafe as a default |
| 1861–1894 | FAQ, support pointers | Rewritten | Appendix D.3; the log prefix is explained |

Review rule: if a reader needs original wording for an old release, use Appendix E. Any statement in Appendix E that conflicts with Steps 4–10 or Appendix D is historical; the later section wins.

## Appendix G — Public API coverage map (types without their own recipe)

Every exported type belongs to a recipe above or is a data/helper type. This map covers the ones not named in a recipe, so no public name is left unaccounted for. Do not import from `src/`; every name below comes from the package barrel.

| Public names | How they are used | Recipe |
|---|---|---|
| `AdAnomalyEvent`, `AdClickEvent`, `AdImpressionEvent`, `AdSkipEvent`, `AdSlot`, `AdSlotState`, `BannerListenables`, `BannerErrorSelfCollapse` | Event/state data types delivered through `AdManager().events` or read from adapter slots; observe, never construct | Steps 10.11, 4.16, 4.18 |
| `ArbitratorDecision`, `ArbitratorDecisionDetail`, `ProviderCircuitState`, `RevenueAnomalyKind`, `RevenueTypeStats`, `DailyAdOutcome`, `AdSafetyResult`, `AdSafetySnapshot` | Result/enum types returned by the monetization and safety modules | Step 4.16 |
| `AttStatus`, `requestAttIfNeeded`, `UmpConsentResult`, `requestUmpConsentFlow`, `ConsentStatus`, `TemplateType` | Low-level ATT/UMP results; prefer `AdManager().requestAtt()`, `requestUmpConsent()` and the splash flow | Steps 4.2, 8 |
| `ConsentManager`, `ConsentFallbackReason`, `ConsentProvenanceJournal`, `ConsentSettings` | Read through `AdManager().consentManager` and the provenance helpers; never construct directly | Steps 8, 10.12, 4.18 |
| `InFeedIndexCalculator`, `InlineAdControllerStatus`, `SelfCheckItem`, `SelfCheckStatus`, `TopToast` | Helpers exposed for list-index math, controller state, self-check rows and the SDK toast; used by the widgets above | Steps 4.12, 4.14, 4.18 |
| `BypassAuditTrail`, `BypassAuditEntry`, `IncidentRecorder`, `IncidentEntry`, `IncidentBundle`, `FlightRecorderEntry`, `FlightRecorderBundle`, `DisputeKit`, `ComplianceReport`, `SignedComplianceReport` | Evidence data types produced by the manager exports; the manager owns the live recorders | Step 10.12 |
| `signBypassAuditTrail`, `signConsentProvenanceJournal`, `signFlightRecorderBundle`, `signIncidentBundle`, `replayIncidentBundleJson`, `redactedConfigFingerprint` | Lower-level signing/replay helpers the `AdManager.exportSigned*` methods already call; use the manager exports unless a verifier needs the helper | Step 10.12 |
| `applyRemoteSafetyOverrides`, `resolvePlatformAdUnitId` | Pure helpers behind the remote-safety merge and per-platform ad-unit selection; no host call needed | Step 4.16 |
| `SignedVipKey`, `VipKeyException`, `VipRevocationList`, `verifySignedCrl` | VIP key/CRL data and verification types used by the signed redemption and revocation flow | Step 10.13 |

If the pinned SDK release adds an exported name that is not in this map, treat it as undocumented: record it in Step 11 as not covered and ask the SDK owner for a recipe before adopting it.

## Single-file completeness gate — SDK owner review before handoff

This gate measures **documentation coverage**, not whether a feature is safe to enable everywhere. “Optional” means the partner may decline a feature; if selected, the recipe below must be complete. Documentation completeness is separate from runtime credentials, device access, legal approval and policy review.

| Feature family | In-file destination | Documentation status | Evidence recorded for this guide revision |
|---|---|---|---|
| Android + AdMob configuration, navigator, controller splash, banner, interstitial, rewarded | Steps 4.1–4.7 | Complete; host callbacks named | Extracted snippets analyze clean; real ad display/dismissal still needs partner device evidence |
| Manual splash, ATT/UMP ownership, bootstrap | Steps 4.2, 8 | Complete; controller is default | Dart analysis only; iOS ATT and UMP UI need device |
| MREC, default Native, Rewarded Interstitial, Adaptive/in-feed, house ad | Steps 4.8–4.15 | Complete | Dart analysis; provider fill needs QA inventory |
| Custom AdMob Android/iOS native factories and AppLovin asset builder | Step 4.17 | Complete code + registration + acceptance | Android debug APK and iOS Simulator app compiled from extracted code; rendering/policy not proven |
| Placement overrides, retry, remote safety, signed flags, compatibility | Step 4.16 | Complete | Dart analysis and existing SDK tests; signed-flag sample payload intentionally absent |
| Arbitrator, fill monitors, cohort/provider choice, waterfall, failover, self-healing, journey, digital twin, revenue ledger/anomaly, diagnostics | Step 4.16 | One recipe per public family; CohortOptimizer limit stated | Dart analysis and closest SDK tests; real provider metrics need device runs |
| QA scenario/fake adapter, custom-provider boundary, runtime controls, QA panel, consent preview | Step 4.18 | Complete; no production adapter injection exists | Two guide tests plus fake-extension test pass; native behavior separate |
| VIP trial/promotions/revocation/operator CLI and legacy AVP1 | Steps 9, 10, 10.13, D.4 | Complete; backend/billing outside SDK | Analysis plus existing tests; Android replay limits remain |
| SDK-scoped erasure, events, diagnostics, evidence, flight recorder, provenance, signed exports, verifier CLI | Steps 10.10–10.12 | Complete; flight recorder stop limit stated | Dart analysis and existing verifier tests; privacy/legal approval separate |
| Existing-app upgrade checks | Appendix D.4 | Retained and rewritten | Source-checked statements; test against real legacy data before upgrade |

Unresolved runtime/approval items are never “documentation complete”: production ad IDs, AppLovin test units, UMP messages, device rendering, dismiss/reward behavior, privacy review, backend verification and legal approval must be recorded in Step 11 evidence.

A compile or analyze check covers API/syntax only. It does not establish production policy compliance, native ad dismissal, all regional consent behavior, rendered viewability or absence of memory leaks. Record those as tested or blocked per Step 11, never inferred from this checklist.
