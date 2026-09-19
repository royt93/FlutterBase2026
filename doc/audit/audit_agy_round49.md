# Audit Round 49 — Independent Adversarial Review

**Audited version:** `applovin_admob_sdk` 3.0.1 (HEAD at `5e63d6b`)  
**Scope:** Dual-provider correctness, offline/flapping resilience, lifecycle/memory management, trial mode, VIP cryptographic security, consent/privacy (GDPR/UMP/CCPA/COPPA), and AdMob/AppLovin ad network policy compliance.

---

## Executive Summary

Audit Round 49 performed an independent, adversarial code walkthrough of `packages/ad_sdk/` across all core orchestration paths, adapter implementations, widget lifecycle controllers, cryptographic signing routines, and privacy/consent management.

- **BLOCKER:** 0
- **MAJOR:** 0
- **MINOR:** 1 (`dart run` build-hook stdout pollution in VIP CLI tools & tests)
- **NIT:** 1 (Documentation in `tool/vip_mint.dart` and `tool/vip_crl_mint.dart` recommends `dart run` instead of `dart` or `dart run --no-build-hooks`)

---

## Detailed Findings

### R49-01 — MINOR / TOOLING: `dart run` stdout build-hook pollution corrupts VIP CLI piped output & breaks subprocess test suite

- **File Path:** [`packages/ad_sdk/tool/vip_mint.dart`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/.claude/worktrees/audit-round44/packages/ad_sdk/tool/vip_mint.dart#L4-L88), [`packages/ad_sdk/tool/vip_crl_mint.dart`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/.claude/worktrees/audit-round44/packages/ad_sdk/tool/vip_crl_mint.dart#L1-L100), [`packages/ad_sdk/test/vip_cli_security_test.dart`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/.claude/worktrees/audit-round44/packages/ad_sdk/test/vip_cli_security_test.dart#L49-L155)
- **Severity:** MINOR
- **Concrete Failure Scenario:**
  1. In Dart 3.9+ / Flutter 3.35.1 with build hooks enabled, invoking a tool script via `dart run tool/vip_mint.dart ...` causes the Dart toolchain itself to emit diagnostic text (`Running build hooks...`) to `stdout` before the Dart program executes.
  2. In [`packages/ad_sdk/tool/vip_mint.dart#L87`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/.claude/worktrees/audit-round44/packages/ad_sdk/tool/vip_mint.dart#L87), the script prints the minted key string (`print(code)`).
  3. When a developer or CI automation script captures stdout via:
     ```bash
     MINTED_KEY=$(dart run tool/vip_mint.dart --priv-file .vip-private-key --days 30)
     ```
     or when subprocess integration tests execute via `Process.start('dart', ['run', ...])` (as in [`vip_cli_security_test.dart#L56`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/.claude/worktrees/audit-round44/packages/ad_sdk/test/vip_cli_security_test.dart#L56)), the captured stdout contains:
     ```text
     Running build hooks...AVP2.<payload>.<sig>
     ```
  4. Attempting to redeem this captured string in [`VipManager.redeemSignedKey`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/.claude/worktrees/audit-round44/packages/ad_sdk/lib/src/vip/vip_manager.dart#L530) or verify it with [`verifySignedVipKey`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/.claude/worktrees/audit-round44/packages/ad_sdk/lib/src/vip/signed_vip_key.dart#L133-L138) fails with `VipKeyException: bad format (expected AVP1|AVP2.<payload>.<sig>)` because the prefix check fails.
  5. The same issue occurs for `CRL1.` strings emitted by `tool/vip_crl_mint.dart`.
- **Recommended Fix:**
  - In `test/vip_cli_security_test.dart`, change `_runDart` to execute `'dart'` with `[_join('tool', script), ...args]` (direct compilation without `run`), or pass `--no-build-hooks` to `dart run`.
  - In `tool/vip_mint.dart` and `tool/vip_crl_mint.dart` header docstrings, update recommended shell command examples from `dart run tool/vip_mint.dart` to `dart tool/vip_mint.dart` or `dart run --no-build-hooks tool/vip_mint.dart`.

---

## Verification Across The 7 Scope Areas

### 1. Dual-Provider Correctness (AppLovin vs AdMob)
- **Banners & MRECs:** Both providers register instances via [`InlineAdInstanceRegistry`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/.claude/worktrees/audit-round44/packages/ad_sdk/lib/src/adapters/inline_ad_instance_registry.dart). Fullscreen presentation holds (`InlineHideReason.fullscreen`) and route-pause holds (`InlineHideReason.routePaused`) propagate cleanly on both providers.
- **Native Ads:** AdMob natively renders via Google templates (`TemplateType.small` / `TemplateType.medium`); AppLovin renders through [`_AppLovinMaxNativeView`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/.claude/worktrees/audit-round44/packages/ad_sdk/lib/src/widget/native_ad_widget.dart#L577) with dedicated yellow compliance `"Ad"` badging. Disposed instances are tracked in a bounded `LinkedHashSet` (200 entries max) to prevent memory leaks in scrollable feeds. Cross-session callback isolation via `capturedAdapter` identity check ([`native_ad_widget.dart#L604`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/.claude/worktrees/audit-round44/packages/ad_sdk/lib/src/widget/native_ad_widget.dart#L604)) is verified sound.
- **Rewarded Interstitial:** Google AdMob properly loads and presents native `RewardedInterstitialAd`; AppLovin MAX does not support this ad unit type and safely treats `loadRewardedInterstitial` / `showRewardedInterstitial` as documented no-ops, returning `RewardResult.skipped`.

### 2. Offline / No-Network Behavior
- **Connectivity Monitoring:** [`AdManager`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/.claude/worktrees/audit-round44/packages/ad_sdk/lib/src/core/ad_manager.dart#L8826) initializes `ConnectionNotifierTools` with pre-ready fallbacks (`_connectivityReady` flag).
- **Flap Resilience:** When network transitions `online → offline → online`, [`_onConnectivityChanged`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/.claude/worktrees/audit-round44/packages/ad_sdk/lib/src/core/ad_manager.dart#L8872) debounces the reconnect event (`_reconnectDebounce = 2s`). Any intermediate `online → offline` transition cancels the pending `_reconnectDebounceTimer`, ensuring stale refill jobs never fire while offline.
- **Retry Timers:** Slot reloads in offline state exit early without consuming error backoff budgets or corrupting safety rate limiters.

### 3. Ad Lifecycle Correctness & Memory Leaks
- **Teardown Serialization:** [`AdManager.destroy()`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/.claude/worktrees/audit-round44/packages/ad_sdk/lib/src/core/ad_manager.dart#L6366) uses `_destroyInFlight` future-coalescing and increments `_initGen` to prevent interleaved init/destroy races.
- **Observer & Stream Teardowns:** `WidgetsBindingObserver` is unregistered, `_eventStream` is closed with a 2-second timeout, `_eventLog` is flushed with a 2-second timeout, and all active slot ValueNotifiers are cleanly disposed.
- **Dialog Identity:** [`AdLoadingDialog`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/.claude/worktrees/audit-round44/packages/ad_sdk/lib/src/widget/ad_loading_dialog.dart#L97) removes dialog routes by explicit object identity (`nav.removeRoute(route)`), avoiding popping unrelated routes pushed on top.

### 4. Trial Mode (1 Day)
- **Storage & Anti-Abuse:** [`FirstInstallGuard`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/.claude/worktrees/audit-round44/packages/ad_sdk/lib/src/vip/_first_install_guard.dart) writes to iOS Keychain with `kSecAttrAccessibleAfterFirstUnlock` (`ad_sdk_first_install_granted_v1`). Android relies on Auto Backup for SharedPreferences.
- **Clock Rollback Protection:** [`VipManager._effectiveNow()`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/.claude/worktrees/audit-round44/packages/ad_sdk/lib/src/vip/vip_manager.dart#L374) enforces monotonic session clock validation against `_sessionClockStopwatch` and persists the highest-observed wall clock as a high-water mark.

### 5. VIP Activation Security (No Backend)
- **Ed25519 Cryptography:** [`SignedVipKey`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/.claude/worktrees/audit-round44/packages/ad_sdk/lib/src/vip/signed_vip_key.dart#L121) signs binary UTF-8 payloads with Ed25519 (`package:cryptography`). Keys cannot be forged without the private key.
- **Format Integrity:** Format downgrade (AVP2 → AVP1) is impossible because field count assertions (`expectedFields == 2 ? 4 : 2`) fail against the signed payload, and modifying payload bytes breaks the cryptographic signature.
- **Replay / Multi-device Protection:** Keys are bound to app bundle IDs, subject to expiration timestamps, tracked per-device via `_redeemedKeyLedger` (Keychain/Encrypted store), and protected against in-flight double-tap races via `_signedKidsInFlight`.

### 6. Consent & Privacy (GDPR / UMP / CCPA / COPPA)
- **UMP Gating:** [`AdManager.initialize`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/.claude/worktrees/audit-round44/packages/ad_sdk/lib/src/core/ad_manager.dart#L1498) fails closed in release mode if UMP consent is unresolved, preventing unconsented ad requests.
- **TCF String Integrity:** [`applyConsentToProviders`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/.claude/worktrees/audit-round44/packages/ad_sdk/lib/src/core/ad_consent.dart#L164) checks `IabStorage.keyTcfString` and avoids overwriting AppLovin's TCF vendor consent when a certified CMP string exists.
- **COPPA Handling:** AdMob passes `tagForChildDirectedTreatment: yes` and `tagForUnderAgeOfConsent` before initializing mediation adapters. AppLovin adapter refuses initialization on child-directed configurations.
- **Separation of Consent vs Privacy Axis:** `AdManager.setConsent` uses `qualifiesAsConsentFlow: false` for CCPA-only updates (`setDoNotSell`), ensuring CCPA updates do not bypass GDPR consent checks.

### 7. Policy Compliance
- **Attribution & Transparency:** Rewarded and Rewarded Interstitial formats include built-in opt-in disclosure dialogs ([`_showRewardDisclosure`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/.claude/worktrees/audit-round44/packages/ad_sdk/lib/src/core/ad_screen.dart#L400)) before ad playback.
- **Accidental Click Mitigation:** 1-second loading buffer ([`AdLoadingDialog.showAdBuffer`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/.claude/worktrees/audit-round44/packages/ad_sdk/lib/src/widget/ad_loading_dialog.dart#L159)) precedes fullscreen ad display.
- **Placement & Rate Limits:** 30-second minimum interval throttle between fullscreen ads, daily/hourly placement caps, and suspicious click-spam progressive throttling are strictly enforced by [`AdSafetyConfig`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/.claude/worktrees/audit-round44/packages/ad_sdk/lib/src/core/ad_safety_config.dart).
- **Modal Collision Avoidance:** App Open ads on resume check [`AdScreenRouteLogger.isDialogOnTop`](file:///Users/LoiTP/StudioProjects/roy/applovin_admob_sdk/.claude/worktrees/audit-round44/packages/ad_sdk/lib/src/core/ad_route_observer.dart) to avoid displaying over active dialogs.

---

## Scores

- **Production-Readiness Score:** `9.5 / 10`  
  *Packaging, comprehensive public API stability golden tests, thorough documentation, and 2,160+ passing tests demonstrate high maturity. Deducted 0.5 for minor CLI build-hook output in tool scripts.*
- **Safety Score:** `9.8 / 10`  
  *Exception-guarded zone error handlers, strict fail-closed GDPR/UMP gates, robust Ed25519 offline verification, leak-free teardown cascades, and conservative policy-compliant ad pacing.*
agy exit=0
