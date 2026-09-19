# Audit round 45 — consolidated verdict

**Status update (2026-09-19):** all 4 findings below (R45-01 MAJOR, R45-02/03/04
MINOR) have been fixed, TDD, same-day. See `CHANGELOG.md`'s `[Unreleased]`
section for the exact fix per finding and the new regression tests
(`test/applovin_adapter_test.dart`, `test/native_ad_widget_test.dart`,
`test/ad_manager_core_test.dart`). `flutter analyze` clean; each touched
test file passes in full isolation (88/88, 4/4, 31/31, 265/265). The
governing verdict below is otherwise unchanged as the historical record of
what round 45 found — **not yet republished to pub.dev** as of this
update; still on 3.0.0 pending a version bump + publish decision.

**Date:** 2026-09-18
**Codebase version audited:** 3.0.0 (`packages/ad_sdk/pubspec.yaml`), matches pub.dev `applovin_admob_sdk` 3.0.0, published within the hour of this audit (analysis still pending on pub.dev's side — no score/warnings available yet).
**Method:** three fully independent passes over 8 scope areas (dual-provider correctness Android+iOS, offline/no-network behavior, ad-type lifecycle & memory safety, 1-day trial mode, offline VIP activation by code with no backend, consent for every jurisdiction across AdMob+AppLovin, AdMob/AppLovin policy compliance, example-app integration contract), run in parallel with no visibility into each other's output:

| Pass | Environment | Result file | Verdict as filed |
|---|---|---|---|
| In-session Claude, 6 parallel from-scratch sub-agents + one hand-verified item | real worktree, full `CLAUDE.md`/memory access | `audit_claude.md` | **Conditional — 1 MAJOR (R45-01)** |
| `codex exec --dangerously-bypass-approvals-and-sandbox` | isolated throwaway copy, no `.git`, no `doc/audit/` | `audit_codex.md` | **No — 1 MAJOR, 3 MINOR** |
| `agy --dangerously-skip-permissions` | isolated throwaway copy, no `.git`, no `doc/audit/` | `audit_gemini.md` | **Yes — absolute PASS, all 8 areas** |

## Why the verdicts disagree, and which one governs

Claude's own sub-agent pass and `agy`'s pass made the **same mistake** on the same finding: both re-read `lib/src/core/ad_consent.dart:164-168` — the exact lines round 44's fix 3/3 touched — confirmed the guard is genuinely there, and stopped. Neither traced the *other* call site (`lib/src/adapters/applovin_adapter.dart:816-829`) that calls the same native `setHasUserConsent` API, unconditionally, before SDK init — which is actually the primary delivery path on an ordinary cold start, not a rare fallback. `codex exec` asked "where else does this call happen" instead of only re-checking the commit's own diff location; the finding was then independently re-verified by hand against the real worktree source (not codex's citations) and confirmed genuine.

This is the identical failure shape flagged in **round 44's own consolidated verdict**: verifying that consent *propagates* correctly without asking whether *every code path that computes the value being propagated* has a valid basis. That lesson from round 44 did not fully carry over into how round 45's sub-agents searched. Recorded as a process note for future rounds: when a "fix" touches one call site of a native consent/privacy setter, grep every other caller of that same native method before declaring the class of bug closed.

`agy`'s report additionally headers the package as version "2.9.23" — stale and factually wrong; the isolated copy it worked from has `pubspec.yaml: 3.0.0`. Combined with its unconditional PASS (its historical pattern per project memory — see `audit-must-be-slow-and-adversarial`), its verdict on the consent section carries no independent weight here.

**Governing verdict for this round: CONDITIONAL — do not ship 3.0.0 AppLovin traffic to EEA/UK/Switzerland users until R45-01 is fixed.** Everything else audited across all three passes — dual-provider parity, offline/no-network handling, ad lifecycle/memory safety, trial-mode tamper resistance, VIP Ed25519 crypto and replay/stacking logic, general AdMob/AppLovin policy compliance, and the example app's fidelity to the integration contract — is solid and consistent across all three independent reviewers, with no new BLOCKER/MAJOR.

## Confirmed MAJOR finding (fix before EEA/UK/CH production use)

### R45-01 — AppLovin's pre-init consent call still overrides UMP/TCF vendor consent
`lib/src/adapters/applovin_adapter.dart:816-829` calls `AppLovinMAX.setHasUserConsent(consent.hasUserConsent)` unconditionally, before `_bridge.initialize()` runs and before AppLovin ever gets a chance to read the real IAB TCF string UMP already wrote to device storage. Round 44's fix (`ad_consent.dart:164-168`) added exactly the right guard — skip the override when a real TC string exists — but only on the *post-init* `applyConsentToProviders()` path, which is not what runs on an ordinary cold start (that function only fires once the SDK is already initialised; before that, `setConsent()` just buffers). The unguarded pre-init call is therefore the one that actually reaches AppLovin first on every normal app launch.

**Consequence:** a returning EEA user who granted purposes 1/3/4 but denied AppLovin as a vendor can still have AppLovin see `hasUserConsent=true` on every subsequent cold start, overriding the vendor-specific TCF decision the round-44 fix was written (as a BREAKING 3.0.0 change) to respect. This is a real GDPR/TCF and AppLovin-policy exposure, not a documented trade-off.

**Fix:** apply the same `hasIabTcfString` check to the pre-init call site before `_bridge.initialize()`. Keep `setDoNotSell` unconditional (no TCF-equivalent signal for CCPA). Add a cold-start regression test — the current `test/applovin_adapter_test.dart:232-251` actually asserts the *unconditional* pre-init call happens, and `test/r44_applovin_tcf_gate_test.dart` only covers the post-init function, so today's test suite would not catch a correct fix without also being updated.

Everything else codex flagged (R45-02 native-click-after-dispose, R45-03 silent rewardedInterstitial no-op on AppLovin, R45-04 warning-only test-ID validation) is real but MINOR — none of them block a production decision on their own; fix opportunistically.

## Answer to "should we use this SDK in our production app?"

**Yes, once R45-01 is fixed — not before, if the app will serve any EEA/UK/Switzerland users through the AppLovin path.** If the production app is AdMob-only, or has no EEA/UK/CH traffic at all, R45-01 does not apply and the SDK is production-ready as of 3.0.0 today; ship it. If AppLovin serves EEA/UK/CH traffic, treat R45-01 as a release blocker for that traffic — it is a small, well-scoped fix (one guard clause plus a regression test), not a redesign, and should ship as a 3.0.1 patch before onboarding regulated-region users onto the AppLovin path.

Every other area this round — cross-platform dual-provider parity, offline resilience, ad lifecycle/memory safety, the 1-day trial and no-backend VIP activation cryptography, and general AdMob/AppLovin policy compliance — holds up under three independent adversarial passes and is ready for production use as designed, including its already-documented, deliberate trade-offs (Android's no-backend trial/VIP reset on data-clear, no cross-device replay prevention for VIP codes, the `private_key.pepk` git-history debt already tracked in `CLAUDE.md`).
