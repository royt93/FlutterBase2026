# Round 46 independent security/correctness audit

Package reviewed: `packages/ad_sdk`  
Audit date: 2026-09-19  
Published version in `pubspec.yaml`: 3.0.0; round-45 changes are local and unpublished

## Executive result

Round 46 is **not clean** for the publish gate.

I found one new **MAJOR** issue: calling the documented pre-initialization `setDoNotSell` API falsely satisfies the release consent-flow guard, even though that call only sets the CCPA opt-out axis and does not establish a GDPR/UK consent flow. In the affected configuration, an EEA/UK release build can proceed to ad loading with both UMP and the AppLovin CMP disabled.

I also found two **MINOR** issues. The round-45 test-ID hard block is not process-lifetime as intended because a later successful consent update clears the same shared block flag. The native late-callback fix only protects disposal within the same `AppLovinAdapter` instance; callbacks from a destroyed adapter can be accepted by its replacement. Banner and MREC click callbacks also lack the stale-instance check already used by their revenue callbacks.

The other two round-45 fixes—the TCF-aware AppLovin consent setter and explicit rewarded-interstitial rejection for AppLovin—are correct and complete for the source-visible paths.

## Scope and method

I first read the repository contract in `CLAUDE.md`, the package README, the changelog's `[Unreleased]` section, and the prior round-44/45 reports. I treated their explicitly accepted limitations as trade-offs rather than rediscovering them as findings.

The review traced public entry points through `AdManager`, consent state, both provider adapters, platform-specific configuration getters, callback ownership, disposal, timers, persistence, and request/show paths. I searched for every source-visible caller of the underlying round-45 mechanisms rather than checking only the changed lines. I did not run tests or build commands because this audit copy permits only one filesystem write: this report. Existing tests were inspected where relevant.

## New findings

### R46-01 — MAJOR — Pre-init `setDoNotSell` bypasses the release consent-flow guard

**Affected code**

- `lib/src/core/ad_manager.dart`, `consentFootgunWarning` (approximately lines 365–395)
- `lib/src/core/ad_manager.dart`, `setConsent` (approximately lines 4755–4763)
- `lib/src/core/ad_manager.dart`, `setDoNotSell` (approximately lines 4954–4974)

**Runtime sequence**

1. A release app configures `autoRequestUmpConsent: false` and leaves the AppLovin CMP disabled.
2. Before `initialize`, it calls the public `setDoNotSell(true)` API. This ordering is supported by the package contract so an application can supply privacy state before SDK initialization.
3. Because `_consentManager` does not exist yet, `setDoNotSell` constructs an `AdConsent` value and routes it through `setConsent`.
4. `setConsent` unconditionally sets `_consentExplicitlySet = true` and clears `_footgunBlocked`.
5. `consentFootgunWarning` treats any `_consentExplicitlySet` value as proof that a consent flow exists and returns no warning/block.
6. Initialization and ad preloading can consequently continue although neither UMP nor AppLovin CMP is enabled and the only explicit value supplied was the CCPA “do not sell” axis.

`doNotSell` is not a substitute for collecting or presenting GDPR/UK consent. The SDK may still derive restrictive request flags from incomplete consent, but that does not satisfy the guard's documented purpose: preventing a production integration with no consent form or qualified consent flow. The bypass is especially misleading because it arises from a legitimate public API call rather than private state manipulation.

**Impact**

This defeats a production policy safeguard intended to prevent an EEA/UK consent-flow omission. It can expose publishers to consent and disclosure non-compliance while the SDK reports no blocking integration error. That is a release-policy correctness issue and is classified MAJOR.

**Recommended fix**

Separate “a privacy field was supplied” from “a qualifying consent flow was completed or deliberately supplied.” Before initialization, `setDoNotSell` should update/buffer only the `doNotSell` field without marking the general consent requirement satisfied. Alternatively, track independent evidence for UMP completion, AppLovin CMP availability/completion, or an explicit host-managed GDPR consent decision.

Add a release-mode regression test with UMP disabled, AppLovin CMP disabled, and pre-init `setDoNotSell(true)`; the consent footgun must remain blocking. Include both providers because the guard is provider-configuration dependent.

### R46-02 — MINOR — The release test-AdMob-ID hard block is cleared by later consent handling

**Affected code**

- `lib/src/core/ad_manager.dart`, `_applyTestIdFootgunGuard` (approximately lines 2369–2381)
- initialization call to that guard (approximately lines 3229–3234)
- `lib/src/core/ad_manager.dart`, `setConsent` (approximately lines 4755–4763)
- UMP result application (approximately lines 5355–5366)

**Runtime sequence**

1. In a release build using the AdMob provider, an active format resolves to a Google sample ad-unit ID.
2. `_applyTestIdFootgunGuard` correctly detects it and sets `_footgunBlocked = true`. Its comment describes the block as lasting for the process lifetime.
3. The default automatic UMP flow completes and applies its result through `setConsent`, or the host calls `setConsent` manually.
4. `setConsent` unconditionally sets `_footgunBlocked = false`, because the same flag is also used for the independent missing-consent-flow footgun.
5. Ad requests are permitted again despite the release build still using a Google test ID.

The ID detection itself is sound: it is limited to the active AdMob provider, checks all configured formats, and uses the effective Android/iOS getters. It therefore does not falsely block AppLovin or a legitimate production AdMob ID. The defect is the shared mutable block state and normal initialization ordering.

**Impact**

The hard block added for R45-04 is ineffective on an ordinary successful UMP path, allowing test inventory in a release build. This retains the original warning's revenue and ad-policy risk. It is MINOR under the project's established severity for R45-04.

**Recommended fix**

Use independent reason flags, for example `_consentFootgunBlocked` and `_testIdFootgunBlocked`, and make request eligibility the conjunction of all blockers. Consent updates must clear only the consent blocker; a detected release test ID should remain blocked for the process lifetime unless configuration is explicitly revalidated and changed.

The existing regression test checks the guard immediately after applying it. Add a sequence test that applies the test-ID block, then applies a successful UMP/manual consent result, and finally verifies that requests remain blocked.

### R46-03 — MINOR — AppLovin inline callbacks are not fully tied to the adapter/ad instance that registered them

**Affected code**

- `lib/src/widget/native_ad_widget.dart`, callback registration (approximately lines 598–688)
- `lib/src/widget/banner_ad_widget.dart`, click/revenue callbacks (approximately lines 983–1027)
- `lib/src/widget/mrec_ad_widget.dart`, click/revenue callbacks (approximately lines 647–686)
- `lib/src/adapters/applovin_adapter.dart`, per-adapter native disposal tombstones (approximately lines 458–571)

**Native cross-adapter race**

The R45-02 click fix now checks `isNativeInstanceDisposed(instanceKey)`, matching the native revenue callback. That protects a late callback after widget disposal while the same `AppLovinAdapter` remains installed.

However, every native callback obtains `AdManager().adapter` again when the callback fires. Disposal tombstones belong to a particular `AppLovinAdapter` instance. After SDK destruction and re-initialization, a late callback registered by the old adapter sees the new global adapter, whose tombstone set has never contained the old widget key. It can therefore pass the new checks:

- click and revenue can update counters and emit events into the new SDK session;
- load and load-failure callbacks can create/update per-key native state in the replacement adapter, retaining a key owned by the destroyed widget/session until a later global teardown.

Thus the comment that the new native guard covers destroy/re-initialize races is not true for the actual object-ownership chain.

**Banner/MREC sibling gap**

Banner and MREC revenue callbacks compare the callback's view identity with the current registered view identity before accounting revenue. Their click callbacks do not perform the corresponding check. A click delivered after reload, replacement, or disposal can therefore increment click/fraud counters and emit an event for a stale view. The banner/MREC loaded, failed, expanded, and collapsed callbacks currently only log, so they do not have the same direct state-accounting consequence.

The revenue callbacks themselves re-resolve state through the global manager; after re-initialization, that lookup can also allocate a null notifier in the new adapter before rejecting the stale event. This is a small cross-session state-retention symptom of the same missing ownership binding.

**Impact**

Late native callbacks can contaminate a new SDK session and retain stale per-widget state; late banner/MREC clicks can corrupt fraud/click accounting. The window depends on native-plugin callback timing and teardown/re-initialization, so this is MINOR rather than a general availability or privacy failure.

**Recommended fix**

Capture the concrete adapter and native/view identity when registering each listener. Before any callback side effect, require both `identical(AdManager().adapter, capturedAdapter)` and equality with the currently registered ad/view identity. Use one shared stale-callback predicate for click, revenue, native load, and native load-failure handling so the callbacks cannot drift apart.

Add tests for both:

- disposal/reload within one adapter; and
- old callback → `destroy` → new `AppLovinAdapter` → old callback fires.

The current native regression covers only disposal while retaining the same adapter, which is why this path remains undetected.

## Round-45 fix verification

| Round-45 item | Result | Verification |
|---|---|---|
| R45-01: AppLovin pre-init consent overwrote TCF vendor consent | **Correct and complete** | The pre-init call now reads `IabStorage.keyTcfString` and calls `setHasUserConsent` only when no non-empty TCF string exists. The post-init consent application already has the same guard. Searches and call tracing found no other source-visible direct or indirect caller that unconditionally applies AppLovin `setHasUserConsent`; mid-session updates and re-initialization converge on these guarded paths. `setDoNotSell` remains independent, as intended. |
| R45-02: native click after disposal | **Incomplete** | The guard works for a disposed key within the same adapter, but callbacks re-resolve the global adapter and can escape old-adapter tombstones after destroy/re-init. Native load/failure have stateful side effects without an adapter-identity guard, and banner/MREC click callbacks lack the stale-view guard used for revenue. See R46-03. |
| R45-03: rewarded interstitial silently no-op on AppLovin | **Correct and complete** | Both load and show explicitly detect `AppLovinAdapter` and emit `AdSkipEvent(reason: 'unsupported_provider')`. `AdMobAdapter` does not match that branch and continues to its supported implementation, so the guard does not disable AdMob rewarded interstitials. |
| R45-04: release build using Google test IDs was warning-only | **Incomplete** | Provider/platform/format detection is correct and does not block legitimate IDs, but normal UMP or manual consent handling clears the shared `_footgunBlocked` flag. See R46-02. |

The other warnings in `releaseFootgunWarnings` do not require the same hard-block behavior:

- `firstInstallVipGrace` being disabled in release is an explicit monetization/product decision. A warning is appropriate; blocking would contradict a supported configuration.
- `umpDebugGeography` in release is a debug-configuration/UX and revenue hazard, but it does not itself substitute for a legal basis or request Google test inventory. Its behavior is conservative in that it can force consent treatment. Leaving it warning-only is a deliberate and defensible distinction from release test ad IDs.

## Fresh review of the eight requested areas

### 1. Dual-provider correctness

Platform-specific AdMob IDs are selected through effective Android/iOS getters, and provider routing for app-open, interstitial, rewarded, banner, MREC, and native ads is internally consistent. Rewarded interstitial remains intentionally AdMob-only and is now explicitly rejected for AppLovin without affecting AdMob. I found no additional silent format/platform divergence.

R46-02 affects only release AdMob sample IDs after consent changes. R46-03 affects AppLovin inline callback ownership across reload/dispose/re-init.

Native SDK availability, mediation waterfall composition, and format rendering on real Android/iOS versions require device-level integration tests; Dart source inspection cannot establish them.

### 2. Offline and no-network behavior

When connectivity information is available, load attempts are gated and reconnect handling schedules refill/retry work. Initialization, consent, and ad-load operations use bounded failure/watchdog paths rather than indefinitely holding public state. If connectivity detection is unavailable, the SDK deliberately falls back to optimistic requests and lets the native SDK fail/back off; I found no new correctness or security defect in that fallback.

The exact ordering of connectivity broadcasts versus native callbacks, captive portals, and process resume requires device/network fault injection to verify.

### 3. Ad lifecycle correctness

Fullscreen formats use slot state, load/show watchdogs, and a show mutex. App-open suppression accounts for SDK-managed dialogs and inline ad hiding; host-owned nested navigators/overlays remain an explicitly documented integration responsibility. Inline widget disposal generally tears down listeners and provider objects.

R46-03 is the newly identified ownership hole for late AppLovin inline callbacks. I found no additional source-visible dispose-chain or app-open/dialog-stacking issue beyond documented trade-offs.

Native dismiss/click delivery after activity/view-controller destruction must be exercised on devices because plugin callback guarantees are outside this repository.

### 4. One-day trial mode

Trial time is persisted in UTC, bounded by a persisted high-water mark, and supplemented with a foreground monotonic-clock check. Resume paths resynchronize relevant state. These mechanisms address ordinary wall-clock rollback and timezone changes.

The documented Android clear-data/reinstall reset and iOS Keychain durability difference remain accepted trade-offs, not new findings. A purely local SDK cannot provide strong reinstall/tamper resistance on every platform without backend or hardware-backed state.

### 5. Offline/no-backend VIP activation

The AVP2 path verifies Ed25519 signatures, expiry and bundle binding, enforces positive bounded duration, clamps stacking/non-stacking results to the configured maximum, and uses both in-flight and persisted redemption tracking. CRL/provenance handling is present where online data is available.

I found no new cryptographic verification, replay, or duration-stacking flaw. Cross-device replay and Android data-clear/reinstall replay remain explicitly accepted consequences of offline verification. Cryptographic library implementation correctness itself is dependency-level and was not re-proven here.

### 6. Consent across jurisdictions

The AppLovin TCF-preservation fix is complete across source-visible setter paths. AdMob request configuration carries child-directed, under-age, and non-personalized treatment; stored TCF/US privacy/GPP signals are used in the SDK's tighten-only derivation. ATT and UMP/AppLovin CMP responsibilities are separated in the expected platform paths.

R46-01 is a new consent-flow qualification bypass. The documented partial GPP parsing, AppLovin fire-and-forget privacy setters, AppLovin's lack of a runtime COPPA update API, and native SDK interpretation of raw consent storage remain accepted limitations.

Device verification is still required to confirm that UMP writes the expected TCF keys before AppLovin initialization, that AppLovin consumes them consistently on both platforms, and that vendor-list/purpose changes are reflected by the installed native SDK versions.

### 7. AdMob/AppLovin policy compliance

The SDK contains child-directed/under-age routing, frequency and density controls, rewarded disclosures, consent safeguards, and explicit unsupported-format reporting. Test-device hashes remaining enabled in release and AppLovin's new-install child-directed gap are documented decisions.

R46-01 bypasses the missing-consent-flow safeguard. R46-02 defeats the intended release test-ID block after consent succeeds. R46-03 can misattribute late click/revenue events and click-fraud counters. I found no additional new policy issue from source inspection.

Actual creative density, mediation waterfall behavior, and provider-console configuration cannot be verified from this source tree and need device plus console review.

### 8. Memory and resource lifecycle

The reviewed managers and widgets generally cancel timers/subscriptions, close stream controllers, dispose notifier/controller state, and destroy provider ad objects along their corresponding teardown paths. Slot/watchdog resources are bounded.

R46-03 permits old native callbacks to create or update per-key state in a replacement adapter, with retention until a later teardown, and can allocate null view-notifier state during stale revenue checks. I found no other new unbounded `Timer`, `StreamController`, native object, or `AnimationController` lifetime mismatch.

Heap/native-view leak absence ultimately needs repeated load/dispose and destroy/re-init profiling on Android and iOS; source review cannot observe plugin/native retain cycles.

## Device-level verification still required

The following cannot be conclusively established from Dart/source inspection alone:

- late callback ordering and retention behavior in the AppLovin Flutter/native bridge;
- UMP-to-TCF persistence timing and AppLovin's native consumption of those values;
- Android activity and iOS view-controller lifecycle behavior for app-open and inline platform views;
- mediation waterfall and provider-console child-directed/test-mode configuration;
- captive portal, network handoff, background/resume, and process-death behavior;
- native heap/view retention after repeated load, dispose, and SDK re-initialization.

These should be covered by device fault-injection and memory-profile runs before publication, but none changes the source-proven findings above.

## Counts and publish-gate verdict

- **NEW BLOCKER findings: 0**
- **NEW MAJOR findings: 1**
- **NEW MINOR/NIT findings: 2** — 2 MINOR, 0 NIT

Round 45's four fixes are **not all verified complete**:

- R45-01 is correct and complete.
- R45-02 is incomplete because it does not bind callbacks to the originating adapter/session and sibling banner/MREC clicks remain unguarded.
- R45-03 is correct and complete and does not disable the supported AdMob path.
- R45-04 detects the right configurations, but its block is later cleared by consent handling and is therefore incomplete.

**Verdict: round 46 is not clean.** It has one new MAJOR finding, so it does not count as a zero-MAJOR/BLOCKER audit round and the project's two-consecutive-clean-round publish gate is not satisfied.
