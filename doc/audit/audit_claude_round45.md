# Audit round 45 — Claude (in-session), independent direct-read pass

**Date:** 2026-09-18
**Codebase version audited:** 3.0.0 (`packages/ad_sdk/pubspec.yaml`) — confirmed matches pub.dev (`applovin_admob_sdk` 3.0.0, "published in last hour" at audit time, analysis pending).
**Method:** 6 parallel from-scratch sub-agent passes (one per scope area below), each re-tracing runtime mechanism against the real worktree source — not diffing since round 44, not trusting prior round comments at face value — plus one item (R45-01) I re-verified myself by hand after an external pass (`codex exec`) flagged it, because my own sub-agent and the independent `agy`/Gemini pass both missed it. Run alongside two fully independent external passes in throwaway isolated copies (`codex exec --dangerously-bypass-approvals-and-sandbox`, `agy --dangerously-skip-permissions`) with no visibility into this file or each other — see `audit_codex.md` / `audit_gemini.md`, consolidated verdict in `audit_round45_consolidated.md`.

## Executive verdict

**CONDITIONAL — do not ship 3.0.0 AppLovin traffic to EEA/UK/Switzerland users until R45-01 is fixed.** Everything else audited this round (dual-provider parity, offline handling, ad lifecycle/memory, trial mode, VIP crypto, AdMob/AppLovin policy compliance, example app contract) is solid, matches documented accepted trade-offs, and turned up no new BLOCKER/MAJOR.

| # | Finding | Severity | Status |
|---|---|---|---|
| R45-01 | AppLovin **pre-init** consent path still unconditionally calls `setHasUserConsent`, bypassing the round-44 TCF-string guard that only covers the *post-init* path | **MAJOR** | New, confirmed by hand + independently by codex |
| R45-02 | AppLovin native ad click counted/emitted after widget disposal (no tombstone check, unlike the revenue callback) | MINOR | New (codex) |
| R45-03 | `rewardedInterstitial` silently no-ops on AppLovin through the provider-neutral API, no explicit "unsupported" signal | MINOR | New (codex), documented root cause, weak contract |
| R45-04 | Public AdMob test ad-unit IDs left in release builds only trigger a log + stripped `assert` | MINOR | Known footgun, still warning-only |

No other new findings across lifecycle, trial/VIP, offline, general policy compliance, or the example app — see per-area detail below.

## R45-01 — AppLovin pre-init consent overrides UMP/TCF vendor consent (MAJOR)

**Why my own process missed this first, and why that matters:** my consent sub-agent (and, independently, `agy`) both re-read `lib/src/core/ad_consent.dart:164-168` — the exact lines round 44's fix 3/3 touched — confirmed the TC-string guard is really there, and called it done. Neither traced every *other* call site that also invokes `AppLovinMAX.setHasUserConsent`. That is the identical failure shape flagged in round 44's own consolidated verdict ("both passes verified consent propagates correctly but not whether every code path computing it has a valid basis") — the lesson from round 44 was not fully internalized into round 45's search strategy. Only `codex exec` asked "where else does this call happen," and I confirmed it by hand afterward. Worth remembering literally: **grep every caller before declaring a consent-relevant native setter fixed, not just the call site the last commit touched.**

**The mechanism, verified directly in this worktree:**

- `lib/src/core/ad_consent.dart:164-168` (round-44 fix, confirmed correct): the **post-init** `applyConsentToProviders()` reads `IabStorage.keyTcfString`; if a real IAB TC string already exists on device, it skips `AppLovinMAX.setHasUserConsent(...)` entirely so MAX can derive vendor-specific consent from the TC string itself instead of a coarse AdMob-shaped boolean.
- `lib/src/adapters/applovin_adapter.dart:816-829` (the **pre-init** path, inside `AppLovinAdapter.initialize()`, called via `AdManager` before `_bridge.initialize()`): calls `_bridge.setHasUserConsent(consent.hasUserConsent)` **unconditionally** — no `hasIabTcfString` check, no guard of any kind. The surrounding comment ("MJ1 — privacy flags must reach MAX BEFORE its SDK init... this was the FIRST time AppLovin heard about consent") makes clear this is deliberately the *primary* delivery point for AppLovin consent on an ordinary cold start, not a rare fallback.
- Because `applyConsentToProviders()` is only reached via `AdManager.setConsent()`, and `setConsent()` early-returns "SDK not initialised — buffering for next initialize()" whenever called before init completes (`ad_manager.dart:4836-4840`), the guarded post-init function is **not** what runs on a normal cold start. The unguarded pre-init call in `applovin_adapter.dart` is.

**Concrete failure scenario:** a returning EEA user who granted purposes 1/3/4 in UMP but denied AppLovin as a vendor. On the *next* app launch, a real `IABTCF_TCString` already sits in storage from the previous session. `AppLovinAdapter.initialize()` still fires `setHasUserConsent(true)` before MAX initializes — round 44's fix never gets a chance to run first, and by the time the guarded post-init call does run, it correctly sees the TC string and *skips*, leaving the wrong pre-init override in force for the entire session. AppLovin may serve personalized ads to a user who denied it as a vendor: the exact GDPR/TCF exposure round 44 was published (as a BREAKING 3.0.0 change) to close.

**Fix required:** gate the pre-init call in `applovin_adapter.dart:816-829` with the same `hasIabTcfString` check `ad_consent.dart` uses, completed before `_bridge.initialize()` runs. Keep `setDoNotSell` unconditional (CCPA has no equivalent per-vendor TCF signal). Add a cold-start regression test that asserts `setHasUserConsent` is never called when a TC string is already present — the existing `test/r44_applovin_tcf_gate_test.dart` only exercises the post-init function, and `test/applovin_adapter_test.dart:232-251` currently *requires* the unconditional pre-init call, so the two tests lock in contradictory behavior.

## Per-area summary (6 parallel sub-agent passes)

**1. Ad lifecycle & memory leaks** — traced full dispose chains for banner/MREC/native/interstitial/rewarded/app-open on both adapters. No new leak. App-open-on-resume vs. dialog-on-top has a genuine double-check (entry check in `showAppOpenAdOnResume`, re-check in `showAppOpenAd` right before presentation) — not a race. `rewardedInterstitial` no-op on AppLovin is intentional per T89 comment (see R45-03 for why the *silence* of that no-op is still worth tightening).

**2. Trial mode + VIP security** — Ed25519 verification is genuinely enforced (throws on bad signature, no bypass branch), replay/stacking/clock-rollback protections all verified against the actual persisted-high-water-mark + monotonic-stopwatch mechanism, not just the function names. Known accepted gaps (Android no durable anti-replay ledger without Auto Backup, cross-device code reuse — no server) are unchanged and remain deliberate per `CLAUDE.md`/memory, not re-flagged.

**3. Consent for all countries** — see R45-01 above for the one real gap found. Everything else (GPP 19-state handling, CCPA `setDoNotSell` pre-init buffering, ATT-before-UMP ordering with a runtime warning, epoch-guarded race protection between overlapping `setConsent` calls) verified correct against the actual code paths, not just round-44's changelog wording.

**4. AdMob/AppLovin policy compliance** — COPPA gate (AppLovin hard-aborts init when age-restricted; AdMob forwards both `tagForChildDirectedTreatment` and `tagForUnderAgeOfConsent` independently) verified correct. No hardcoded test ad-unit ID reaches a release path directly — only the warning-only guard from R45-04. No artificial mediation-waterfall preference found (provider selection is a static host config, not a runtime auction the package biases).

**5. Offline / no-network handling** — init has a bounded 20s timeout that doesn't block the splash indefinitely; init keeps running in the background and self-reports via the event bus when the network returns. Backoff has an overflow guard, retry jitter has a floor so it can't collapse into a request storm. Remote safety-config fetch fails closed to safe local defaults, not fail-open. No Android/iOS-specific connectivity-detection divergence found at the Dart level.

**6. Example app integration contract** — `packages/ad_sdk/example/lib/main.dart` satisfies all 7 CLAUDE.md contract points (navigator key before `runApp`, route observers registered, SDK init inside splash with the event-bus listener registered first, all four splash requirements present in the right order, ad-showing screens extend `AdScreen`/`AdScreenState`, `bypassSafety: true` appears exactly once and only in splash, no duplicate app-open-on-resume logic). `flutter analyze` in `example/` is clean. Only a NIT: the single 4944-line `main.dart` is unwieldy as a reference to copy from.

## Cross-check against the two independent external passes

- **`codex exec`** independently found R45-01 (as its own "R45-01"), plus R45-02/03/04 above — all four re-verified against the real source in this worktree and confirmed real, not codex-citation artifacts. Its verdict: **no, not safe to ship AppLovin/EEA traffic as-is.**
- **`agy` (Gemini)** returned an unconditional **PASS** across all 8 scope areas, explicitly quoting `ad_consent.dart:164-168` as proof round 44's fix is "confirmed" — without tracing the pre-init call site that defeats it. Its report also headers the package as version "2.9.23", which is stale/incorrect (the isolated copy it worked from has `pubspec.yaml: 3.0.0`) — a sign it leaned on cached pattern-matching from a prior round's report shape rather than confirming fresh state, consistent with this project's prior experience that this tool tends toward absolute-PASS verdicts (see memory `audit-must-be-slow-and-adversarial`). Its PASS verdict on the consent section should not be trusted on its own.

See `audit_round45_consolidated.md` for the governing verdict and required fix before production.
