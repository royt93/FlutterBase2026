# Audit — applovin_admob_sdk v2.9.17 (agy/Gemini pass + orchestrator supplementary verification)

**Date:** 2026-09-05
**Scope:** `packages/ad_sdk/lib/`, `packages/ad_sdk/test/`, `packages/ad_sdk/example/`
**Method:** Ran `agy --dangerously-skip-permissions -p "<detailed audit prompt>"` (Gemini-backed CLI) against this worktree's `packages/ad_sdk`, per the six-requirement checklist (dual-provider correctness, offline/online resilience, ad-type lifecycle/leak-freedom, 1-day trial, no-backend VIP-by-code security, multi-jurisdiction consent) plus general AdMob/AppLovin policy compliance. This is round 38 in the project's audit history — round 37 (`doc/audit/audit_round37_consolidated.md`, note: filed at the **repo root** `doc/audit/`, not `packages/ad_sdk/doc/audit/` — a path mistake in that commit) already fixed 1 BLOCKER + 13 MAJOR/MINOR findings via 4 independent reviewers and 2 further independent verification passes, landing at 9.5–9.8/10.

## Orchestrator's note on the agy run

`agy` ran successfully this time (no auth/crash failure) and — unlike the round-32 precedent recorded in `audit_agy.md` — **did write to the correct target path** (`packages/ad_sdk/doc/audit/audit_gemini.md` inside this worktree; verified by `mtime` and `git status` showing no stray files elsewhere). No copy-over was needed this run.

However, agy's report itself did not meet the bar this task asked for: it read the code (its architectural descriptions below are accurate, cross-checked against source) but returned **zero severity-tagged findings** — every item is labeled "VERIFIED CLEAN," there are no file:line citations, no concrete failure scenarios, and no suggested fixes, because it did not find anything to fix. Its self-assigned score (9.9/10) is presented with no accounting of the 0.1–0.4 points three prior independent reviewers already docked for identified residual risk (see round 37's 9.5/10 and 9.8/10 conclusions). I did **not** take agy's score at face value; I re-derive the verdict below from what was actually verified.

Given the thin findings section, I (the orchestrating Claude instance) spent additional time doing my own targeted line-level spot-checks — both to verify agy's "VERIFIED CLEAN" claims against real source (not just trust the CLI's prose) and to hunt independently for anything round 37 + agy both missed. That supplementary work is folded into the findings below rather than kept as a separate section, with each item's provenance noted.

---

## I. Findings

**No new BLOCKER, MAJOR, or MINOR was found by either agy or this orchestrator's supplementary pass.** This is consistent with — not merely asserted by — the following independently re-verified facts:

### Re-verified: round-37 BLOCKER fix is genuinely present (not regressed)
`lib/src/adapters/admob_adapter.dart` — all four fullscreen load paths now gate the expiry-driven dispose on `!slot.isShowing`, confirmed by direct grep/read of current source:
- `loadAppOpen` L886: `if (_appOpenAd != null && !appOpenSlot.isShowing)`
- `loadInterstitial` L1230: `if (_interstitialAd != null && !interstitialSlot.isShowing)`
- `loadRewarded` L1473: `if (_rewardedAd != null && !rewardedSlot.isShowing)`
- `loadRewardedInterstitial` L1738: `if (_rewardedInterstitialAd != null && !rewardedInterstitialSlot.isShowing)`

This was the single BLOCKER round 37 found (reload-while-showing killing the on-screen ad's dismiss callback). Confirmed still fixed — no regression.

### Re-verified: round-37's follow-up double-invoke fix is genuinely present
`lib/src/core/ad_manager.dart` — all four `show*()` paths (`showInterstitial` ~L5950, `showAppOpenAd` ~L6408, `showRewardedAd` ~L6823, `showRewardedInterstitialAd` ~L7014) declare `var delivered = false`, set it `true` at the start of the real callback, and gate the catch-block fallback callback on `!delivered`. Confirmed present in all four, not just some — this matters because round 37's own history shows a fix landing on 3 of 4 sibling paths and being caught only by a second independent review.

### Confirmed intentional, not a leak: `AdManager` constructor-time listeners never removed
`lib/src/core/ad_manager.dart:83-90` registers 6 listeners (`umpFormOnScreen`, `AdLoadingDialog.isShowingNotifier`, `AdScreenRouteLogger.isDialogOnTopNotifier`, `_offlineNotifier`, `_canRequestAdsNotifier`, `initRevision`) in `AdManager._internal()` with no matching `removeListener` anywhere in `destroy()`. Traced this specifically because it looked like a leak candidate (an `addListener`/`removeListener` grep count mismatch of 25 vs 23 across `lib/src`). It is not a bug: `AdManager` is a process-lifetime singleton (comments tagged `T75`/`T109` at the call site say so explicitly) and `destroy()` intentionally tears down only the per-init adapter state, not the singleton's own process-lifetime wiring — re-`initialize()` after `destroy()` reuses the same listeners rather than re-registering them. Confirmed by reading `destroy()` and the surrounding constructor comment; this is by-design, not a new finding.

### Confirmed: `Backoff.compute()` overflow fix is arithmetically correct
`lib/src/state/backoff.dart` — replaced `math.pow(2, n)` with a doubling loop that exits as soon as `shifted >= maxMs` (with a redundant 62-iteration hard cap as defense-in-depth). Manually traced: with defaults (`baseMs=15000`, `maxMs=1_800_000`), the loop only needs ~7 iterations to exceed the cap, so it can never approach the `int` range where overflow would matter — the fix is not just "probably fine," it structurally cannot overflow regardless of `consecutiveFailures` magnitude. Confirmed correct.

### Confirmed: round-37 MINOR #13 (`IndexedStack` hidden-tab banner refresh) documentation gap is closed
Round 37 downgraded this from MAJOR to MINOR specifically because "the workaround exists but isn't in the README yet." Checked `README.md:111-120` and the `BannerAdWidget` class doc comment (`lib/src/widget/banner_ad_widget.dart`) — both now document the `IndexedStack` gap and the `Visibility(maintainState: true)` workaround explicitly. Closed, not a new finding.

### Confirmed: example app declares the platform-required manifest/plist entries
`example/android/app/src/main/AndroidManifest.xml` declares `com.google.android.gms.ads.APPLICATION_ID`; `example/ios/Runner/Info.plist` declares both `NSUserTrackingUsageDescription` and `SKAdNetworkItems`. All three are required for AdMob/mediation policy compliance and were previously-flagged integration conditions (round 32) — confirmed present, not regressed.

---

## II. NITPICK

- **N1 — agy's report format doesn't meet the audit's own bar.** `audit_gemini.md` as agy wrote it (now folded into this file) contains no file:line citations, no failure scenarios, and no fixes — it is an architecture-confirmation memo, not an adversarial audit deliverable. Worth remembering for future rounds: agy's Gemini backend, when given a "find new bugs" prompt against a codebase this heavily pre-hardened, tends to produce a "here's what I verified is fine" report rather than adversarially hunting for what's still broken, unless explicitly told "if you find nothing wrong, that itself is suspicious — go looking harder in the interaction between two individually-correct mechanisms" (round 37's real BLOCKER was exactly that kind of finding, and it took a second full independent pass to catch its own follow-up bug). Not a code defect — a process note for whoever runs round 39.
- **N2 — agy's self-assigned 9.9/10 is uncalibrated.** It is higher than any of round 37's three independent reviewers (9.5, 9.5, 9.8), despite auditing less deeply (no new findings, vs. round 37's 1 BLOCKER + 13 MAJOR/MINOR across 4 reviewers). A score with no findings to subtract points for is not evidence of a cleaner codebase, just of a shallower pass. Treat 9.9 as noise; see verdict below for a calibrated number.

---

## III. Production-readiness verdict

**No genuinely new BLOCKER, MAJOR, or MINOR finding** emerged from this round, either from agy's pass or this orchestrator's supplementary line-level spot-checks of the highest-risk areas (round-37 fix regressions, listener/timer lifecycle, backoff arithmetic, documentation gaps, example manifest compliance). Everything checked was confirmed either already-fixed-and-still-fixed, or intentional-by-design.

This is consistent with — and does not contradict — the project's own stated trajectory: 37 rounds of increasingly adversarial, line-by-line review have driven the codebase to a state where a 38th independent pass, run in earnest with real file reads (not a rubber stamp), turns up nothing new. That itself is a meaningful (if less exciting) data point after 37 prior rounds, several of which *did* find real bugs on the Nth read of files "already read many times" (round 37's own framing).

**Score: 9.5/10** — consistent with round 37's own two lower-bound scores (9.5 from the original round-37 pass, 9.5 from its independent Codex re-review), not agy's 9.9. Reasoning for not going higher: this was one round-38 pass (this orchestrator + one agy CLI invocation) rather than round 37's four-independent-reviewer cross-check, so absence of new findings here carries less weight than round 37's multi-reviewer convergence; and the same acknowledged residual risks from round 37 remain unresolved by design (Android VIP/trial ledger has no anti-clear-storage protection without host-app Auto Backup; AVP1 has no expiry/app-binding; the `private_key.pepk` git-history exposure remains deferred per `CLAUDE.md`). None of these are new — all were already known, documented, and accepted before this round started.

**Recommendation:** no code changes required from this round. Continue treating the CLAUDE.md-documented pre-production checklist (rotate demo VIP keypair, Android backup manifest entries, real ad unit IDs, `Visibility(maintainState:true)` wrapping for `IndexedStack` tabs) as the actual remaining gate before a fresh consuming app integrates this SDK — that checklist, not this audit, is where real remaining risk lives.
