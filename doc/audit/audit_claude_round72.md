# Audit Round 72 — Independent Full Audit (Claude, Sonnet 5)

Auditor: independent pass with no memory of any prior audit session. Every
conclusion below — especially the fraud-investigation section — comes from
reading this repository's actual source code during this session, not from
trusting any prior `doc/audit/*` file's verdicts. Prior audit files were
skimmed only to see where things live, never for their conclusions.

Read-only audit: no files were edited, moved, or deleted, and no destructive
or build command was run. `pubspec.lock` / `Podfile.lock` were read directly
instead of running `pub get` / `pod install`.

Method: the ~38.7k lines of `packages/ad_sdk/lib/**` plus the ~5k-line
`packages/ad_sdk/example/lib/main.dart` were split across six independent
full-file read-only passes (adapters/provider layer, consent, VIP/trial
security, monetization/fraud-hunt, widget lifecycle, state/compliance/config
+ example app), each of which read its assigned files line-by-line rather
than sampling, followed by one additional targeted pass to close a coverage
gap in `ad_manager.dart` (the 9,385-line central orchestrator, too large for
any single pass to read in full). Findings from all seven passes are merged
below; severities were reconciled by this coordinator where two passes
disagreed.

## 1. Verdict

**Production-ready, with conditions.** The SDK's Dart layer is a thin,
consistently audited wrapper around the official `google_mobile_ads` and
`applovin_max` plugins — no unofficial dependencies, no dynamic code
loading, no undisclosed network endpoints were found anywhere in the ~44k
lines read across all seven passes, and the majority of edge cases this
brief asked about (offline handling, ad-stacking, consent-before-init
ordering, VIP clock-tamper resistance) already have dedicated, working fixes
with inline comments citing the specific prior audit round that found and
closed them. Conditions before shipping:

1. **Accept or close the Android trial/VIP-key farming gap** (MAJOR finding
   below) — the 1-day trial and single-use signed VIP keys have no durable
   anti-reinstall protection on Android (only iOS has a Keychain-backed
   guard), and there is currently no runtime signal to an integrator who
   hasn't separately configured Android Auto Backup.
2. **This is a code-review-only audit.** Per the project's own `CLAUDE.md`,
   verify any release on a real consuming app with `flutter pub get` **and**
   `pod install` **and** a real `flutter build apk` / `flutter build ios`
   before publishing — this round could not do that.
3. Two self-disclosed, not-independently-verifiable gaps remain: the iOS
   branch of TCF/GPP storage has never been exercised on real hardware (CI
   down since 2026-08-09), and the 19 US-state GPP parsers' bit offsets are
   claimed correct against the IAB reference encoder but could not be
   re-verified without network access this round.

No BLOCKER-severity finding was identified in any of the seven passes.

## 2. Fraud / covert ad-injection investigation — **NO EVIDENCE FOUND**

Explicit conclusion: **NO EVIDENCE OF FRAUD OR COVERT AD-NETWORK INJECTION**
was found anywhere in `packages/ad_sdk/lib/**`, `packages/ad_sdk/example/lib/**`,
`pubspec.yaml`/`pubspec.lock` (all three lockfiles: package, example,
`tool/pinning_check_app`), `example/ios/Podfile`/`Podfile.lock`, or any
native glue file. This conclusion is based on directly reading essentially
the entire Dart source tree (see §4 for the one disclosed sampling
boundary), not a partial grep.

Supporting evidence, file:line:

- **No hardcoded URL/domain/IP/base64 exfiltration channel.** A repo-wide
  grep for URLs, `base64Decode`, `dlopen`, `DexClassLoader`, `loadClass`,
  `Reflect`, `eval(`, `WebView`, and `RemoteConfig` across `lib/` and
  `example/lib/` turned up exactly five hits, all confirmed benign by
  reading the surrounding code in full:
  - `packages/ad_sdk/lib/src/config/remote_ad_safety_provider.dart:13` and
    `packages/ad_sdk/lib/src/vip/vip_revocation_provider.dart:17` are
    **doc-comment examples** inside `abstract class` extension points
    (`RemoteAdSafetyProvider`, a CRL fetcher), showing a host app how it
    *could* wire its own Firebase Remote Config / HTTP client if it wants
    one. Neither class ships a default implementation or makes a network
    call itself — the SDK contacts nothing here unless a host app supplies
    a concrete subclass.
  - `packages/ad_sdk/lib/src/vip/signed_vip_key.dart:377` — `base64.decode`
    on the VIP key payload, part of the already-audited Ed25519
    verification path, not a hidden payload channel.
  - `packages/ad_sdk/lib/src/core/ad_manager.dart:2516` and
    `example/lib/main.dart:21` are plain-English comments, not code.
- **No git/path dependency overrides.** Every `source:`/`url:` entry in
  `packages/ad_sdk/pubspec.lock`, `packages/ad_sdk/example/pubspec.lock`,
  and `packages/ad_sdk/tool/pinning_check_app/pubspec.lock` resolves to
  `hosted` / `https://pub.dev` — zero git or path dependency pointing at an
  unofficial fork.
- **No unofficial native SDKs.** `example/ios/Podfile.lock` pins only
  official pods: `AppLovinSDK (13.6.3)`, `Google-Mobile-Ads-SDK (12.14.0)`,
  `GoogleUserMessagingPlatform (3.1.0)`, plus standard first-party Flutter
  plugin pods (`webview_flutter_wkwebview` is a **transitive** dependency of
  Google-Mobile-Ads-SDK itself, used for its own rich-media ad rendering —
  not something this package added). Versions match the pinning-wall combo
  `CLAUDE.md` documents (AppLovinSDK 13.6.3 ↔ applovin_max 4.6.4).
- **No native code inside the package itself.** `packages/ad_sdk/` has no
  `android/`/`ios/` directories of its own — confirmed by directory search —
  so there is no surface for hidden native (Kotlin/Java/Swift/ObjC) code at
  all; the SDK is 100% Dart calling the official plugins' public Dart APIs.
  The only native code in the repo is in `example/` and is stock Flutter
  boilerplate with zero custom logic:
  `packages/ad_sdk/example/ios/Runner/AppDelegate.swift` (registers plugins,
  nothing else), `packages/ad_sdk/example/android/app/src/main/kotlin/com/example/ad_sdk_example/MainActivity.kt`
  (5 lines, empty `FlutterActivity` subclass), and
  `packages/ad_sdk/example/ios/RunnerTests/RunnerTests.swift` (an empty
  template test).
- **No dynamic code loading / reflection.** Zero real hits for
  `DexClassLoader`, `loadClass`, `Reflect`, `eval(` anywhere in the tree.
- **No hidden/off-screen ad views or synthetic clicks.** A dedicated pass
  over every widget file (`banner_ad_widget.dart`, `mrec_ad_widget.dart`,
  `native_ad_widget.dart`, `inline_ad_controller.dart`, `ad_screen.dart`,
  `ad_loading_dialog.dart`, `debug_ad_overlay.dart`, `revenue_panel.dart`,
  `shimmer_view.dart`, `top_toast.dart`) plus `example/lib/main.dart` found
  no `Offstage`/`opacity: 0` trick used to hide an ad, no programmatic
  dispatch of tap/pointer/gesture events onto an ad view, and no
  auto-refresh behavior that violates network refresh-rate policy — the
  opposite is true: `applovin_adapter.dart`'s `InlineVisibilityOwners`
  machinery actively **pauses** AppLovin MAX's native refresh ticker
  whenever an inline surface isn't visible (route change, app backgrounded,
  covered by a fullscreen ad).
- **Every click/impression/revenue event is a pass-through, never a
  fabrication.** `AdClickEvent`/`AdImpressionEvent`/`AdRevenueEvent` are
  traced in both `admob_adapter.dart` and `applovin_adapter.dart` back to
  the native SDK's own `onAdClicked`/`onAdImpression`/`onAdRevenuePaidCallback`
  delegate calls in every case — the SDK only *observes and forwards* what
  the ad network itself reported, it never *dispatches* a click or inflates
  a value. The single event-sink chokepoint,
  `AdManager._emit()` (`packages/ad_sdk/lib/src/core/ad_manager.dart:~9350-9384`),
  forwards each event unchanged (it only re-attributes the `placement`
  field for correct host-side attribution) to exactly two destinations: the
  SDK's own public `events` stream (consumed by the host app) and the local
  compliance `AdEventLog` — no third, external destination exists.
- **The suspiciously-named `monetization/` subsystem is genuinely benign.**
  Every file in `packages/ad_sdk/lib/src/monetization/` and
  `lib/src/adaptive/adaptive_frequency.dart` was read in full specifically
  *because* names like `MonetizationDigitalTwin`, `WaterfallTuner`,
  `RevenueIntegrityLedger`, and `MonetizationArbitrator` sound
  fraud-adjacent. Each one turned out to be a pure, on-device, read-only
  statistics/heuristic layer that only ever reads from the SDK's own
  already-recorded local `AdEventLog` — none of them make a network call,
  none of them alter or inflate a revenue/click/impression value before or
  after it's reported to AdMob/AppLovin, and none of them redirect an
  impression to a different network. `RevenueAnomalyDetector` in
  particular exists to **surface** possible double-counting/fraud patterns
  to the host app, not commit them (median/MAD statistical spike detection
  and duplicate-`requestId` detection over local data only).
- **No undisclosed telemetry/analytics.** Every runtime dependency in
  `pubspec.yaml` (`google_mobile_ads`, `applovin_max`,
  `app_tracking_transparency`, `advertising_id`, `connection_notifier`,
  `flutter_secure_storage`, `cryptography`, `package_info_plus`,
  `confetti`, `visibility_detector`, `wakelock_plus` + platform interface,
  `shared_preferences` family) has a stated, on-topic purpose (ads, consent,
  secure storage, connectivity, screen-wake, confetti UI) and none of them
  is used outside that stated purpose anywhere in the code read.

**No BLOCKER- or MAJOR-severity fraud-adjacent finding exists.** The one
MAJOR finding in §3 (Android trial/VIP-key reinstall farming) is a
monetization-integrity *gap* — an abuse vector available to the SDK's own
*end users*, bounded by requiring a real app reinstall each time — not
evidence of the SDK author or the SDK itself committing fraud, skimming
revenue, or injecting a hidden ad network.

## 3. Findings

| Severity | Location | Summary | Why it matters | Suggested fix |
|---|---|---|---|---|
| MAJOR | `packages/ad_sdk/lib/src/vip/_first_install_guard.dart:27-47,149-156` | Android has **no durable local anti-bypass** for the 1-day trial grace period — the guard is iOS-only (Keychain-backed). On Android, uninstalling and reinstalling the host app wipes the SharedPreferences record and grants a fresh trial, indefinitely, unless the host app separately configures Android Auto Backup (`android:dataExtractionRules` restoring `FlutterSharedPreferences.xml`) — and nothing in the SDK warns an integrator who skipped that step. | This is a core monetization mechanism (the free trial gating VIP/ad-free entitlement). Unbounded, silent farmability on the majority mobile platform materially undermines the very thing it's meant to protect, and an integrator who follows the documented setup steps has no runtime signal that Android needs *extra* manifest configuration to make the guard actually hold. | **A)** Ship as-is — documented, deliberate "no backend" product decision; cost is bounded per-reinstall. **B)** Add a one-time `SafeLogger` warning inside `AdManager.initialize()` on Android when Auto Backup can't be confirmed present, so integrators aren't silently exposed. **C)** Elevate the Android Auto Backup step from a doc footnote to a CI-enforced requirement (fail the example-app build if `AndroidManifest.xml` lacks the `dataExtractionRules`), moving it from "hope they read the docs" to "enforced." |
| MINOR | `packages/ad_sdk/lib/src/vip/_redeemed_key_ledger.dart:9-22`, `packages/ad_sdk/lib/src/vip/vip_manager.dart:1424-1441` | Signed VIP-key one-time-use replay protection is durable (iOS Keychain-backed `RedeemedKeyLedger`) only on iOS; on Android it relies solely on `SharedPreferences`, which an uninstall/reinstall wipes — so a leaked/publicly-shared signed key can be replayed once more per Android reinstall. Same root cause and same Auto-Backup dependency as the MAJOR finding above. | Bounded impact: requires actually possessing the leaked key and performing a real reinstall each time, and is explicitly documented in-code as an accepted no-backend trade-off (round-31/round-39 audit trail). Listed separately because it's a distinct code path from the trial guard. | Same three options (A/B/C) as the MAJOR finding above — they share one fix. |
| MINOR | `packages/ad_sdk/lib/src/utils/sensitive_data_redactor.dart:12-29` | `redactSensitiveData` only matches `key[:=]value`-shaped substrings (e.g. `gaid: X`, `"gaid":"X"`). A future log call that interpolates a raw GAID/IDFA/VIP-key value without that exact label shape immediately preceding it (e.g. `'device gaid is $gaid'`, or logging a bare value with no label) would pass through **unredacted**. No current call site does this — verified across every file read this round — but the redactor is a pattern-match safety net, not a structural guarantee. | Privacy/PII-in-logs risk is not eliminated, only currently unexploited; a future contributor adding a convenience debug log could reintroduce it without noticing. | **A)** Leave the regex as-is, add a CI grep/lint that flags any `SafeLogger.*` call interpolating a known-sensitive variable name without the expected `key: value` shape. **B)** Refactor sensitive logging call sites to pass structured fields to a typed redaction wrapper instead of freeform interpolated strings, closing the gap architecturally. **C)** Accept as low-risk today; revisit only if a future round adds an offending call site. |
| MINOR | `packages/ad_sdk/lib/src/vip/vip_manager.dart:198-223` | CRL (revocation list) self-attestation gap: on a device where no host-supplied public key has been configured yet, a **rooted** attacker could plant a self-signed CRL dated far in the future to permanently block real future revocations — but only on their own device, with no cross-user impact. | Already reviewed multiple times per in-code audit comments and explicitly scoped as "attacker already rooted, harms only themselves." Documented here for completeness, not because it's newly discovered. | Accept as-is; a real fix would require server-side revocation delivery, which conflicts with the SDK's stated zero-backend design goal. |
| NIT | `packages/ad_sdk/lib/src/core/ad_safety_config.dart` (whole file) | The frequency-cap/anti-fraud safety engine is implemented as 20+ top-level `static` mutable fields — a singleton by construction. | Correct and exhaustively audited for this SDK's stated single-account use case, but structurally forecloses any future multi-instance/multi-account requirement. | No action needed unless that requirement ever materializes; would need a real refactor (instance-based config) at that point, not a patch. |
| NIT | `packages/ad_sdk/lib/src/compliance/compliance_signing.dart:107` | Self-documented narrow gap: the keypair-mint lock is keyed globally rather than per-`FlutterSecureStorage`-instance, so two callers using *different* storage instances could theoretically collide. | Harmless today — every real call site uses the canonical `const FlutterSecureStorage()` — but the gap is real if that assumption ever changes. | Already flagged in-code by a prior audit round; no action required unless a caller starts using a non-canonical storage instance. |
| NIT | `packages/ad_sdk/lib/src/core/iab_storage.dart:99-101` | The iOS branch of TCF/GPP consent-string storage is self-documented as **never exercised on real hardware** — the iOS integration-test CI lane has been down since 2026-08-09. | Correctness of the iOS consent-read path is a documented, honest gap, not something this code-review-only audit can close. | Restore the iOS CI lane, or run the consent integration tests manually on a real iOS device/simulator before the next release that touches this file. |
| NIT | `packages/ad_sdk/lib/src/core/iab_storage.dart:482-502` | The 19 US-state GPP section bit-offset parsers are claimed in-code to have been verified against the IAB Tech Lab's reference `@iabgpp/cmpapi` encoder. This round had no network access to independently re-run that cross-check. | Not a defect — just an unverifiable-this-round claim. Flagging per the brief's instruction to say so explicitly rather than assume correctness. | Independently re-verify against `@iabgpp/cmpapi` (or the IAB's published test vectors) in a future round with network/tooling access. |
| NIT | Coverage disclosure — `packages/ad_sdk/lib/src/core/ad_manager.dart` (9,385 lines) | This round read, line-by-line: 100% of `adapters/*`, `consent/*`, `vip/*`, `widget/*` (+ related `core`/`utils` files), `state/*`, `compliance/*`, `config/*`, `monetization/*`, `adaptive/*`, the public barrel file, and `example/lib/main.dart`. `ad_manager.dart` itself — the 9,385-line central orchestrator — was read across roughly 3,300-3,500 lines (~37%), concentrated on every method the brief's focus areas flag as highest-risk: `initialize()`, `setConsent()`, `destroy()`, `showAppOpenAd`/`showInterstitial`/`showRewardedAd`, `canRequestAds`/footgun gating, the connectivity watch loop, `_retryRefillAds`, and the `_emit()` event chokepoint. **Not** personally read: `loadAppOpenAd`/`loadRewardedAd`'s own bodies (only their call sites), ~190 one-line `@visibleForTesting` debug getters/setters scattered through the file (grepped and spot-checked — none touch network/consent/revenue), and the compliance-export methods (covered instead from the `compliance/*` side). | Full disclosure per the brief's instruction to say so rather than assume unread code is fine. No fraud-relevant gap is believed to remain given the concentration of what *was* read, but this is a disclosed sampling boundary on one file, not a claim of 100% coverage of it. | A future round could finish the remaining ~63% of `ad_manager.dart` (the two `load*` bodies in particular) for full closure. |

## 4. What was checked and found genuinely fine

- **Provider abstraction (AppLovin MAX vs AdMob).** Both adapters
  implement `AdProviderAdapter` symmetrically for App Open, Interstitial,
  Rewarded, Banner, MREC, and Native formats; disposed-adapter/tombstone
  checks and `creativeId`/`isStaleAppLovinCallback`-based staleness guards
  prevent a callback from an old ad-load cycle from corrupting a new one.
  No provider-specific behavior was found leaking into shared code in a way
  that breaks the other provider (`applovin_adapter.dart`,
  `admob_adapter.dart`, `applovin_bridge.dart`, `gma_bridge.dart` read in
  full).
- **Offline / flaky connectivity.** Every native/platform-channel await in
  the connectivity-sensitive paths of `ad_manager.dart` carries an explicit
  5-20s timeout with a safe fallback on expiry; no unbounded `Completer`/
  `Future` was found. The connectivity-watch loop debounces and
  generation-tokens offline→online transitions and retries UMP consent on
  reconnect inside an unhandled-zone-error guard. `_retryRefillAds`
  correctly early-returns while offline, while a VIP entry is active
  (confirming `CLAUDE.md`'s claim), and once the daily cap is reached.
- **Ad-stacking / re-entrancy.** A single shared `_fullscreenBusyReason`
  mutex prevents App Open, Interstitial, and Rewarded from stacking on one
  another; `showAppOpenAdOnResume` correctly checks
  `AdScreenRouteLogger.isDialogOnTop` and skips while a modal is showing.
  `bypassVipGuard` re-checks both the consent gate and the mutex again
  *after* its on-demand ad load, closing a window where another fullscreen
  surface could otherwise land during the wait.
- **Widget lifecycle / memory leaks.** Every `StreamSubscription`/`Timer`/
  `AnimationController` created in `initState` across all ten widget files
  is cancelled/disposed in `dispose()`; `mounted`/`_isDisposed` checks guard
  every async callback into host code; banner/MREC ads are torn down (not
  just flagged) when routed away from, since the Flutter AdMob plugin has
  no runtime pause API. No static field was found holding a `BuildContext`
  or platform `Activity`/`Context` beyond its needed scope.
- **Trial mode (1 day) & VIP clock-tamper resistance.** `VipManager`
  maintains a wall-clock high-water mark plus a monotonic
  (`Stopwatch`-anchored) resync on foreground-resume to distinguish
  "clock genuinely advanced" from "clock was rolled back," with an
  asymmetric start/expiry check (`_isLive`) closing a real historical
  exploit (round-24). The one residual gap — a clock rollback applied
  *before* first launch — is explicitly documented as impossible to detect
  in pure Dart, not hidden.
- **VIP offline verification.** Signing is real Ed25519 via
  `package:cryptography`; only the public key is ever referenced in shipped
  `lib/` code (the private key exists only in dev-only CLI tools under
  `tool/`, which are gitignored where they'd contain key material).
  Redeemed keys bind to the live bundle ID (`package_info_plus`), are
  checked against an atomic in-flight claim plus a persisted ledger, and
  VIP stacking is capped (`maxVipStackDuration`) with provenance tracking
  that closes a revocation-laundering path.
- **Consent (GDPR/UMP/TCF/GPP/CCPA/COPPA/ATT).** `AdManager.initialize()`
  genuinely `await`s the UMP consent flow before native AppLovin/AdMob
  adapter init (round-71 fix, confirmed real by tracing the code, not the
  comment). TCF purpose-bitfield indices, the GPP two-segment split
  (round-56 fix), and CCPA/US-state GPP parsing were all traced and found
  correct; CCPA/DNS reaches **both** providers (`AppLovinMAX.setDoNotSell()`
  as well as AdMob). COPPA is correctly forwarded to AdMob; AppLovin has no
  runtime equivalent, which is honestly logged as `false` rather than
  silently dropped. Revocation (`ConsentManager.reset()`) unconditionally
  re-applies to both providers. Concurrent `set()`/`reset()` calls are
  serialized via an epoch counter so a slower, older write can never
  clobber a newer one.
- **Policy compliance.** Daily/hourly/session caps, the 30s (default 60s
  configurable) throttle, CTR-fraud detection, and progressive cooldown are
  internally consistent and not bypassable through normal app usage;
  `dryRun` is force-disabled in real release builds regardless of caller
  override. Every safety bypass (`bypassSafety`, `bypassVipGuard`) is
  recorded to an always-on, non-disableable, Ed25519-signable audit trail
  — `showAppOpenAd(bypassSafety: true)` is an intentionally unenforced
  back door (nothing stops a host from calling it outside the splash
  screen), but it is fully audited, and this is a pre-existing, disclosed
  design choice, not a new defect. The rewarded-interstitial disclosure
  screen is on by default (an AdMob policy requirement), and
  `native_ad_widget.dart` correctly renders AppLovin's required AdChoices
  badge.
- **Debug/dev-only surfaces.** `debug_ad_overlay.dart` and
  `revenue_panel.dart` are gated on `kDebugMode`, a compile-time constant
  the compiler folds away in release builds — verified as not
  runtime-bypassable.
- **Example app integration contract.** `example/lib/main.dart` matches
  every step of the contract `CLAUDE.md`/`README.md` document:
  `setNavigatorKey` before `runApp`, `adRouteObserver` +
  `AdScreenRouteLogger` registered in `navigatorObservers`, SDK
  `initialize()` called from the splash screen (not `main()`), correct
  ATT→UMP→initialize ordering, hard-cap timer, `markSplashActive/Inactive`,
  `incrementSplashCount`, `AdLoadingDialog.showAdBuffer()` before
  `showAppOpenAd(bypassSafety: true)`. No anti-pattern was found (no
  interstitial shown immediately on launch without a buffer dialog, no ads
  on app exit).
- **Public API surface.** The `applovin_admob_sdk.dart` barrel exports
  nothing sensitive — VIP-related exports are limited to
  `SignedVipKey`/verification functions (public-key verification only); no
  private key material or internal token is exposed anywhere in the public
  API.
- **Dependency/version hygiene.** `pubspec.yaml`'s dependency set matches
  its declared purpose exactly; `pubspec.lock` across all three lockfiles
  in the repo resolves only to `https://pub.dev`; the iOS `Podfile.lock`
  pins only official AppLovin/Google pods at versions consistent with
  `CLAUDE.md`'s documented pinning-wall combination.

---

*Prepared as an independent, read-only review across seven parallel/sequential
full-file passes. No code in this repository was changed as part of this
audit.*
