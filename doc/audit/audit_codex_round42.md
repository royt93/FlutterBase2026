# Audit round 42 — codex (independent reviewer)

> Verbatim report from an isolated `codex exec --dangerously-bypass-approvals-and-sandbox`
> run on a detached-worktree copy of the repo at commit `ca7a36e`, given the same brief as
> the other two independent reviewers this round (see `audit_round42_consolidated.md` for
> the brief, method, and cross-verification of these findings against source).

# Independent security, lifecycle, and policy audit — round 42

Date: 2026-09-17
Package: `applovin_admob_sdk`
Checkout version: `2.9.21` (`packages/ad_sdk/pubspec.yaml:6`)
Latest pub.dev version: `2.9.21` (verified against the live pub.dev API on 2026-09-17; published at 2026-09-17T16:19:10Z)
Result: **2 BLOCKER, 2 MAJOR, 3 MINOR, 1 NIT**

## Executive verdict

**No — this SDK should not be used in a real production app as-is.** At minimum, the AppLovin native layout must include its mandatory privacy-information control, and the rewarded API must stop reporting `earned == true` when no ad was shown. Before release, the AppLovin rewarded callback correlation also needs a design that cannot assign an old ad's reward event to a new caller when `creativeId` is unavailable or reused, and the iOS example must use iOS AdMob test IDs so that the advertised cross-platform integration can actually be validated.

The package has substantial defensive engineering: native objects are generally disposed, callbacks are made one-shot, loads have watchdog/backoff behavior, reconnect causes refill, UMP is sequenced before provider initialization, COPPA is fail-closed for AppLovin, and signed VIP codes use real Ed25519 verification. Those strengths do not neutralize the policy and reward-integrity blockers below.

## Scope and method

I reviewed the package source under `packages/ad_sdk/lib/`, the integration example under `packages/ad_sdk/example/lib/`, and the tests under both requested test trees. I formed findings from the source itself and did **not** open any prior report under `doc/audit/`. Source comments sometimes refer to earlier rounds; those comments are part of the current implementation and were evaluated as claims, not treated as proof.

This was a read-only static audit. I did not run `flutter test` or `flutter analyze`, because dependency/tool bootstrap could mutate generated package state. I did not change repository source or dependency files. Current policy and integration requirements were checked against the linked official Google and AppLovin documentation.

## Findings

### 1. BLOCKER — Every AppLovin native ad omits the mandatory privacy-information icon

**Evidence:** `packages/ad_sdk/lib/src/widget/native_ad_widget.dart:662-697`

The package constructs the complete child tree passed to `MaxNativeAdView`. It includes icon, title, rating, media, body, and CTA components, but never includes `MaxNativeAdOptionsView`. AppLovin's current Flutter native-ad documentation explicitly says that, to comply with AppLovin policy, the ad **must** contain the Privacy Information icon, bound with `MaxNativeAdOptionsView` ([official AppLovin native-ad guide](https://support.applovin.com/en/max/flutter/ad-formats/native-ads)). This is not an optional host-app placement concern: the package itself owns this custom layout.

**Failure scenario:** Any production app renders `NativeAdWidget` while AppLovin is selected. The displayed native ad has no AppLovin privacy-information control, so every such impression is non-compliant and the user cannot open the linked privacy notice.

**Required fix:** Add a correctly sized and unobstructed `MaxNativeAdOptionsView` to the package-owned layout, following AppLovin's reference arrangement, and add a widget test that proves it is present for the AppLovin branch.

### 2. BLOCKER — `vipAutoGrant` reports a rewarded-ad completion and grants value when no ad was shown

**Evidence:** `packages/ad_sdk/lib/src/core/ad_manager.dart:7720-7724`, `:7746-7749`, `:7778-7791`; `packages/ad_sdk/example/lib/main.dart:2982-3015`; `packages/ad_sdk/test/ad_manager_core_test.dart:1722-1729`

For a VIP user, `showRewardedAd(vipAutoGrant: true)` deliberately skips the provider and calls `onEarnedReward(true)`. The public callback is named and documented as an earned-reward signal, not as a generic "grant an equivalent VIP benefit" result. The example demonstrates the concrete damage: its button says "Watch ad for +10 coins," then adds 10 coins whenever that boolean is true, including the no-ad VIP path. A unit test expressly locks in `earned == true` and zero provider show calls.

Google's current rewarded policy requires accurate disclosure of the action needed before each rewarded ad and delivery following completion of the required action ([official AdMob rewarded policy](https://support.google.com/admob/answer/7313578?hl=en)). Independently of whether an app is allowed to give VIPs free coins, representing "no ad occurred" through an API whose boolean means "ad reward earned" destroys the legally and economically important completion invariant. It also makes ordinary caller code—exactly like the bundled example—grant a reward without genuine ad completion.

**Failure scenario:** A VIP user enables the demonstrated option and taps "Watch ad for +10 coins." No ad loads or displays, but the callback says `true` and the app grants 10 coins. The UI disclosure is false and downstream analytics/entitlement code records an ad-earned reward that never occurred.

**Required fix:** Remove `vipAutoGrant` from the rewarded-ad completion path. If the product needs a VIP perk, expose a separate, explicitly named result/callback (for example, `RewardOutcome.vipBenefitGranted`) that can never be confused with provider-confirmed completion. `earned` must only become true in the native provider reward callback (or, where configured, after server-side verification).

### 3. MAJOR — AppLovin can assign a stale reward event to the next rewarded caller

**Evidence:** `packages/ad_sdk/lib/src/adapters/applovin_adapter.dart:572-641`, `:1844-1882`, `:1903-1948`

AppLovin uses one persistent listener and stores the current caller in the mutable `_rewardedDone` field. Stale-event rejection relies only on `MaxAd.creativeId`, and `_isStaleAd` deliberately accepts the event whenever either ID is empty or the IDs repeat. The reward callback then takes whichever callback is currently in `_rewardedDone`, clears it, and reports `earned: true` and `shown: true` without any other per-show identity.

Creative ID cannot safely serve as an ad-instance nonce. AppLovin documents Creative ID support as network/format dependent, with unsupported and limited cases ([official Creative Debugger support matrix](https://support.applovin.com/en/max/flutter/testing-networks/creative-debugger)). The code itself also acknowledges empty and repeated IDs. Therefore its guard becomes no guard precisely on supported real mediation paths where no unique ID is supplied.

**Failure scenario:** Show A loses its display confirmation and the SDK's show watchdog resolves caller A as skipped. A later load/show installs caller B in `_rewardedDone`. A delayed reward callback belonging to A then arrives with an empty or reused creative ID. It passes `_isStaleAd`, consumes caller B, and tells B that its ad was shown and its reward earned even if B has not completed. The event also carries B's pending-SSV flag, further misattributing identity.

**Required fix:** Do not expose a new rewarded show until all callbacks from the prior native show are impossible, or obtain/use a genuine native ad-instance identifier round-tripped through every callback. If the plugin API cannot provide that identity, fail closed for ambiguous reward events and redesign the timeout/reload state machine around a quarantine period. Tests must exercise a late A reward after B begins with both empty and repeated creative IDs.

### 4. MAJOR — The iOS example supplies Android AdMob test-unit IDs for every format

**Evidence:** `packages/ad_sdk/example/lib/main.dart:249-269`

The example puts Android test IDs into the common `bannerId`, `interstitialId`, `appOpenId`, `rewardedId`, `mrecId`, `nativeId`, and `rewardedInterstitialId` fields, while leaving all iOS overrides unset. Consequently, iOS resolves those Android IDs. Google publishes separate platform test IDs; for example, native is Android `.../2247696110` versus iOS `.../3986624511` ([official native template guide](https://developers.google.com/admob/flutter/native/templates)), and the same platform distinction applies to the other formats.

**Failure scenario:** A developer runs the package's advertised demo on iOS to validate the SDK. AdMob requests use Android units and fail rather than exercising banner, fullscreen, rewarded, app-open, or native behavior. That hides iOS-only integration and lifecycle failures and means the example does not demonstrate the package correctly on one of its two supported platforms.

**Required fix:** Populate `android*Id` and `ios*Id` for every supported AdMob format using Google's current platform-specific test units. Add an iOS configuration test that asserts each resolved unit differs from its Android counterpart and equals the published test unit.

### 5. MINOR — `NativeAdWidget` documents and accepts a medium AdMob template far below its recommended size

**Evidence:** `packages/ad_sdk/lib/src/widget/native_ad_widget.dart:57-71`, `:100-120`, `:435-452`

The default template is `TemplateType.medium`, but the API accepts any `double` height without validation and its class documentation recommends `NativeAdWidget(height: 120)`. That wraps the provider view in a 120-pixel `SizedBox`. Google's current template guide recommends a minimum height of 320 for medium (and 90 for small) ([official native template sizing](https://developers.google.com/admob/flutter/native/templates#display_ad)). A host following the package's own example can therefore constrain or clip a medium native view, including provider-rendered disclosure/assets.

**Failure scenario:** A developer copies `const NativeAdWidget(height: 120)` without switching to the small template. On either platform, the 320-high medium template is forced into a 120-high viewport; content can overflow or be clipped, producing a broken or potentially non-compliant native presentation.

**Required fix:** Enforce template-appropriate minimums for the AdMob branch (at least 90/320), change the example to `TemplateType.small` for a compact layout, and document/provider-test AppLovin sizing separately.

### 6. MINOR — AVP2's app binding fails open if package identity cannot be read

**Evidence:** `packages/ad_sdk/lib/src/vip/vip_manager.dart:1331-1366`; `packages/ad_sdk/lib/src/vip/signed_vip_key.dart:225-242`

AVP2 signs an allowed bundle-ID list, which is a useful mitigation against copying a code into another app. But if `PackageInfo.fromPlatform()` throws, redemption logs a warning and passes `null`; verification checks the bundle only when the current ID is non-null and non-empty. This changes an asserted security property into a best-effort property exactly when platform-channel registration or execution is unhealthy.

**Failure scenario:** A repackaged app or an app with a broken `package_info_plus` channel presents an otherwise valid AVP2 code minted for another bundle. The package-ID read throws, the bundle check is skipped, and the code redeems.

**Required fix:** Fail closed for AVP2 when the current bundle ID cannot be obtained. AVP1 can retain its legacy behavior because it carries no app binding.

### 7. MINOR — Public `bypassSafety` can disable all app-open frequency protection from any call site

**Evidence:** `packages/ad_sdk/lib/src/core/ad_manager.dart:7036-7057`

`showAppOpenAd` exposes `bypassSafety: true` publicly. The source accurately admits that it is not restricted to splash, bypasses caps/throttling, and can cause policy violations; `callSiteTag` merely records a caller-supplied, in-memory audit entry. The need for a cold-start exception is understandable, but the API turns a package advertised as providing safety caps into an unenforced integration convention.

**Failure scenario:** A host copies the splash invocation into resume/navigation code or wraps it in a helper that always sets the flag. App-open ads can then be displayed without the SDK's hourly/daily/session caps or 60-second throttle, including adjacent fullscreen presentations.

**Required fix:** Make the bypass private to a dedicated one-shot splash controller/token, enforce lifecycle state and one-use semantics, and remove the general public boolean.

### 8. NIT — Public VIP-validator documentation contradicts release behavior

**Evidence:** `packages/ad_sdk/lib/src/config/ad_config.dart:489-492`; `packages/ad_sdk/lib/src/vip/vip_manager.dart:1706-1727`

`AdConfig.vipKeyValidator` says null means every key is accepted. The implementation only does that in debug/profile; release builds reject every key. The implementation is the safer behavior, but the public API documentation is materially wrong for integrators.

**Failure scenario:** An app relies on the docstring while building a release flavor and discovers that all local VIP redemption fails after shipment.

**Required fix:** State explicitly that null accepts arbitrary input only in debug/profile and rejects all input in release; recommend `redeemSignedKey` for backend-free production use.

## Subsystem conclusions

### Cross-platform provider abstraction

The core ID resolver supports Android/iOS overrides, and the AppLovin demo configuration correctly branches by `Platform.isIOS`. Provider adapters translate their respective APIs rather than assuming GMA object semantics on MAX. AdMob request configuration uses the plugin's integer COPPA flags and extras, while AppLovin's bridge uses its boolean privacy calls. I found no production-library platform-channel argument-type mismatch.

The abstraction is nevertheless not production-correct on both platforms as delivered: the example cannot validate AdMob on iOS (finding 4), and the package-owned AppLovin native branch is non-compliant on both operating systems (finding 1). The IAB preference reader also states at `packages/ad_sdk/lib/src/core/iab_storage.dart:39-41` that its iOS branch has never been exercised on a device. That is a verification gap, not proof of a defect, but it is significant for a package claiming both platforms.

### Offline/no-network behavior

Loads generally fail closed when the connectivity detector is ready: they are skipped while offline, load failures enter slot backoff/cooldown, load watchdogs prevent a permanent loading state, an offline-to-online transition triggers refill, and a periodic retry is retained as a backstop (`packages/ad_sdk/lib/src/core/ad_manager.dart:6895-6999`, `:8736-8905`). Before the detector is ready the code deliberately assumes online so a broken detector cannot black-hole ads; native SDK failures then drive ordinary backoff. UMP retry is also connected to reconnection.

Already cached fullscreen ads may still be shown after connectivity is lost. That is reasonable: the provider owns whether its cached creative remains showable, and native failure/dismiss callbacks plus the show-confirmation watchdog resolve the Dart caller. There is no indefinite SDK-level wait in the traced paths. Behavior is broadly consistent between providers, though the provider SDKs can naturally differ in cache validity and failure timing.

Signed VIP verification is cryptographically offline but redemption is deliberately blocked without connectivity (`packages/ad_sdk/lib/src/vip/vip_manager.dart:1257-1260`, `:1315-1327`). This is a documented product gate, not a technical necessity and not an availability bug hidden by the implementation.

### Ad lifecycle correctness

AdMob disposes superseded, failed, dismissed, and teardown-time ad objects; per-widget banner/MREC/native maps are cleaned. AppLovin clears global listeners, cancels timers, destroys widget ad views with bounded detached-view retry, and tombstones disposed native instances (`packages/ad_sdk/lib/src/adapters/admob_adapter.dart:471-567`; `packages/ad_sdk/lib/src/adapters/applovin_adapter.dart:859-916`). App-open freshness is bounded, callbacks are normally one-shot, inline widgets do not retain `BuildContext`, and route/visibility/active-state gates suppress hidden inline inventory.

Banner, MREC, interstitial, and the AdMob rewarded implementation did not reveal a verified native-object leak or unconditional hang in static tracing. App-open has explicit load/show budgets and restores inline visibility on completion. Reward grant integrity is not acceptable because of findings 2 and 3. Native presentation is not acceptable because of findings 1 and 5.

One test file is stale in a way that helps explain the callback gap: `packages/ad_sdk/test/interstitial_rewarded_watchdog_test.dart:1-22` asserts there is no interstitial/rewarded watchdog or late-event race, while `showRewarded` now calls `AdSlot.beginShow`, which arms the show-confirmation watchdog. No test covers "cycle A times out, cycle B starts, A reward arrives with empty/reused creative ID."

### One-day trial mode

The release default is a 24-hour first-install VIP grant (`packages/ad_sdk/lib/src/config/ad_config.dart:523-545`). Time rollback within the same stored state is mitigated by a persisted high-water wall-clock plus a foreground monotonic anchor (`packages/ad_sdk/lib/src/vip/vip_manager.dart:300-399`), and the liveness check also consults raw device time to prevent a poisoned future timestamp from creating permanently active VIP. This is stronger than a plain `DateTime.now()` expiry, but no purely local design provides a trustworthy clock across process/device resets.

Bypassability is explicitly accepted and explained. iOS stores an already-granted flag in Keychain, which normally survives reinstall. Android relies on Auto Backup and intentionally returns "not already granted"; clearing storage, disabling backup, changing account, or reinstalling without restored backup grants another day (`packages/ad_sdk/lib/src/vip/_first_install_guard.dart:8-88`, `:137-155`). A device wipe also bypasses iOS. The source documents this as an offline/no-backend trade-off, including its abuse cost and the need for a server if it is a hard business requirement. I therefore do not reclassify that disclosed constraint as a new defect. Hosts must not market this as attacker-proof, and should disable the grace or add a server/account claim if repeated one-day trials are economically material.

### VIP activation without a backend

The secure production path is not a shared secret hidden in the app. AVP1/AVP2 codes carry a payload and Ed25519 signature; the app ships only a public key and verifies the signature (`packages/ad_sdk/lib/src/vip/signed_vip_key.dart:86-120`, `:133-249`). Decompilation therefore does not reveal the private signing capability, so an attacker cannot forge new valid codes merely from the package. AVP2 also signs expiry and bundle binding. Finding 6 is the exception to that binding's enforcement.

Replay is inherent and explicitly accepted: a redeemed-ID ledger blocks reuse on one device, but a copied valid code can be redeemed once on every device because there is no central claim service (`packages/ad_sdk/lib/src/vip/vip_manager.dart:1240-1255`). AVP2 expiry/bundle binding and revocation reduce impact but do not eliminate cross-device reuse; AVP1 remains accepted indefinitely for compatibility and lacks both fields (`packages/ad_sdk/lib/src/vip/signed_vip_key.dart:95-100`). If VIP represents a monetized durable entitlement, a backend is required despite the package's "no backend" constraint.

The generic `vipKeyValidator` path is only as secure as the host callback. The demo's local map at `packages/ad_sdk/example/lib/main.dart:199-233` is trivially recoverable and forgeable/replayable and is correctly labelled demo-only; it must not be copied into production. The signed-key path is the only credible backend-free authenticity mechanism here.

### Consent and privacy regulation wiring

The default startup sequence requests UMP before initializing either ad provider, reads TCF purpose consent, gates ad requests, writes GMA request configuration (including COPPA), sends RDP for US-state opt-out, and supplies AppLovin `hasUserConsent`/`doNotSell` before MAX initialization. Current Google guidance confirms that UMP consent is not a single boolean and that purpose/vendor consent matters ([official UMP GDPR guide](https://developers.google.com/admob/flutter/privacy/gdpr)); MAX also reads the IAB TCF/Additional Consent strings written by the CMP. The implementation's readback of purpose 1/3/4 is therefore a conservative ad/personalization gate, not the sole consent propagation channel.

For US privacy, GPP sections and the legacy US privacy string feed the do-not-sell decision, AdMob receives RDP extras, and AppLovin receives `setDoNotSell`. For a child-directed user the SDK configures GMA's COPPA treatment and refuses to initialize AppLovin because MAX does not expose an equivalent runtime flag and AppLovin prohibits child-directed use. That fail-closed behavior is appropriate.

No library can itself guarantee "consent for all countries." Coverage still depends on the publisher configuring and publishing the correct UMP regional messages, declaring every mediated vendor, setting age-restriction/COPPA truthfully, maintaining a privacy policy, and updating for new laws/GPP sections. The package exposes those host responsibilities and I did not find a verified silent country-specific bypass in the current paths. However, the untested iOS IAB-storage branch should be device-validated before production.

### Current ad-policy compliance

The SDK includes sensible caps, fullscreen mutual exclusion, natural-break-oriented APIs, inline hiding around fullscreen ads, app-open freshness checks, and consent gates. AdMob's app-open policy still requires launch/resume context and no disruptive adjacency; banner/native placement and rewarded opt-in/disclosure ultimately remain host responsibilities. AppLovin similarly requires compliant placement and host-controlled consent/CMP setup.

The package is not policy-safe as-is because its own AppLovin native UI violates a mandatory layout requirement (finding 1), its demonstrated rewarded contract can claim completion without the disclosed action (finding 2), and its public app-open bypass can remove the very caps advertised as protection (finding 7). An in-memory audit log does not prevent a policy breach.

## Production decision

**Direct answer: No. Do not ship this SDK unchanged in a production app.**

Production use becomes conditional only after:

1. adding and verifying the mandatory AppLovin native privacy-information view;
2. making `earned == true` impossible without the current native rewarded completion (or confirmed SSV), including removing `vipAutoGrant` from that boolean contract;
3. resolving or conservatively failing closed on ambiguous AppLovin late reward callbacks;
4. correcting every iOS AdMob test unit in the example and running real-device lifecycle/consent tests on both Android and iOS; and
5. either constraining native sizes and the app-open bypass in code or clearly removing the claim that the SDK itself enforces those safety properties.

For any app where a one-day trial or VIP is financially meaningful, there is an additional business condition: accept the documented reinstall/cross-device replay risk explicitly, or add a server-backed account clock and one-time code claim. No client-only revision can make those properties authoritative.
