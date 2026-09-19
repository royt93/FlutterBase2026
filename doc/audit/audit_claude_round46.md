# Audit round 46 — Claude (in-session), independent direct-read pass

**Date:** 2026-09-19
**Codebase audited:** local worktree with round 45's 4 fixes applied (unpublished, still `pubspec.yaml` 3.0.0).
**Method:** 5 parallel from-scratch sub-agent passes: one dedicated purely to
re-verifying round 45's 4 fixes are complete (by grepping every caller of the
underlying mechanism, not just the changed lines — the exact discipline round
45 itself established after finding round 44's fix was incomplete the same
way), plus 4 fresh sweeps of the 8 standard scope areas. Run alongside
`codex exec` and `agy` in isolated copies — see `audit_codex_round46.md` /
`audit_gemini_round46.md`, consolidated verdict in
`audit_round46_consolidated.md`.

## Executive verdict

**Not clean** (before same-day fixes). My own sub-agents found 1 new MINOR
(banner/MREC click missing the stale-callback guard) and flagged round 45's
own R45-02 fix as incomplete. `codex exec`, run in parallel, additionally
found a MAJOR (R46-01) and a second MINOR (R46-02, a regression in round 45's
own R45-04 fix) that my sub-agents and `agy` both missed. All 3 are fixed as
of this writing — see `CHANGELOG.md`'s `[Unreleased]` section and
`audit_round46_consolidated.md` for the governing verdict.

## What my own process caught vs. missed, and why

The fork dedicated to re-verifying round 45's fixes correctly found the
banner/MREC gap by asking "what ELSE in this codebase does the same thing
round 45 fixed for native — are there siblings that needed the same fix and
didn't get it?" That question surfaces gaps of the shape "fix A applied to
file X, but file Y has the identical pattern and was missed."

It did NOT ask the different question codex asked: "what ELSE reads/writes
the same shared mutable STATE this fix touches?" — which is what surfaces
R46-01 (two different fixes from two different rounds, each correct in
isolation, sharing `_consentExplicitlySet`/`setConsent()`'s side effects) and
R46-02 (two different footguns sharing one `_footgunBlocked` flag). Both
question shapes are now written into `[[audit-must-be-slow-and-adversarial]]`
for future rounds: **grep every caller of what you fixed, AND grep every
other reader/writer of any shared flag your fix touches.**

## Per-area summary (4 fresh-sweep sub-agent passes)

- **Ad lifecycle & memory leak:** 1 new MINOR — banner/MREC click callbacks
  missing `isStaleAppLovinCallback`, same class of bug as R45-02 but for the
  two widgets round 45 didn't touch. No other new lifecycle/leak finding;
  round 45's own fixes (App Open on-resume double-check, dispose chains)
  hold up unchanged.
- **Trial + VIP security:** no new finding. Concurrency (two redeems racing),
  stacking-clamp overflow, UTC/leap-second handling, and dispose-vs-in-flight-
  redeem races were all specifically re-examined from fresh angles and hold.
- **Consent (all jurisdictions):** no new finding in `consent/`, `ump_consent.dart`,
  `ad_consent.dart`, `att_consent.dart`, `iab_storage.dart` themselves — R46-01
  lives in `ad_manager.dart`'s footgun-guard plumbing, outside this fork's
  assigned file scope, which is exactly why a fork organized by *file area*
  missed an issue that spans two different areas' shared state.
- **Offline + policy compliance:** no new finding. Connectivity-watch
  generation-guard, per-slot backoff/jitter, and the R45-03 `unsupported_provider`
  guard's AdMob-safety were all re-checked and hold.

## Cross-check against the two independent external passes

- **`codex exec`** found R46-01 (MAJOR) and R46-02 (MINOR) fresh — neither
  organized its search by file/area the way my sub-agents were split, which
  is plausibly why it caught the cross-cutting shared-state issues my
  file-scoped forks structurally couldn't. It also independently found the
  same banner/MREC gap, plus the cross-adapter-instance angle on native
  (R46-03's second half) that no other pass identified.
- **`agy` (Gemini)** returned an unconditional **PASS** across all 8 scope
  areas and declared all 4 round-45 fixes "verified correct and complete" —
  missing both R46-01 and R46-02 entirely. This is the third consecutive
  round (42, 44, 46) `agy` has given an absolute PASS that missed a real
  MAJOR-or-equivalent finding; its verdict alone should not be treated as
  evidence of correctness going forward (see project memory).

See `audit_round46_consolidated.md` for the governing verdict and required
next step (round 47 must run fresh against these fixes).
