# Prompt Template: Integrating `applovin_admob_sdk` into a Flutter Project

## How to use this document

**This is a step-by-step integration prompt for an AI coding agent, and a detailed reference for a junior engineer.** For AI-assisted use, start the agent in the consuming Flutter project and provide this complete file. It should fill Section 0 from partner-approved values, ask before unresolved decisions, then follow Steps 1–12 in order. Steps 9–10 are conditional on approved VIP scope; provider-specific native setup is conditional on the selected provider/platform. Review each change and recorded test result before handoff.

**Manual/junior-developer use:** read `packages/ad_sdk/README.md` → Quick start once for the minimal working integration, then follow Steps 0–12 here in order. Fill Section 0 before editing; Step 2 records current state; Step 3 records the plan; Steps 4–10 make only approved changes; Steps 11–12 collect evidence and handoff. Skip only the explicitly conditional steps whose feature is out of scope, and record that decision in `<PROJECT_PATH>/doc/AD.MD`.

**Example conventions:** GetX, `BaseStatefulState`, `SafeLogger`, and `.tr` appear in historical examples from one host app; they are not SDK requirements. Keep the partner app's existing state management, navigation, localization, and logging. The SDK-specific constraints are called out in each step (navigator setup, splash event ordering, ad safety, consent-before-provider initialization, and optional VIP behavior).

> **Maintenance note:** this file is the complete, self-contained handoff given to a partner engineering team integrating this SDK. Whenever the SDK version, ad unit conventions, native config requirements, splash lifecycle, VIP flow, or consent flow changes, update this file at the same time.
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
> 6. **Logging**: wire `AdConfig.onLog` to the partner's approved logger and apply its retention/access policy. Do not log ad identifiers, consent strings, user-entered VIP codes, or other personal data unless the partner's privacy/security review explicitly approves the fields and purpose. (One reference implementation names its logger `SafeLogger` and prefixes every line with a project tag, e.g. `roy93~` — that's just an example from one integration, not a requirement; use whatever logger convention your project already has.)

---

## 0. Context — fill in before running

Read the SDK source before starting. In this repository, SDK root is `packages/ad_sdk/`; if integrating a consuming app from a separate checkout, read the installed package under `~/.pub-cache/hosted/pub.dev/applovin_admob_sdk-<version>/` and replace monorepo-relative paths below with that package's corresponding README/CHANGELOG/example paths.

| Field | Value |
|---|---|
| Current project (cwd, absolute path) | `<PROJECT_PATH>` |
| Dart package name (from `pubspec.yaml: name`) | `<DART_PACKAGE_NAME>` |
| Current state management | `<existing framework/pattern, or none>` |
| Default locale | `<vi_VN \| en_US \| ...>` (default to whatever the project already targets) |
| `applovin_admob_sdk` version | `<LATEST_STABLE_VERSION>` — check the published package metadata on pub.dev, pin that version in `pubspec.yaml`, then read that exact version's README/CHANGELOG before integration. `flutter pub outdated` is only a dependency report; it does not replace checking the latest published release. |
| Local library reference (if monorepo) | `packages/ad_sdk/` |
| Library's own spec files | `packages/ad_sdk/README.md` (Quick start + API) + `packages/ad_sdk/CHANGELOG.md` (feature history) + this file's Appendix D (migration guide) |
| Sample app | `packages/ad_sdk/example/lib/main.dart` (demo pages, one page per feature) |
| Debug build target | `flutter build apk --debug` (Android) + `flutter build ios --debug --no-codesign` (iOS, if targeting iOS) — both must succeed |
| Release build target | `flutter build apk --release --analyze-size` (Android); compare against the partner's approved size budget/baseline, if one exists |
| Primary provider (active at runtime) | `<ask partner which provider is approved and configured: AdMob or AppLovin MAX>` |
| Alternate provider | `<optional; provider is selected at initialization, not switched automatically during a session>` |
| AppLovin SDK key | `<only if AppLovin is selected; store in CI/build secret and provide as `--dart-define=APPLOVIN_SDK_KEY=...`; embedded in binary at build>` (86 chars, from `dash.applovin.com → Account → Keys → SDK Key`) |
| AppLovin ad-unit IDs (each enabled format/platform) | `<required only when AppLovin is selected; keep Android/iOS units separate>` |
| AdMob `APPLICATION_ID` | `<required by the bundled google_mobile_ads/UMP setup even when AppLovin is the active provider; use partner app ID, or Google test app ID for a test-only app>` |
| AdMob ad-unit IDs (each enabled format/platform) | `<required only if AdMob is selected; use platform-specific production IDs in release and test IDs only in test builds>` |
| AppLovin MREC/native IDs | `<per platform, only if those formats are selected; custom native builder is optional>` |
| AdMob rewarded-interstitial IDs | `<separate Android/iOS AdMob units, only if Rewarded Interstitial is selected>` |
| AdMob MREC/native IDs | `<per platform, only if selected; custom NativeAdFactory is separate Android/iOS host work>` |
| Privacy Policy URL | `<partner-approved privacy policy URL if required by enabled providers/regions or VIP UI>` |
| Splash hard cap (seconds) | `<ask the user, default 8>` (must match `AdConfig.splashMaxDuration`) |
| First-install VIP grace | `<default is 24h in release; partner integrations should use disabled unless explicitly approved>` |
| VIP feature | `<enabled only if product requires it; otherwise skip VIP UI/key setup>` |
| VIP signing public key | `<if VIP is enabled: embed the Ed25519 public key only; keep the private signing key in an approved secret manager, never in the app/repository>` |
| VIP activation | `<if VIP is enabled: use redeemSignedKey or VipRedeemScreen; activation requires network, VIP works offline after activation>` |

**Hard rules for Section 0**:

1. Choose exactly the active ad provider approved for this build and configure only that provider's ad-unit IDs. The Android/iOS AdMob `APPLICATION_ID` metadata is still required by `google_mobile_ads`/UMP initialization even when AppLovin serves ads; use the partner's AdMob App ID, or Google's test App ID only for an explicitly test-only app with no production AdMob account. Never substitute a test ad-unit ID for a partner's production unit. Keep provider app IDs/ad units correct per platform.
2. For AppLovin builds, read the SDK key from the CI/build secret channel into `--dart-define=APPLOVIN_SDK_KEY=...`; the key is embedded in the app binary because the native SDK needs it at runtime. Do not commit it in Dart/Gradle source or confuse it with the VIP private signing key (which must never ship).
3. Include `gma_mediation_applovin` only when the partner uses AppLovin as an AdMob mediation network. Direct AppLovin (`AdProvider.appLovin`) and AdMob-only integrations do not need it.
4. If any required field is missing, ask for it and pause that branch. Do not infer production identifiers, bundle IDs, provider choice, privacy/legal copy, backup policy, VIP grants, or tracking purpose text. If VIP is out of scope, do not ask for VIP signing material.
5. Before editing, verify the selected release's pub.dev package metadata, README, CHANGELOG, and native constraints. Confirm the same SDK version is locked by `pubspec.lock`; do not treat `flutter pub outdated` alone as the latest-release source.

---

## Feature coverage matrix — select before Step 2

Use this table to decide what the partner app will integrate. **Core** means needed for any ad-serving integration; **select** means choose only the formats/features in approved product scope; **optional** means no code/config is needed unless the partner explicitly adopts it. The SDK exposes more APIs than most apps should wire on day one.

| Area | Scope | Host integration step | Provider/platform notes | Reference |
|---|---|---|---|---|
| Provider config + bootstrap | Core | Steps 0, 4; choose one `AdConfig.provider`, matching `AdMobConfig` or `AppLovinConfig`; set navigator key and observers; use manual init or `bootstrap`, not both | Active provider's ad units are required; bundled `google_mobile_ads`/UMP still needs app ID metadata even when AppLovin serves ads; mediation only for AdMob mediation; splash controller optional | README → Quick start, Configuration reference |
| App Open (splash/resume) | Select | Step 4; splash event listener, hard cap, `loadAppOpenAd` → buffer → show; resume is SDK-managed | Splash bypass is only for splash call; AppLovin does not expose ad freshness timestamp | README → Quick start, Pitfalls |
| Banner / MREC | Select | Step 4.4/4.8; use `AdScreen` helper or widget, register route observer, place in approved layout | MREC is fixed 300×250; `IndexedStack` tabs need explicit visibility/`active` wiring | README → Quick start, Configuration reference |
| Native | Select | Step 4.9; default layout needs Dart widget only; custom layout uses provider-specific implementation | AdMob custom layout requires host Kotlin/Swift `NativeAdFactory`; AppLovin custom builder is Flutter-side; check AdChoices | README → Native Ad (v1), example native factory files |
| Adaptive / in-feed surfaces | Select | Use `AdaptiveAdSurface` or `InFeedAdListView` when layout changes by width/list index; pass active/visibility state for offscreen routes | Test rotation, resizing, and list index changes; `IndexedStack` must also wire visibility | README → Configuration reference / Pitfalls; `AdaptiveSurfaceDemoPage`, inspect `InFeedAdListView` public API |
| Interstitial / rewarded | Select | Step 4.6–4.7; preserve existing triggers; handle shown/earned callbacks | Rewarded grants only after `earned == true`; safety gates remain on | README → Quick start, Configuration reference |
| Rewarded interstitial | Select | Step 4.10 only if partner has a natural user-initiated disclosure flow | AdMob only; AppLovin implementation is unsupported/no-op; includes disclosure API | README → API reference; example `RewardedInterstitialDemoPage` |
| Navigation / inline lifecycle | Core for mounted ads | Step 4; `adRouteObserver`, `AdScreen`, `AdScreenState`; use safe modal helper for nested navigators | `InlineAdController` and manual refresh/pause/resume are optional; overlays and `IndexedStack` need special handling | README → Quick start, Pitfalls, Configuration reference |
| Consent / privacy | Required when applicable; confirm with partner | Step 8; auto UMP or explicit manual UMP (one owner only), ATT after first frame if approved, privacy options/CCPA UI where required | UMP is default auto path; no SDK-made certified GDPR dialog; AppLovin consent writes are fire-and-forget; COPPA behavior differs | README → Consent & compliance, Known limitations |
| Safety / placements | Core defaults; overrides optional | Step 7; retain `AdSafetyParams.auto`, validate placements against network policy | Placement registry, per-placement caps, custom retry and remote safety provider are opt-in; remote backend is partner-owned | README → Configuration reference, Pitfalls |
| PlacementRegistry | Optional | Configure an `AdPlacement` ID → `PlacementSpec` map in `AdConfig.placements`; specify the exact `AdSlotType` that uses the override | Override applies only when registered format matches the actual show call; does not configure ad-unit IDs | README → Configuration reference → Centralized placement behavior overrides |
| Signed feature-flag kill switch | Advanced; only if SDK owner supplies a signed payload/public-key contract | Apply `AdManager().applySignedFeatureFlags(payload, publicKeyBase64: ...)` only with that matching public key and monotonic revision | Current recognized payload actions disable `arbitrator`, `waterfallTuner`, `journeyPrefetcher`, and `selfHealingObserver`; it is not a general remote-config service. Private signing key remains with SDK flag issuer | Public API / source `config/feature_flags.dart`; not a normal partner setup step |
| Compatibility matrix | Informational/CI-owned | Compare the partner's Flutter/platform/provider target against the SDK's declared matrix; do not change the SDK matrix from a consuming app | Matrix data is maintained with SDK release/CI review; unsupported entries must be escalated to SDK owner | Public API / source `config/compatibility_matrix.dart` |
| Test devices / release validation | Core QA task | Register test-device IDs in the right provider console/config; inspect release warnings before rollout | SDK carries an always-on QA hash fleet; AdMob test IDs/test geography must not ship as release config | README → Built-in QA test devices, Debugging |
| Connectivity / recovery | Core runtime path | Step 11; test offline → reconnect with configured formats and mounted inline widgets | SDK retries/reconnects known surfaces; host owns connectivity-specific UX and monitoring | README → Pitfalls, Configuration reference |
| Revenue / event stream | Optional | Subscribe to `AdManager().events` if analytics/finance needs impression, revenue, load, show or reward events | SDK emits typed events; analytics destination, retention, deduplication are host-owned | README → Why this SDK, Public API |
| Reward SSV | Optional; backend-owned | If authoritative server reward is required, configure provider dashboard postback, pass user/custom data, verify signed callback on partner backend | SDK does not provide endpoint, signature verification service, or authoritative reward database | README → Server-Side Verification (SSV) for rewarded ads |
| VIP / first-install grace | Optional | Steps 9–10 only after product/security/privacy approval; otherwise configure grace disabled and skip UI/key work | Signed redemption requires network; offline VIP after activation; Android clear-data/reinstall replay is possible; not a paid-license boundary | README → VIP system, Known limitations |
| Consent provenance / journal | Optional; privacy-owner approval | Enable `enableConsentProvenanceJournal` only if a partner workflow needs local audit evidence; define read/export/retention controls | Journal records decisions locally; it is not legal consent by itself and must not be exported without approval | README → Consent & compliance |
| Revenue / event stream | Optional | Subscribe to `AdManager().events` if analytics/finance needs impression, revenue, load, show or reward events | SDK emits typed events; analytics destination, retention, deduplication are host-owned | README → Why this SDK, Public API |
| Monetization Arbitrator | Optional | Enable only after product/monetization approval; configure formats/placements and act on emitted recommendations | Opt-in; does not silently change providers during a session | README → Monetization Arbitrator |
| Fill-rate / baseline monitors | Optional | Configure sample window/thresholds; decide who receives alerts and what response is allowed | Opt-in observers; avoid collecting more analytics than approved | README → Fill-rate monitor, Other advanced opt-in modules |
| Waterfall / cohort / failover advice | Optional advanced | Enable only a named experiment or operations owner; document sample size, provider assignment, rollback and whether requests create real traffic | Advice/recommendations are not automatic live failover; session exploration can make real provider requests | README → Other advanced opt-in modules |
| Prefetch / journey optimisation | Optional advanced | Add only when app navigation model and consent state are understood; review which slots can be prefetched on each route | Can create requests before a visible placement; validate partner/network policy and consent gates | README → Other advanced opt-in modules |
| Diagnostics / compliance / flight recorder | Optional; owner-controlled | Use debug self-check for integration; enable recorders/export only with owner-approved fields, retention, access and transfer procedure | Self-check can request real ads; recorder/compliance reports may contain operational identifiers; no data is uploaded automatically | README → Diagnostics & integration self-check, Consent & compliance |
| SDK data erasure | Optional; privacy/deletion flow | Call `AdManager().clearSdkData(scope:, ...)` only from an approved account/privacy deletion workflow; choose scope and require explicit confirmation before entitlement erasure | Do not call broad preference clears; verify what gets erased and what entitlement data remains | README → Consent & compliance / Public API |
| ScenarioRunner / fake adapter | QA-only | Use `ScenarioRunner` + `FakeAdProviderAdapter` in tests or an internal QA harness to script provider outcomes/events | Not production ad serving; do not use fake adapter as release provider | README → Public API; `example/integration_test/` |
| Custom provider adapter | Advanced/testing only | Implement exported adapter contract only if partner owns another provider or test harness | Not needed for normal AdMob/AppLovin integration; review adapter lifecycle and API golden first | README → Public API; `lib/src/core/ad_provider_adapter.dart` |

Record selected rows and explicit exclusions in `<PROJECT_PATH>/doc/AD.MD` before Step 2. For every selected row, identify owner screen/file, trigger, provider, platforms, required identifiers/native files, and a verification case. Do not add optional modules merely because they appear in the public API.

## Forbidden (applies to every project)

Items marked partner approval below are release gates, not optional documentation suggestions. Never infer a provider, VIP entitlement, backup policy, or consent policy from the sample app.

- Adding a new ad slot beyond the slots that already exist in the current code.
- Refactoring code unrelated to the ad integration.
- Bumping or downgrading the SDK version outside the range settled in Section 0.
- Changing `AdConfig.provider` without partner approval. Select only a provider the partner has configured and approved; the SDK does not perform silent in-session provider failover.
- Re-reading the same file more than once for "double checking" — review the result you already have; don't re-read.
- Adding a new interstitial trigger (e.g. "show after every action X") if the existing code doesn't already do that.
- Filling an ad ID with a test ID or placeholder when the user already has a production ID — you must ask the user instead.
- Bypassing `AdSafetyParams.auto` anywhere except the one sanctioned spot: the splash App Open ad (`bypassSafety: true`).
- Re-implementing first-install VIP grace in app code. If product and security owners approve VIP grace, configure the SDK's `firstInstallVipGrace` explicitly; otherwise use `FirstInstallVipGrace.disabled`. Never silently enable a free entitlement in a partner app.
- Showing an App Open Ad **directly on a bare splash screen** (this violates AdMob's "Disallowed interstitial implementations" policy) — it must go through the flow `loadAppOpenAd → AdLoadingDialog.showAdBuffer → showAppOpenAd(bypassSafety: true)`.
- Subscribing to `WidgetsBindingObserver` lifecycle yourself to show App Open on resume — the SDK already hooks this; double-subscribing means double-showing.
- Adding an Android/iOS permission beyond the whitelist (see Step 2 + Step 11), except for an ad-related permission with a clear justification (e.g. `ACCESS_WIFI_STATE` for AppLovin GeoTargeting). Any non-ad-related permission → ask the user first.
- Introducing lifecycle leaks, unsafe nullable-state access, or a parallel state-management framework solely to satisfy this template. Existing host conventions such as `setState`, `late`, or a chosen framework are not prohibited; review changed code for actual lifecycle/nullability bugs instead of blanket grep bans.
- Adding new user-facing consent/disclosure strings without using the host app's existing localization mechanism.

---

## Step 1 — Read the reference library

- `ls -R packages/ad_sdk/` (if you have the monorepo) or `~/.pub-cache/hosted/pub.dev/applovin_admob_sdk-<VERSION>/` (if hosted).
- Fetch `https://pub.dev/api/packages/applovin_admob_sdk` to verify the latest stable version and update Section 0 if needed.
- Read `packages/ad_sdk/README.md` (Quick start + Configuration reference + Public API). Pay particular attention to these call sites:
  - Bootstrap: `AdManager().setNavigatorKey(key)`, `adRouteObserver`, `AdScreenRouteLogger()`, `SimpleEventBus().listen`, `AdManager().initialize(config:, onComplete:)`.
  - Splash flow: `markSplashActive` / `markSplashInactive` / `incrementSplashCount` / `countInitSplashScreen`, `loadAppOpenAd`, `AdLoadingDialog.showAdBuffer`, `showAppOpenAd(bypassSafety: true)`.
  - Per-screen: `class XxxScreen extends AdScreen` → `class _XxxState extends AdScreenState<XxxScreen>` gives you `buildBanner()`, `showInterstitialAd(onDone:)`, `showRewardedAd(onEarnedReward:)`.
  - VIP (only if the product needs it): `AdManager().vip` is nullable. For promotions, use `redeemSignedKey` or `VipRedeemScreen` with the public key; activation requires network and VIP works offline after activation. Never place the private key or a plaintext/Base64 key whitelist in the app. `addVip` is for trusted purchase/reward flows, not validating user-entered promo codes. Check this SDK version's README/CHANGELOG for stacking, revoke, and expiry APIs.
  - Rewarded while already VIP: `showRewardedAd(bypassVipGuard: true, ...)` lets a VIP user **voluntarily** watch a real rewarded ad to extend their window (the SDK loads the ad on-demand and shows a loading dialog; default `false` keeps the surface suppressed). Configurable `onDemandLoadTimeout` (default 15s). `showRewardedAd` is already **re-entrancy-safe** (blocks double-tap while loading/showing). (Available in current SDK releases — check `CHANGELOG.md` for the exact version.)
  - Consent: `AdManager().requestUmpConsent(testMode:, debugGeography:, testIdentifiers:)` (Google UMP, a certified CMP, wired by default via `AdConfig.autoRequestUmpConsent: true`) + `CcpaOptOutToggle` for the separate CCPA "Do Not Sell" axis. No built-in GDPR consent dialog — removed round 44 (was not a certified CMP).
  - Safety: `AdSafetyParams.auto` (default, do NOT override).
  - Logger pipe: `AdConfig.onLog: (level, tag, msg) { ... }`.
- Read `packages/ad_sdk/CHANGELOG.md` — the "What's new" section for the version you're using, to learn about newer features (UMP wrapper, smart App-Open timeout, slot-state dismiss watcher, first-install grace, the anti-bypass guard if present in that version, the taskAffinity pitfall).
- Use the README chapter matching selected feature; don't ask junior integrators to infer feature steps from internal architecture docs:
  - Setup/provider/bootstrap/formats → `README.md` → [Quick start](../README.md#quick-start), [Configuration reference](../README.md#configuration-reference), [Pitfalls](../README.md#pitfalls)
  - Consent/UMP/ATT/CCPA/COPPA/privacy options → [Consent & compliance](../README.md#consent--compliance)
  - VIP/signed keys/CRL/Android limits → [VIP system](../README.md#vip-system), [Known limitations](../README.md#known-limitations--read-before-adopting)
  - Rewarded server verification → [Server-Side Verification](../README.md#server-side-verification-ssv-for-rewarded-ads)
  - Native ad layouts/factories → [Native Ad (v1)](../README.md#native-ad-v1)
  - Arbitrator/fill-rate/waterfall/cohort/failover advice → [Monetization Arbitrator](../README.md#monetization-arbitrator-opt-in), [Fill-rate monitor](../README.md#fill-rate-monitor-opt-in), [Other advanced opt-in modules](../README.md#other-advanced-opt-in-modules-brief)
  - Diagnostics/self-check/exports → [Diagnostics & integration self-check](../README.md#diagnostics--integration-self-check)
- For runnable examples, open only the matching class in `example/lib/main.dart`; the file is intentionally long so pub.dev can display a complete example entry point. Current examples include: ad formats/lifecycle (`BannerDemoPage`, `BannerAdaptiveSizingDemoPage`, `MrecDemoPage`, `NativeDemoPage`, `InterstitialDemoPage`, `RewardedDemoPage`, `RewardedInterstitialDemoPage`, `AppOpenDemoPage`, `AdaptiveSurfaceDemoPage`, `InlineAdControllerDemoPage`); consent (`ConsentDemoPage`, `CcpaToggleDemoPage`, `I18nPresetDemoPage`); VIP and SDK data (`VipDemoPage`, `ClearSdkDataDemoPage`); controls (`SafetyDemoPage`, `PlacementThrottleDemoPage`, `RemoteSafetyDemoPage`, `ReadinessControllerDemoPage`); operations (`ComplianceDemoPage`, `DiagnosticsDemoPage`, `EventsDemoPage`, `LogViewerDemoPage`, `RevenueDemoPage`, `StatePanelDemoPage`, `TestDeviceHashDemoPage`, `CustomOverlayDemoPage`). Search the current file for each class before using it; this navigation list is not a substitute for the public API reference.

**Required output from Step 1**: return (a) a one-line summary of the installed package version, (b) one row per feature-family in the matrix stating public entry point, host action, and optional/provider limitations, and (c) a clear list of behaviors the SDK owns automatically versus behaviors the host must implement. Do not use a 10-line cap if that would omit an exported feature family; link to the exact README chapter for details.

## Step 2 — Audit the current state of the project

Answer 8 questions (yes/no + evidence as `file:line`):

1. Is `applovin_admob_sdk` already present? Record the current package/version and existing ad integrations; do not remove a provider or old implementation until every caller and intended migration scope is identified.
2. What does `main.dart` call during startup? Record the navigator key, `navigatorObservers`, and current splash/init entry point with `file:line` evidence.
3. Does splash call `AdManager().initialize` rather than `main()`? Is `SimpleEventBus().listen` registered before init? Is there a hard-cap timer and hot-restart guard (`countInitSplashScreen > 1`)?
4. Which screens show each currently used format, what triggers them, and which SDK API is used? Record existing `AdScreen`/`AdScreenState` usage; do not add ad placements or change triggers during migration.
5. **Does partner-approved scope include VIP or first-install grace?** If not, record both as disabled and skip the corresponding implementation/UI steps. If yes, record approved grant types, activation policy, duration, and Android backup/privacy decision before coding.
6. Which state-management, navigation, localization, and logging systems does the host app already use? Keep these; do not add GetX or create a new framework layer solely for this integration.
7. Which existing base widget/state or lifecycle helpers can the integration reuse? Reuse if useful; do not create `BaseStatefulState` or other project-wide abstractions merely to match this template.
8. Which logger does the host app use, and what fields/retention are approved? Wire `AdConfig.onLog` to that logger without logging raw consent strings, user-entered VIP codes, or personal data.

## Step 3 — Write the integration plan into `<PROJECT_PATH>/doc/AD.MD`

Target file: `<PROJECT_PATH>/doc/AD.MD` (create it if it doesn't exist yet).

It must contain these sections:

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

**(a) `pubspec.yaml`** — pin one released SDK version selected in Section 0:

```yaml
dependencies:
  applovin_admob_sdk: <PINNED_STABLE_VERSION>
  # Only for AppLovin served through AdMob mediation (not direct AppLovin):
  # gma_mediation_applovin: <PARTNER_APPROVED_COMPATIBLE_VERSION>
```

Then run:

```bash
flutter pub get
```

Do not separately add `google_mobile_ads`, `applovin_max`, `app_tracking_transparency`, or UI/state-management packages just because the SDK/example uses them transitively. Add `gma_mediation_applovin` only for the mediation branch. Current source supports Flutter `>=3.38.1`, Dart `>=3.10.0`, and pins `google_mobile_ads >=9.0.0 <9.1.0`; verify the selected published release's constraints before using these values.

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

**(c) iOS identifiers and deployment target** — merge into `ios/Runner/Info.plist`:

```xml
<key>GADApplicationIdentifier</key>
<string><ADMOB_APPLICATION_ID_OR_TEST_ONLY_ID></string>
<!-- Include only when AppLovin is enabled: -->
<key>AppLovinSdkKey</key>
<string><APPLOVIN_SDK_KEY></string>
<!-- Include only when partner approves an ATT prompt: -->
<key>NSUserTrackingUsageDescription</key>
<string><PARTNER_APPROVED_LOCALIZED_TRACKING_PURPOSE></string>
```

Set `platform :ios, '13.0'` in the existing `ios/Podfile`, then run `(cd ios && pod install)`. If iOS is a target, obtain current `SKAdNetworkItems` from each enabled provider/mediation partner's official source and merge their identifiers with existing entries; do not paste a stale fixed-count list. If AppLovin is not enabled, do not add an AppLovin key solely from this example.

**(d) Resolve before proceeding:** run `flutter pub get`; if mediation or native dependency versions changed, run `pod install` and build both Android and iOS Simulator before proceeding. A successful Dart dependency solve or CocoaPods resolve alone is not a successful native build; see Step 6 and Appendix D.6.

### 4.1 — Bootstrap order in `main.dart` (do NOT reorder)

```dart
import 'package:flutter/material.dart';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

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

### 4.2 — Splash flow (hard rule, hot-restart guard is mandatory)

```dart
// Enable only after the partner's iOS tracking/privacy review approves ATT.
const bool kRequestAtt = false;

class _SplashScreenState extends State<SplashScreen> {
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

    // 4.2.2 — Hard cap timer (default 8s, must match AdConfig.splashMaxDuration)
    _hardCap = Timer(const Duration(seconds: 8), _goHome);

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
      if (kRequestAtt) {
        final att = await AdManager().requestAtt();
        debugPrint('ATT status=${att.status.name}');
      }
      // Build exactly one of these provider configs from Section 0.
      // AppLovin example (keep separate platform IDs):
      const config = AdConfig(
        provider: AdProvider.appLovin,
        appLovin: AppLovinConfig(
          sdkKey: const String.fromEnvironment('APPLOVIN_SDK_KEY'),
          bannerId: '<APPLOVIN_ANDROID_BANNER_ID>',
          interstitialId: '<APPLOVIN_ANDROID_INTERSTITIAL_ID>',
          appOpenId: '<APPLOVIN_ANDROID_APP_OPEN_ID>',
          rewardedId: '<APPLOVIN_ANDROID_REWARDED_ID>',
          iosBannerId: '<APPLOVIN_IOS_BANNER_ID>',
          iosInterstitialId: '<APPLOVIN_IOS_INTERSTITIAL_ID>',
          iosAppOpenId: '<APPLOVIN_IOS_APP_OPEN_ID>',
          iosRewardedId: '<APPLOVIN_IOS_REWARDED_ID>',
          // If selected, set mrecId/nativeId and iosMrecId/iosNativeId here.
        ),
        firstInstallVipGrace: FirstInstallVipGrace.disabled,
        autoRequestUmpConsent: true,
        logLevel: kDebugMode ? AdLogLevel.verbose : AdLogLevel.warning,
      );

      // AdMob-only alternative (use instead of the AppLovin config above):
      // const config = AdConfig(
      //   provider: AdProvider.admob,
      //   admob: AdMobConfig(
      //     bannerId: '<ADMOB_ANDROID_BANNER_ID>',
      //     interstitialId: '<ADMOB_ANDROID_INTERSTITIAL_ID>',
      //     appOpenId: '<ADMOB_ANDROID_APP_OPEN_ID>',
      //     rewardedId: '<ADMOB_ANDROID_REWARDED_ID>',
      //     iosBannerId: '<ADMOB_IOS_BANNER_ID>',
      //     iosInterstitialId: '<ADMOB_IOS_INTERSTITIAL_ID>',
      //     iosAppOpenId: '<ADMOB_IOS_APP_OPEN_ID>',
      //     iosRewardedId: '<ADMOB_IOS_REWARDED_ID>',
      //     // Add only for selected formats: mrecId/nativeId and platform overrides.
      //     // rewardedInterstitialId is a separate AdMob unit (AdMob only).
      //     rewardedInterstitialId: '<ADMOB_ANDROID_REWARDED_INTERSTITIAL_ID>',
      //     iosRewardedInterstitialId: '<ADMOB_IOS_REWARDED_INTERSTITIAL_ID>',
      //   ),
      //   firstInstallVipGrace: FirstInstallVipGrace.disabled,
      //   autoRequestUmpConsent: true,
      // );

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
        if (!mounted) return _goHome();
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
  void dispose() {
    _hardCap?.cancel();
    final onInitEvent = _onInitEvent;
    if (onInitEvent != null) SimpleEventBus().remove(onInitEvent);
    super.dispose();
  }
}
```

**Note on 4.2.4 (informational, does not change the hard rule above):** the SDK
also ships `bootstrap(AdBootstrapOptions(config: ..., requestAtt: kRequestAtt))`, which wraps the
optional ATT request → UMP → initialize sequence into one awaited
call returning `AdBootstrapResult`. It does NOT replace the hard-cap timer /
hot-restart guard / App-Open dance mandated above — those still need writing
by hand as shown. Its `initTimeout` option (default 20s) bounds how long it
waits specifically on `initialize()`, so a wedged native init can't hang the
splash for the ~130s worst-case retry pileup `AdManager.initialize()` itself
can take. Use either `bootstrap(...)` OR the manual sequence; never call both for the same startup. With `bootstrap`, remove the manual `requestAtt()`/`initialize()` calls and read `result.initSuccess`; keep the splash hard-cap, event subscription, and App Open display logic. The manual pattern above remains available and is what most
of this document assumes.

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

```dart
class HomeScreen extends AdScreen {  // NOT StatefulWidget
  const HomeScreen({super.key});
  @override State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends AdScreenState<HomeScreen> {
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        Expanded(child: _content()),
        _buildBannerEdgeToEdge(),    // bottom + edge-to-edge wrap
      ],
    ),
  );

  // Detect edge-to-edge: if the app uses UIUtils.initEdgeToEdge() →
  // wrap with SafeArea(top: false, bottom: true) so the banner sits above the gesture nav bar.
  // If the app is NOT edge-to-edge → buildBanner() bare is fine.
  Widget _buildBannerEdgeToEdge() {
    return SafeArea(
      top: false,
      bottom: true,
      child: buildBanner(),
    );
  }
}
```

### 4.5 — App Open when returning to the foreground

The SDK already hooks `WidgetsBindingObserver`. **Do NOT** subscribe to lifecycle a second time — that causes a double-show.

As of current SDK releases: `showAppOpenAdOnResume` will not show App Open on top of a modal —
it checks `isDialogOnTop` (tracked by `AdScreenRouteLogger` counting open `PopupRoute`s) plus
`AdLoadingDialog.isShowing` before showing; if a dialog or loading buffer is currently on top, it skips.

### 4.6 — Interstitial pattern

```dart
showInterstitialAd(onDone: (shown) {
  // shown=true → ad displayed and dismissed
  // shown=false → blocked by safety / VIP / no network / slot showing
  // ALWAYS perform the existing post-action regardless.
  Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => const HistoryScreen()),
  );
});
```

Replace `HistoryScreen` with the screen your existing trigger already navigates to; keep the original trigger and destination.

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

### 4.8 — MREC pattern (audit round 27 addition — this surface exists in the SDK)

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

### 4.9 — Native ad pattern (audit round 27 addition — this surface exists in the SDK)

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

**Default vs. custom layout:** default `buildNative()`/`NativeAdWidget()` uses the provider's built-in layout and needs no native factory. If a custom AdMob layout is requested, custom factory work is required in the host app:
- Android: copy `example/android/app/src/main/kotlin/.../T228CustomNativeAdFactory.kt` and its layout XML; register the factory in `MainActivity.configureFlutterEngine`.
- iOS: copy `example/ios/Runner/T228CustomNativeAdFactory.swift`; register in `AppDelegate.didInitializeImplicitFlutterEngine`.
- Dart: set `factoryId: 't228CustomNativeAd'`; it must exactly match the native registration.

For AppLovin custom layout, use `customNativeAdBuilder` with its asset widgets; this does not use Google's native factory. See `README.md` → “Custom native ad layout” and the selected release's example files before copying, since platform templates may change.

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

### 4.11 — Known SDK limitations to design around (round-32 audit, 2026-09-02)

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
  non-route popups during a window where App Open could resume, or accept the rare overlap.
- **No automatic runtime failover between AdMob and AppLovin.** `AdConfig.provider` picks one backend per
  session (including a stable per-install A/B split via the SDK's own cohort picker) — this is fully
  runtime-configurable, no rebuild needed. But if the active provider degrades mid-session (outage, no-fill),
  the SDK does not detect that and switch to the other one; it keeps retrying the same provider. Switching
  requires the host calling `AdManager().destroy()` then `initialize()` with a different `AdConfig.provider`
  itself.
- **AppLovin consent writes cannot be confirmed as successful (round-33 audit).** `applyConsentToProviders()`
  calls `AppLovinMAX.setHasUserConsent`/`setDoNotSell` — both fire-and-forget `void` methods in the
  `applovin_max` package with no `Future` to await, unlike AdMob's `updateRequestConfiguration` which is
  properly awaited and only recorded as applied on success. If that platform-channel write silently fails
  (cold/backgrounded channel, transient native exception), AppLovin can keep serving personalised ads to a
  user who just withdrew consent, with no way for this SDK to detect it — a dependency-level gap, not
  something the Dart side alone can close. If the host app has real EEA/UK/California traffic on
  `AdProvider.appLovin`, do not treat the AppLovin branch of consent as a hard guarantee; see
  `doc/audit/audit_round33_consolidated.md` for the full trace.

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

For each enabled placement, record PASS/FAIL and `file:line` evidence. These checks do not replace provider policy review or partner legal/privacy approval.

| # | Check | How to verify |
|---|---|---|
| 1 | Banner/native/MREC never obscure controls or imitate clickable app controls | Inspect host layout on target device sizes; compare placement against current selected-network policy |
| 2 | App Open never interrupts first-use navigation unexpectedly | Verify cold-start flow `loadAppOpenAd → showAdBuffer → showAppOpenAd(bypassSafety: true)` and resume behavior; confirm hard cap reaches app when no ad is ready |
| 3 | Interstitial respects configured frequency gates | Confirm `AdSafetyParams.auto` or an explicitly approved preset; record actual caps from selected SDK version/config |
| 4 | Rewarded appears only in approved user flow and reward is granted only when earned | Inspect each enabled placement and callback; do not reward from impression/show/dismiss alone |
| 5 | Partner-approved ad/disclosure text is shown at the agreed location, if required | Get exact copy/location from partner policy/legal owner; localize using host system; do not use this template's sample text as legal advice |

Do not mark a check PASS based on reading code alone when it needs device or owner verification.

## Step 8 — Consent (UMP + iOS ATT)

No built-in GDPR consent dialog — removed in audit round 44 because it was not a
Google-certified CMP and produced no valid IAB TCF string. Use Google UMP for applicable consent requirements; handle ATT separately only when the partner's iOS tracking/measurement plan and privacy review call for it:

### 8.1 — Google UMP form (review for every selected provider/market)

By default, `autoRequestUmpConsent: true` runs Google UMP during `initialize()` before the selected ad provider initializes. In the Step 4.2 example, call `requestAtt()` after the first frame (iOS only), then call `initialize()`; do not call `requestUmpConsent()` separately as well. If the host must present UMP earlier itself, await `requestUmpConsent()` before `initialize()` and set `autoRequestUmpConsent: false` in `AdConfig`.

Before release, the partner must publish the Google UMP consent message for **each AdMob App ID** in its AdMob console. A newly created/unconfigured App ID may return `no form(s) configured`. Follow README → Consent & compliance → “AdMob Console setup” for generic per-App-ID steps; do not use `doc/UMP_SETUP.md`, which is a stale record for a retired host app and contains unrelated historical IDs.

If UMP is enabled, add a permanent privacy-options entry point in the host app's Settings/Privacy screen that calls `AdManager().showPrivacyOptions()`. Do not make it splash-only or transient. See README → Consent & compliance → Privacy Options entry point.

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
- Call `requestAtt()` in **SplashScreen postFrame, before `initialize()`** (Step 4.2.4), after app UI is visible. It is no-op on Android and does not replace Google UMP. Calling before `runApp()` prevents showing the system prompt until UI is available.
  ```dart
  final att = await AdManager().requestAtt();   // no-op on Android
  // att.status: notSupported | notDetermined | restricted | denied | authorized
  // att.idfa: String? (only when authorized); att.allowsTracking: bool
  ```
- `requestAtt()` handles this internally: non-iOS → `notSupported`; already decided before →
  returns the cached status, no re-prompt; error/missing plugin → `denied` (never throws).
- ATT does NOT touch the GDPR consent flag — native AppLovin/AdMob read ATT for IDFA on their own.
- If an iOS user picks "Ask App Not to Track", it falls back to non-personalized ads / SKAdNetwork.

### 8.3 — COPPA (`isAgeRestrictedUser`) — AppLovin/AdMob asymmetry (audit round 27 addition)

**If the project targets children (any part of the audience under the applicable age of consent), read this
before calling `setConsent`.** AdMob has a per-request COPPA flag (`tagForChildDirectedTreatment`) — setting
`isAgeRestrictedUser: true` narrows just that provider's requests. AppLovin MAX 4.x has **no runtime
child-directed API at all** — when `isAgeRestrictedUser: true` is known at `initialize()` time (persisted
from a prior session), `AppLovinAdapter` refuses to initialize entirely and every AppLovin ad surface stays
unavailable for that session. This is the SDK's intentional, stricter-by-design behavior for that provider —
do not treat it as a bug to "fix" by trying to force AppLovin to serve child-safe ads some other way.

**Known gap that needs an explicit decision from the user, not a default assumption:** on a brand-new install
with no persisted consent yet, an app that is *always* child-directed (no consent flow needed at all,
because the whole app is COPPA-scoped) will still see AppLovin attempt to initialize once on that very first
launch — there is nothing yet to gate on. If the project is *always* child-directed, ask the user whether they
want an explicit "child app" config checked ahead of the very first `initialize()` call (e.g. a build-time
flag, not something derived from consent state) so AppLovin never initializes even on install #1. Do not
silently ship the one-time gap without asking.

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

Generate the Ed25519 pair as described in `packages/ad_sdk/README.md` → “Signed VIP keys”. The private key stays with the authorized minting operator in an approved secret manager; the app receives only the public key. Example config file:

`lib/<DART_PACKAGE_NAME>/features/vip/vip_config.dart`:

```dart
abstract final class VipConfig {
  static const publicKeyBase64 = '<PARTNER_VIP_PUBLIC_KEY_BASE64>';
}
```

Do not put promo codes, key-to-duration maps, or private signing material in app config. Configure ad-provider credentials separately as shown in Section 0 and Step 4.2. See the current SDK README for the exact signed-key API and status values for the selected release.

### 10.2b — Or skip 10.3 entirely: wrap the SDK's `VipRedeemScreen` (round-37 audit — this note was a dangling forward-reference before, fixed here)

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

Replace `launchPartnerPrivacyPolicy()` with the host app's approved privacy-policy launcher. `publicKeyBase64` is required; other callbacks/localized `VipRedeemStrings` are optional. This screen handles signed promotion redemption; activation requires network. Do not wire a private signing key or plaintext promo validator. If the built-in screen meets the partner UI requirements, stop here and skip the custom UI, animation, and translation design sections below. See `packages/ad_sdk/README.md` → “Pre-built redeem screen (`VipRedeemScreen`)” for the complete current constructor.

### 10.3 — Optional custom VIP UI (only if approved and `VipRedeemScreen` does not meet host requirements)

Use this as a sequence of UI requirements only when the partner approved VIP and needs a custom screen. These details are not reasons to add a state-management, animation, or localization package: use existing host-app patterns and omit visual extras the product does not need.

| # | Optional idea | Detail |
|---|---|---|
| 1 | Status header / Hero card | Observe `vip.activeListenable` through the host app's reactive pattern after checking `vip != null`. Active state can show approved localized status/expiry; inactive state shows the host's normal free-user state. The `.tr` names in older examples are GetX-specific, not SDK API. |
| 2 | Activation date row | `'Activated: ${DateFormat('dd/MM/yyyy HH:mm').format(entry.grantedAt)}'` (hidden if free). Uses `package:intl`. The field is named `grantedAt` (SDK 1.0.18+), NOT `startedAt` |
| 3 | Expiry date row | `'Expires: ${DateFormat('dd/MM/yyyy HH:mm').format(entry.expiresAt)}'` (hidden if free) |
| 4 | Progress bar (elapsed) | `LinearProgressIndicator` with `value = (now − entry.grantedAt) / (entry.expiresAt − entry.grantedAt)`, clamped to `[0.0, 1.0]`. **3 points on the horizontal timeline**: `start = entry.grantedAt` (left edge, 0%), `end = entry.expiresAt` (right edge, 100%), `current = now` (fill position). The bar starts **empty right after activation and fills up toward expiry** (elapsed semantics — matches the user's mental model of "progression toward expiry"). Absolutely do NOT invert the formula to `remaining/total` (full → empty) — that's confusing UX. Only show this when VIP is active. **No need for `TweenAnimationBuilder`** — a per-second tick from `_now` is smooth enough (Δ ≪ 0.001%/s for a 24h+ VIP window); `TweenAnimationBuilder` would only add overhead and slow rebuilds. Edge case `total ≤ 0` (clock skew / already expired) → default to `value = 1.0` (full = expired) |
| 5 | Countdown text | Format like `12d 03h 24m 15s` — updated via `Timer.periodic(Duration(seconds: 1), ...)` in `initState`, `cancel()`'d in `dispose`. State goes through `ValueNotifier<Duration>`, never `setState` |
| 6 | Signed VIP code field (if promotions are in scope) | `TextEditingController` + `TextCapitalization.characters`; redeem with `redeemSignedKey` or the SDK screen. Handle statuses explicitly; activation requires network. Never check user-entered codes against an app-bundled plaintext/Base64 key map. |
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
| 5 | Confetti on successful activation | `package:confetti`: `ConfettiController? _confettiController;` init `duration: 1000ms`. In `dispose`: `_confettiController?.dispose()`. On successful `redeemVip` or `onEarnedReward == true` → `_confettiController?.play()` + `HapticFeedback.heavyImpact()` (Flutter built-in, no need for the `vibration` package) | After success |

Bonus (nice-to-have, not mandatory): default ripple effect for both buttons (comes with Material 3), an animated gradient background for the status header.

### 10.5 — Lifecycle checklist for custom VIP UI

Use patterns that fit the host app; the important requirement is that resources cannot outlive their owner and nullable SDK state is handled. Examples below are Dart/Flutter options, not style mandates.

- A nullable `AnimationController` is one option when initialization is conditional:
  ```dart
  // ❌ DO NOT
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
- Since `AdManager().vip` is null before SDK initialization, check it before use. Pattern matching is one option:
  ```dart
  // ❌ DO NOT
  AdManager().vip!.redeemVip(...);
  _pulseController!.repeat();
  // ✅ CORRECT (Dart 3 pattern matching)
  if (AdManager().vip case final vip?) {
    vip.redeemVip(...);
  }
  // or a local copy
  final vip = AdManager().vip;
  if (vip == null) return;
  vip.redeemVip(...);
  ```
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

Use signed AVP2 promotions, never an app-bundled plaintext/Base64 key-to-duration map. Generate the Ed25519 keypair once with `dart tool/vip_keygen.dart`; keep the 0600 private-key file with an authorized minting operator in an approved secret manager. Ship only the public key. Mint a time-limited, app-bound promotion from the package root:

```bash
dart tool/vip_mint.dart --priv-file .vip-private-key --days 30 --valid-days 14 --bundle com.example.app --kid PROMO30-001
```

Replace `com.example.app` with the exact consuming app bundle ID and choose expiry/validity per promotion policy. Do not use `--priv`; the CLI intentionally rejects private keys in argv. Never commit the private-key file or paste its contents into chat/source.

On the screen, first check that SDK initialization has completed (`AdManager().vip` is nullable), then handle all result statuses:

```dart
final vip = AdManager().vip;
if (vip == null) {
  showMessage('VIP is not ready yet');
  return;
}

final result = await vip.redeemSignedKey(
  userInput,
  publicKeyBase64: VipConfig.publicKeyBase64,
  stack: true,
);
switch (result.status) {
  case VipRedeemStatus.success:
    showMessage('VIP activated');
    break;
  case VipRedeemStatus.alreadyUsed:
    showMessage('This code was already redeemed on this device');
    break;
  case VipRedeemStatus.invalid:
    showMessage('Code invalid, expired, or for another app');
    break;
}
```

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

### 10.9 — Optional modules beyond ad surfaces

Do not implement these during core ads setup unless Step 0/3 selected them. If selected, follow the named README section, record owner/configuration, and add the corresponding test/check to the integration record:

| Module | Add it when | Host/backend work | Minimum validation | Reference |
|---|---|---|---|---|
| Revenue / `AdEvent` analytics | Partner needs impression/revenue/reward events outside provider dashboards | Subscribe once to `AdManager().events`; map only approved event fields to existing analytics, define dedupe/retention | Confirm one test impression yields expected format/provider/placement/revenue fields; confirm stream subscription is cancelled | README → Public API; `RevenueDemoPage`, `EventsDemoPage` |
| Rewarded SSV | Reward must be authoritative outside the client | Configure selected provider's dashboard callback URL/secret; backend verifies provider signature, timestamp/replay, user/custom data, then grants reward server-side | Use provider test postback; test valid, invalid-signature, replay, unknown-user cases on partner backend | README → Server-Side Verification (SSV) for rewarded ads |

For the optional SSV branch, pass a stable partner user ID (not raw PII) and optional opaque server-issued state when showing the ad:

```dart
showRewardedAd(
  ssvUserId: currentUser.rewardAccountId,
  ssvCustomData: serverIssuedRewardNonce,
  onEarnedReward: (earned) {
    if (!earned) return;
    // Update UI optimistically only. The partner backend postback is authoritative.
  },
);
```

The guide does not prescribe the partner's postback URL, signature-validation code, identity schema, database, or reward policy. Those are backend-owned; follow each network's current SSV docs and validate callback signatures/replay before crediting rewards. Never grant valuable entitlements solely from the client callback when SSV is the approved source of truth.
| Monetization Arbitrator | Partner explicitly wants SDK event-based arbitration | Enable/configure module, define eligible formats and decision owner; no automatic provider switch is implied | Feed representative test events; record recommendation and host action; compare against simple control | README → Monetization Arbitrator |
| Fill-rate / baseline monitor | Partner needs local fill or revenue alerts | Enable selected monitor and sampling window; decide alert destination/retention | Simulate fill/no-fill and verify alert thresholds/destination | README → Fill-rate monitor, Other advanced opt-in modules |
| Remote safety policy | Partner must adjust caps without app release | Implement `RemoteAdSafetyProvider` using approved remote config, validation/versioning, and safe defaults | Test valid, stale, malformed, timeout/offline values and verify local safety defaults remain active | README → Configuration reference / Other advanced opt-in modules |
| Cohort, waterfall tuning, failover advice, prefetch | A named monetization owner approved the experiment and impact | Configure one selected module, sampling/persistence/rollback; review whether prefetch or exploration sends real ad requests | Use test units where supported; record request behavior, recommendation, rollback result; never call advisory output automatic failover | README → Other advanced opt-in modules |
| Diagnostics, flight recorder, compliance export | Support/audit workflow requires local evidence | Choose fields, enable flag, retention, access and secure transfer path with privacy/security owners | Export a test artifact, verify signature/chain where applicable, redact identifiers, verify delete/retention flow | README → Diagnostics & integration self-check / Consent & compliance |

If no row was selected, record “not in scope”; do not add packages, backend endpoints, storage, network calls, or UI for these modules.

## Step 11 — Partner readiness review & update `<PROJECT_PATH>/doc/AD.MD`

Before handoff or production rollout, complete this checklist with the partner's owners. Put the completed evidence in `<PROJECT_PATH>/doc/AD.MD` (created in Step 3) under “Partner readiness”. For each test row, record: test case, device/model + OS, build mode, provider/region, expected result, observed result, log/screenshot path, and PASS/FAIL. A passing emulator build is not device compatibility evidence.

### 11.0 — Partner release gates

- [ ] Product owner approved provider, ad formats/placements, launch triggers, VIP/grace scope, and all user-facing ad disclosures; placements do not risk accidental clicks or interrupt active interaction
- [ ] Privacy/legal owner approved target markets, consent/CMP flow, ATT purpose text, age-directed behavior, privacy-policy URL, data purposes, retention, and any permitted diagnostics
- [ ] Security/privacy owner reviewed Android backup policy before any change; backup include rules are merged, not replaced, and scope is understood to include all keys in `FlutterSharedPreferences.xml`
- [ ] Tested consent granted, denied/withdrawn, unavailable/offline, app resume, and re-initialization for each enabled provider; record provider-specific limitations, including AppLovin consent writes being fire-and-forget
- [ ] Ran on real partner-target devices/OS versions, including at least one low-memory/low-end device and one current flagship per supported platform; add OEM-specific devices (Samsung, TECNO, Huawei, etc.) from the partner's launch matrix. Record device model, OS, architecture, provider, build mode, network, and outcome
- [ ] Verified cold start, splash timeout/ad success/ad unavailable, fullscreen dismiss/reward, background/resume, rotation/window resize where supported, no-network/reconnect, and VIP/consent paths that are in scope
- [ ] Release build uses production app IDs/ad unit IDs only in approved release configuration; debug/test builds use test inventory. Confirm no test geography, test IDs, verbose logs, private VIP signing key, or unapproved diagnostics are shipped
- [ ] Reviewed merged manifest permissions, exported components, backup rules, iOS privacy declarations/ATT text, SKAdNetwork configuration, and dependency lockfiles against partner policy
- [ ] Captured final analyze/test/build results and signed-off known limitations, rollback owner/path, monitoring owner, and escalation contacts



One review pass only, do NOT repeat it 3 times. Checklist:

### 11.1 — Native config

- [ ] `pubspec.yaml`: add `applovin_admob_sdk: <LATEST_STABLE>` and keep unrelated dependencies unchanged. Do not add provider plugin dependencies manually unless required by the selected integration.
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
          jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11)
      }
  }
  ```
- [ ] If AppLovin is selected, match AppLovin SDK key/platform ad-unit IDs to partner dashboard. If AdMob is selected, register correct App ID per platform in manifest/Info.plist.
- [ ] (If iOS) Podfile deployment target is at least 13.0; run `(cd ios && pod install)` and then an actual `flutter build ios --simulator --debug --no-codesign`. Successful `pod install` alone does not prove Xcode compile/link succeeds.

### 11.2 — Bootstrap

- [ ] `main.dart`: `AdManager().setNavigatorKey` before `runApp`, navigator observers complete (`adRouteObserver` + `AdScreenRouteLogger()`)
- [ ] If ATT is in scope on iOS, `AdManager().requestAtt()` is called after first frame; then `initialize()` runs. SDK auto UMP is enabled by default and runs before provider init. If host explicitly calls `requestUmpConsent()` itself, set `autoRequestUmpConsent: false` to avoid duplicate consent flow.
- [ ] Splash: `SimpleEventBus().listen` registered BEFORE `initialize`, hard-cap (default 8s), `markSplashActive/Inactive` paired correctly, **hot-restart guard `countInitSplashScreen > 1`** (mandatory), the App Open flow `loadAppOpenAd → showAdBuffer → showAppOpenAd(bypassSafety: true)` in the right order
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

Report only verified results; do not mark a gate PASS without evidence. Include:

- SDK, Flutter, Dart, Android Gradle/Kotlin, iOS/Xcode, and provider SDK versions
- `flutter analyze`, unit/widget tests, platform builds, and real-device matrix with model/OS/provider/build/network/results
- Enabled formats and placements; approved consent/CMP/ATT behavior by market and provider
- Release-config checks (test IDs/geography absent, logging/privacy review, manifest/permissions, backup policy)
- VIP/grace scope and approved behavior, if applicable; disclose Android replay limitation
- Known failures, accepted limitations, rollback/monitoring owners, and outstanding partner sign-offs

Never include real credentials, private VIP signing keys, raw user-entered keys, or raw consent strings in the report or attached logs.

---

## Appendix A — Cheat sheet: API mapping (Android Kotlin → Flutter Dart)

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
- This file's Appendix D — step-by-step upgrade guide between versions (merged from the former standalone `MIGRATION.md`)
- `packages/ad_sdk/example/lib/main.dart` — a demo app with one page per feature, useful as a working reference for bootstrap, splash, banner/interstitial/rewarded, and VIP wiring
- `packages/ad_sdk/lib/src/vip/` — the SDK's own `VipRedeemScreen` implementation, useful if you're wrapping it directly instead of building the 13-component screen from scratch (see the note in Step 10.2)

If you only have the hosted `applovin_admob_sdk` package (no source access), the equivalent material ships with the package itself:

- The package's README and CHANGELOG on pub.dev (`https://pub.dev/packages/applovin_admob_sdk`)
- The same files under your local `.pub-cache`, e.g. `~/.pub-cache/hosted/pub.dev/applovin_admob_sdk-<version>/README.md` and `CHANGELOG.md`
- The package's own `example/` directory (also mirrored into `.pub-cache`) for a working demo of every integration point covered in this document

---

## Appendix C — Audit log (internal, reserved for next audit round)

This section is a running log for whoever continues auditing/enhancing this SDK. Each round appends a dated entry below — do not delete prior entries, only add. Keep this section free of real ad-unit IDs, SDK keys, bundle IDs, and local absolute paths, since this file is shared with partners as-is.

### Round — 2026-08-09

**Scope**: full audit of the SDK (`packages/ad_sdk/`), the SDK example app (`packages/ad_sdk/example/`), and the host app, including a 100%-of-suite pass on a real physical Android device (Pixel 7 Pro).

**Automated results at time of audit**:
- SDK unit tests: 699/699 pass, `flutter analyze` clean.
- SDK example on-device integration tests: 19/21 clean pass on the real device; the remaining 2 (`interstitial_ad_test`, `rewarded_ad_test`) load and display the ad creative correctly (confirmed via log lines showing successful display with network/creative/latency info) but can't complete because there's no unattended way to dismiss the ad — a known limitation, not an SDK defect, and the same reason CI already excludes these two files from its automated run.
- Host app tests: 118/118 pass, `flutter analyze` clean.

**Scores** (1–10, informs but doesn't replace an editorial decision on publishing):
- SDK itself: **9/10**.
- SDK example/demo app: **7/10**.
- Host app: **8/10**.

**Findings worth carrying into the next round**:

1. **Build-output path collision (DX trap, not a bug)**: `flutter build apk --debug` and `flutter test integration_test/*.dart` both write to the same default path (`build/app/outputs/flutter-apk/app-debug.apk` under whichever project directory you're in). Running an integration test after a debug build — or vice versa — silently overwrites that APK with a different compiled entrypoint. Reinstalling "the debug build" afterward can boot to a blank/stuck splash screen with zero crash log, because the installed binary's `main()` is actually a test file's harness waiting for a VM service connection that will never arrive. Not documented anywhere in the repo yet. Worth a one-line callout in `packages/ad_sdk/example/README.md` or `doc/README_TESTING.md`: rebuild explicitly (`flutter build apk --debug`) before manually reinstalling after running integration tests.
2. **Local interstitial/rewarded on-device testing needs real AppLovin credentials via `--dart-define`**, not documented in one obvious place. Without them, `interstitial_ad_test`/`rewarded_ad_test` fail for a credentials reason that looks superficially like an ad-load bug; worth a short note (which dart-define flags, roughly what they gate) somewhere a new contributor running these tests locally would see it before debugging the wrong thing.
3. **Same Android `applicationId` used by both the SDK example app and the host app** causes an install conflict on one device (installing one force-uninstalls or blocks the other). Not a bug — expected Android behavior for two apps sharing a package name — but worth a one-line note in `packages/ad_sdk/example/README.md` so a tester doesn't waste time diagnosing an "installation failed" error.
4. **AppLovin MAX test-ad creative close (X) button was not discoverable on this device/session** for either interstitial or rewarded, despite the ad genuinely loading and displaying (confirmed via SDK event logs), 10+ tap coordinates tried across letterbox and content-area corners, the hardware back button, and swipe gestures. Most likely a quirk of the specific AppLovin MAX test creative and/or this device's rendering, not an SDK integration defect — it directly explains why these two integration test files are excluded from CI (`.github/workflows/test.yml` comments call out exactly this: no unattended way to dismiss the ad). Worth re-checking on a future AppLovin MAX SDK bump in case a newer test creative fixes it, but not something to chase as an SDK code bug.

**Publish decision this round**: user reviewed the above and explicitly authorized publishing `applovin_admob_sdk` **2.0.4** to pub.dev (docs-only release — corrected an overclaimed "offline VIP redeem" description, see `CHANGELOG.md`). Published successfully; no new pub.dev scoring traps hit (description 153 chars, all three screenshot descriptions under 160 chars, dry-run and real publish both clean).

**Suggested next-round starting points**: re-verify the score-driving findings above are still accurate before re-quoting them (files/behavior may have moved), then decide whether findings #1–#3 warrant small doc patches (they're all doc-only fixes, no code risk) versus being left as tribal knowledge in this log.

Either way, treat this `AD_PROMPT_FLUTTER.MD` file itself as the primary, self-contained spec — the SDK source (when available) is a secondary reference for implementation detail, not a prerequisite for following the steps above.

### Round — 2026-09-01 (SDK audit round 27, doc-completeness pass)

**Scope**: user asked, as a standalone question separate from the SDK audit, whether this file alone is sufficient for a partner engineer to integrate "every feature" — not just whether it's internally correct. Full findings: `packages/ad_sdk/doc/audit/audit_claude_round27.md` (Part 1) and `packages/ad_sdk/doc/audit/audit_round27_consolidated.md` (§6).

**Finding**: this file was very strong on the hardest, highest-legal-risk parts (bootstrap ordering, splash lifecycle, VIP UI + security, consent/ATT, memory-leak checklist, policy compliance) but was missing 3 of the 7 ad surfaces the SDK actually ships and demos in `example/`: MREC, Native, and Rewarded Interstitial were absent from the touchpoint table and every lifecycle step — an agent following only this file would ship a correct integration for 4/7 ad types and never learn the other 3 exist. Also found the COPPA/AppLovin asymmetry (Step 8.4 below) was reduced to 2 lines of example code with no explanation of the real gap for always-child-directed apps.

**Fixed this round**: added Steps 4.8 (MREC), 4.9 (Native), 4.10 (Rewarded Interstitial), 3 new touchpoint-table rows, and Step 8.4 (COPPA/AppLovin asymmetry + the explicit question an integrator must ask the user for an always-child-directed app). The example app's own gap (`showRewardedInterstitialAd()` had zero demo/test coverage anywhere) was fixed in the same round — see `CHANGELOG.md` **[2.9.6]**.

**Suggested next-round starting point**: when a future round adds a new public ad surface or config knob, check this file's touchpoint table and Step 4/8 sections got a matching addition in the same commit — this gap sat undetected for at least 2 SDK feature releases (MREC/Native predate this entry) before someone asked the completeness question directly instead of only auditing the SDK's own correctness.

### Round — 2026-09-02 (SDK audit round 32)

**Scope**: 3 fully independent CLI agents (codex, agy/Gemini, claude) audited the SDK in parallel, each on its own isolated `git worktree`, no shared context with each other or the orchestrating session. Full findings: `packages/ad_sdk/doc/audit/audit_round32_deep_consolidated.md` (also `audit_codex.md`, `audit_agy.md`, `audit_claude.md` for the raw per-agent reports).

**Findings**: the 3 agents disagreed — 0/1/1 BLOCKER — and the 2 BLOCKERs found were independent of each other (neither agent that found one found the other); the orchestrator verified both directly against source before trusting them, both were real:

1. `ad_consent.dart`'s `applyConsentToProviders()` recorded consent as applied even when a provider write threw, so a transient failure during a consent withdrawal could leave a provider still personalised while the SDK believed it had gone restrictive.
2. `iab_storage.dart`'s `tcfAllowsPersonalisedAds()` had a `try { ... } on StateError` around opening the platform store that didn't catch `TimeoutException` — undoing round-31's fail-closed fix whenever the open itself hangs (e.g. a wedged `PackageInfo.fromPlatform()` binder call).

**Fixed this round** (`CHANGELOG.md` **[2.9.12]**–**[2.9.14]**): both BLOCKERs (TDD, RED→GREEN); `remote_ad_safety_provider.dart`'s `minSessionDurationBeforeAd` missing floor; `canShowRewardedInterstitialAd()` missing the `AdLoadingDialog.isShowing` gate its two siblings have; a splash example race (`_navigated` check missing from a buffered App Open callback); `bootstrap()`'s previously-unbounded wait on `initialize()` (new `initTimeout`, see Step 4.2's note above); AppLovin banner/MREC/native's revenue-event timing/gap (see this file's Step 4 ad-type sections — no prompt content changed, this was pure `lib/src/` code). This document itself got 3 updates: the `bootstrap()`/`initTimeout` note in Step 4.2, new Step 4.11 (known SDK limitations), and this entry.

**Suggested next-round starting point**: the AppLovin banner/MREC/native revenue-event wiring (2.9.14) has a known test gap — the platform-channel callback wiring has no test seam in this repo (`MaxAdView`/`MaxNativeAdView` are third-party platform views), only the pure event-mapping logic is unit tested. If a future round has real-device access, verify `AdRevenueEvent`s actually arrive for these 3 surfaces, not just that the code compiles.

### Round — 2026-09-02 (SDK audit round 33)

**Scope**: same 3-independent-agent method as round 32 (codex, agy/Gemini, claude), this round tasked with (a) verifying round 32's 6 fixes against real source (not the changelog) and (b) a fresh full re-audit. Full findings: `packages/ad_sdk/doc/audit/audit_round33_consolidated.md` (also `audit_codex_round33.md`, `audit_agy_round33.md`, `audit_claude_round33.md`).

**Findings**: the 3 agents disagreed again — codex found 2 new issues the other two missed entirely; the orchestrator traced the disagreement one level deeper than either the Gemini agent or the orchestrator's own first-pass Claude sub-agent had gone, into the `applovin_max` dependency's actual method signatures, and confirmed codex was right:

1. Round 32's BLOCKER-A fix (`ad_consent.dart`) is correct for the AdMob branch (properly `await`ed) but not the AppLovin branch — `AppLovinMAX.setHasUserConsent`/`setDoNotSell` are fire-and-forget `void` calls with no `Future` to await, so the surrounding `try/catch` cannot see a platform-channel failure; `appLovinApplied = true` is effectively unconditional in practice. This is a dependency-level ceiling, not fixable by changing this SDK's code alone — documented as a known limitation instead (README.md, this file's Step 4.11).
2. US state privacy signals sent only via the newer GPP string (not the legacy US Privacy string) were not read — same gap round 32 already classified MAJOR (#6), not a regression; user chose to close it this round (see below) rather than leave it deferred.

**Fixed this round**: GPP US-state opt-out parsing (`iab_storage.dart`, TDD) — closing round-32/33's MAJOR #6/R33-02 gap; a defensive per-instance ownership guard on AppLovin banner/MREC/native revenue callbacks (`banner_ad_widget.dart`/`mrec_ad_widget.dart`/`native_ad_widget.dart`, TDD) against a plausible-but-unconfirmed double-count risk codex flagged (R33-03) when the underlying `MaxAdView`/`MaxNativeAdView` platform view is torn down and a late native callback still arrives.

**Documented, not fixed** (user decision): the AppLovin consent-write confirmation gap (#1 above) — a dependency limitation, not something the Dart side can close; recorded as a known limitation in `README.md` and this file's Step 4.11 rather than papered over with a false sense of certainty.

## Appendix D — Migration guide (version history, merged from `MIGRATION.md` on 2026-08-20)

Practical step-by-step guides for upgrading from older versions of `applovin_admob_sdk`. This appendix replaces the former standalone `MIGRATION.md` — that file was deleted; `README.md`'s Migration section and this repo's root `CLAUDE.md` both now point here.

### Table of contents

- [1.0.20 → 1.0.21 → 1.0.22 → 1.0.23](#d-1020--1021--1022--1023) — backward-compatible; opt-in VIP stacking / rewarded-while-VIP; auto App-Open-skip-on-dialog
- [1.0.18 → 1.0.19 → 1.0.20](#d-1018--1019--1020) — iOS ATT (action needed for iOS); example-only 1.0.20
- [1.0.15 → 1.0.16](#d-1015--1016) — documentation-only release
- [1.0.14 → 1.0.15](#d-1014--1015) — no breaking changes; opt-in new features
- [1.x → 2.x (legacy upgrade path)](#d-1x--2x) — auto-migrating; old calls still work
- [3.x compatibility and latest release](#d6--3x-compatibility-and-latest-release) — verify Flutter/Dart/Kotlin floors, provider pins, and native build requirements
- [Common issues](#d-common-issues)
- [FAQ](#d-faq)

---

### D.1 — 1.0.20 → 1.0.21 → 1.0.22 → 1.0.23

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

### D.2 — 1.0.18 → 1.0.19 → 1.0.20

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

### D.3 — 1.0.15 → 1.0.16

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

### D.4 — Historical: 1.0.14 → 1.0.15 (not current guidance)

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

### D.5 — Historical: 1.x → 2.x (migration record, not current integration sample)

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

`AdConfig.maxVipStackDuration`: `null` (uncapped) → `Duration(days: 90)`. If you use `stack: true` on `addVip`/`redeemVip` (see D.1 above) and relied on unlimited stacking, set it back explicitly:

```diff
  AdConfig(
+   maxVipStackDuration: null, // restore uncapped stacking
  );
```

---

### D.6 — 3.x compatibility and latest release

Fetch the latest stable version from pub.dev when integrating; do not assume this guide describes every release. Read that exact version's README and CHANGELOG, run `flutter pub get`, and validate native dependency resolution/builds for every target platform.

The current source package metadata sets Flutter `>=3.38.1` and Dart `>=3.10.0`. It constrains `google_mobile_ads` to `>=9.0.0 <9.1.0` because `9.1.0` has a documented iOS build regression. On Android, GMA 9.0.0 requires the consuming app's Kotlin Gradle plugin to be `>=2.3.0`; Kotlin 2.3 removes the old `kotlinOptions { jvmTarget = ... }` DSL. Confirm these constraints against the actual published version selected for the partner.

For an Android app on Kotlin below 2.3.0:

1. In `android/settings.gradle.kts`, raise `id("org.jetbrains.kotlin.android")` plugin version to at least `2.3.0` (see `example/android/settings.gradle.kts` for this SDK's current pattern).
2. In `android/app/build.gradle.kts`, remove the old `android { kotlinOptions { jvmTarget = ... } }` block and use:
   ```kotlin
   kotlin {
       compilerOptions {
           jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11)
       }
   }
   ```
3. Run `flutter clean`, `flutter pub get`, and `flutter build apk --debug`. If Gradle/Kotlin fails, record the complete error and check Android Gradle Plugin/Gradle compatibility before changing further versions.

`gma_mediation_applovin` is optional and belongs at the consuming-app level only when using AppLovin as an AdMob mediation network. The checked-in known-good fixture pins `gma_mediation_applovin: 2.6.2` with `applovin_max: ^4.6.4` and asserts CocoaPods resolves `AppLovinSDK 13.6.3`. In this repository run `./tool/check_pinning_wall.sh` for Dart/pod resolution + pod version assertion, or `./tool/check_pinning_wall.sh --with-builds` to additionally compile the fixture APK and iOS Simulator app. This fixture validates dependency compatibility, not partner app configuration. When versions change, also run `flutter pub get`, `(cd ios && pod install)`, and real Android/iOS builds in the consuming app; dependency resolution alone is not compile proof.

For behavior changes between SDK releases, read the full CHANGELOG entry and this guide's corresponding integration sections. Do not treat a version bump as automatically source-compatible; confirm breaking changes and migration steps first.

---

### D.7 — Common issues

**"Build failed — `applovin_admob_sdk` is not in the dependency cache"**

Pub.dev typically takes up to 10 minutes to index a newly published version. If you upgrade right after a release, wait a few minutes and re-run `flutter pub get`. If the issue persists, force a fresh fetch:

```bash
flutter pub cache clean -f
flutter pub get
```

**"Build failed — `Unexpected token` in `build.gradle.kts`"**

Likely the `minSdk` or `targetSdk` is set with Groovy syntax (`minSdk 24`) in a Kotlin DSL file. Use Kotlin syntax (`minSdk = 24`).

**"App crashes when user backgrounds during an ad"**

See `README.md` → Pitfalls → 1. Most likely you have `android:taskAffinity=""` on `MainActivity`. Remove it.

**Ads not loading on iOS**

Verify `Info.plist` contains `GADApplicationIdentifier` for bundled Google Mobile Ads/UMP, `AppLovinSdkKey` only if AppLovin is enabled, partner-approved `NSUserTrackingUsageDescription` only if ATT is in scope, and current merged `SKAdNetworkItems` for enabled networks. Verify Podfile targets iOS 13 or newer; run `pod install` and an iOS Simulator/device build.

**"Inter ad doesn't show — `canShow=false`"**

Run with `AdConfig.logLevel = AdLogLevel.verbose` and check the log for `⏭️ showInterstitial blocked by safety: <reason>`. The reason tells you exactly which gate denied the show:

- `Suspended: Xs remaining` — progressive cooldown active because of a recent CTR/click anomaly. Wait it out or call `AdSafetyConfig.resetSession()` in QA.
- `Session too young: wait Xs` — `minSessionDurationBeforeAd` not yet elapsed.
- `Session limit: N ads` — hit `maxFullscreenAdsPerSession`.
- `Hourly cap: N ads` — hit `maxFullscreenAdsPerHour`.
- `Daily limit: N ads` — hit `maxFullscreenAdsPerDay` (persisted across launches).
- `Throttle: wait Xms` — too soon after the previous fullscreen ad.

**"VIP grace not expiring in dev"**

Default debug grace is 30 seconds. Wipe app data to start fresh:

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

### D.8 — FAQ

**Will my 1.0.14 code keep working in 1.0.15?**

Yes. 1.0.15 has zero breaking changes. The new behaviors (auto consent dialog, first-install grace) are opt-in defaults that you can disable if they conflict with your existing UX.

**Which version should I integrate?**

Use the latest stable release shown by pub.dev at integration time, then read that version's README and CHANGELOG before changing `pubspec.yaml`. The historical 1.x → 2.x migration notes above describe only that version transition; they are not a substitute for the migration notes required when moving to the currently selected release. Check Appendix D.6 for current 3.x compatibility constraints.

**How do I roll back from 1.0.15?**

Pin to the previous version in `pubspec.yaml`:

```yaml
applovin_admob_sdk: 1.0.14
```

Then `flutter pub get`. The SDK does not write to SharedPreferences in a forward-incompatible way, so persisted state (VIP entries, consent settings, daily ad count) will degrade gracefully if you downgrade. The only loss is the consent-settings JSON record, which 1.0.14 does not read — your users will be re-prompted via your existing consent UI on the downgrade.

**Can I run 1.0.15 alongside an older version in a monorepo?**

Yes, as long as each app pins its own version in `pubspec.yaml`. The SDK is a single Dart package; no native module conflicts.

**Why is `flutter analyze` failing right after I upgrade to a freshly-published version?**

pub.dev takes up to 10 minutes to index a new release. Wait a few minutes and re-run.

**Need help?**

- Open an issue on [GitHub](https://github.com/royt93/FlutterBase2026/issues) with the `roy93~` log output, your SDK version, and which provider (admob / appLovin)
- See `README.md` for the integration walkthrough
- See `doc/architecture.md` for the internals (state machine, lifecycle, safety gate)
