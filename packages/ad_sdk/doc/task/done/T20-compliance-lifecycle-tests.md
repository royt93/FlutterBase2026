# T20 — Test suite: compliance + lifecycle + network

- **REQ:** tất cả (gate chất lượng)
- **Priority:** P2 · **Severity:** — · **Status:** done (2026-07-07)
- **Files:** `packages/ad_sdk/test/` (200+ test sẵn có), CI `.github/workflows/test.yml`

## Mục tiêu (Why)
Mỗi fix ở T01–T19 phải có test bảo vệ khỏi hồi quy. Không mark task nào "done" nếu test tương ứng đỏ (theo Definition of Done ở `README.md`).

## Acceptance criteria (checklist theo nhóm)

**Consent (T01–T07):**
- [x] gate `canRequestAds` — `test/consent_gate_test.dart` group "canRequestAds gate" (closed→all loads skip; open→loads reach adapter; VIP precedence; not-initialised no-op).
- [x] npa khi consent=false — `test/admob_behavioral_test.dart` group "Non-personalized (npa) consent propagation" (6 cases incl. conservative default, accept/revoke flip).
- [x] không impression trước consent — `test/consent_gate_test.dart` group "show gate (T03)" (gate closed → `showInterstitial` fires `onDoneFlow(false)`, adapter never shows).
- [x] map CCPA/COPPA đúng — `test/admob_behavioral_test.dart` group "Restricted-data-processing (RDP/CCPA) consent propagation" (7 cases, RDP and npa proven orthogonal) + `test/ad_consent_test.dart` group "applyConsentToProviders (T04)" (COPPA-gap warning).
- [x] privacy options gọi UMP — `test/privacy_options_test.dart` group "showPrivacyOptions (T06)" + "isPrivacyOptionsRequired".
- [x] ATT ordering — `test/att_consent_test.dart` (notDetermined→authorized/denied branches, prompt-throws-degrades-to-denied); ordering itself is wired in host splash (no new observable branch to test per T07 doc).

**Network (T08–T10):**
- [x] offline→online refill (debounced) — `test/connectivity_refill_test.dart` group "offline → online refill" (7 cases: refill, no-op same-state, no refill going offline, flapping debounce, VIP skip, not-initialised skip).
- [x] banner offline→reload — `test/banner_ad_widget_test.dart` "banner collapses offline and reloads on reconnect".
- [x] isConnected pessimistic — **not pessimistic by design** (T10 doc: deliberately kept optimistic/last-known, documented engineering decision, not a bug). Added `test/connectivity_refill_test.dart` group "isConnected fallback (T10)" locking in the actual contract: `isConnected` mirrors last-known state from the connectivity watch when the native detector throws.
- [x] network error không backoff dài — subsumed by T08 connectivity-watch refill (per T10 doc); covered by the same `connectivity_refill_test.dart` reconnect-refill cases.

**Lifecycle (T11–T14):**
- [x] double-show guard — `test/admob_behavioral_test.dart` group "single-use / double-show guard" (second show while showing rejected; no reuse of disposed ad after dismiss).
- [x] banner 1-callback/1-load — `test/banner_ad_widget_test.dart` "repeated rebuilds trigger exactly one banner load".
- [x] stream close & dialog pop — `_eventStream` deliberately NOT closed (T13 doc: singleton, public `events` stream, guarded by `isClosed` — closing would break host subscribers; documented decision, not a gap). Dialog pop covered by `test/ad_loading_dialog_test.dart` (`resetState` pops a showing dialog; no-op when nothing showing).
- [x] route re-subscribe — `test/banner_ad_widget_test.dart` "route replace re-subscribes RouteAware to the new route (push→pop→push)".

**Provider (T15–T16):**
- [x] resolve id theo platform — `test/ad_config_platform_test.dart` group "resolvePlatformAdUnitId (T15)" (4 cases: android override, ios override, no override→fallback, empty-string treated as absent).
- [x] footgun id rỗng/sai định dạng — `test/ad_manager_core_test.dart` group "releaseFootgunWarnings" (T16 cases: empty rewardedId, empty required id, AppLovin-shaped id on AdMob provider, well-formed→clean, AppLovin empty id, non-ca-app-pub AppLovin ids exempt).

**Trial/VIP (T17–T19):**
- [x] clock rollback inactive — `test/vip_entry_test.dart` group "anti clock-rollback (T17)" (4 cases: `grantedAt` in future → inactive/remaining=zero even when not yet wall-clock-expired; normal entry still active; expired+rolled-back stays false).
- [x] grace-disabled footgun — `test/ad_manager_core_test.dart` "release + firstInstallVipGrace.disabled → one warning" / "...enabled (default) → no grace warning".
- [x] server validator path — no backend chosen (T18 doc: signed offline Ed25519 keys instead, explicit product decision, no server exists to test). Covered instead by `test/signed_vip_key_test.dart` (verify genuine/tampered/wrong-signer/malformed/empty/non-positive-seconds; redeem success/already-used/stack/invalid; widget redeem flow).
- [x] duration âm bị chặn — `test/vip_manager_robustness_test.dart` group "non-positive duration rejected" (zero and negative both assert-reject; rejected duration never creates/activates an entry).
- [x] purge — `test/vip_manager_robustness_test.dart` group "eager purge on load/redeem" (load() shrinks persisted store; addVip purges an entry that expires mid-session; redeem-style add purges too).
- [x] stacking cap — `test/vip_manager_stacking_test.dart` + `test/vip_manager_robustness_test.dart` group "maxStackDuration cap scope" (stacking clamps at cap; non-stacking grants explicitly NOT capped even far beyond it).

**CI:**
- [x] CI (`packages/ad_sdk`) xanh; `flutter analyze` sạch cả SDK và host — `.github/workflows/test.yml` has `sdk` job (`flutter analyze` + `flutter test` in `packages/ad_sdk`) and `host` job (same, repo root). Verified 2026-07-07: SDK 318/318 tests green, analyze clean; host 76/76 tests green, analyze clean.

## Ghi chú
- Chạy: `cd packages/ad_sdk && flutter test` và `flutter test` (repo root).
- Dùng `@visibleForTesting` hooks sẵn có: `debugSetAdapter`, `debugVipManager`, `debugEmit`, `releaseFootgunWarnings`, các `*Override` của ATT.

## Audit findings (2026-07-07)

Only one genuine test gap found and closed: `isConnected` getter's fallback-to-last-known-state on detector failure had no direct assertion (only the connectivity-watch refill *side effects* were tested). Added one test case to `test/connectivity_refill_test.dart`.

Two acceptance sub-items are **not testable as literal unit tests** because the underlying implementation deliberately made a different, documented choice than the literal wording (not a scope gap — see inline notes above): "isConnected pessimistic" (kept optimistic/last-known by design, T10) and "server validator path" (no backend exists by design, T18 — signed offline keys instead).

Two private-method behaviors have **no reachable test seam** and are left as a real, acknowledged gap (out of scope for a test-only audit — would require adding a new `@visibleForTesting` hook, which the audit was told not to invent):
- `_armSplashBudget()` cancelling a prior timer before arming a new one (`core/ad_manager.dart:408-413`) — only reachable via the real `initialize()`, which no existing test calls.
- `_scheduleFirstSecondaryLoad()` removing its old listener before re-adding (idempotent re-init guard, `core/ad_manager.dart:829-838`) — same reachability issue.

These are noted as FOLLOW-UP FINDINGS for a future task that's allowed to add a lib-code test seam (e.g. a `debugReinitializeForTest()` hook), not fixed here.
