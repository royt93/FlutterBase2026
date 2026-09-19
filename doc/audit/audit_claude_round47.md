# Audit round 47 — Claude (in-session), independent direct-read pass

**Date:** 2026-09-19
**Codebase audited:** local worktree with round 45 + round 46 fixes applied (unpublished, `pubspec.yaml` still 3.0.0).
**Method:** 5 parallel from-scratch sub-agent passes, applying round 46's
generalized lesson (grep every OTHER reader/writer of shared mutable state a
fix touches, not just every caller; also check for "sibling class has the
identical pattern and was never touched"): one dedicated to re-verifying
round 46's 3 fixes, four fresh sweeps across the 8 standard scope areas
split by file/topic area.

## Executive verdict

**No new BLOCKER/MAJOR/MINOR.** All 5 sub-agents independently confirm round
46's 3 fixes are correct and complete, with two NIT-tier caveats (see below)
that don't block anything and are safe to leave or fix opportunistically.

## Round-46 fix re-verification

- **R46-01 (`qualifiesAsConsentFlow`):** correct & complete. Only 3 internal
  callers of `setConsent()` exist; the 2 genuine-consent-decision ones keep
  the default `true`, `setDoNotSell`'s CCPA-only routing passes `false`.
  `_consentExplicitlySet` has exactly one reader (`consentFootgunWarning`).
- **R46-02 (`_testIdFootgunBlocked`):** correct & complete. All 11 real
  ad-request gates route through the shared `canRequestAds` getter, which
  checks both flags. The few raw `_canRequestAds` reads left are refill-retry
  bookkeeping, not request-decision gates — harmless if stale.
- **R46-03 (banner/mrec stale-click guard + native cross-adapter identity):**
  correct & complete for both halves that were fixed. Two NIT-tier items
  found, neither blocking:
  1. `native_ad_widget.dart`'s `onAdLoadedCallback`/`onAdLoadFailedCallback`
     still resolve `adapter.native(instanceKey)` freshly without the
     `capturedAdapter` identity check the click/revenue callbacks got. Unlike
     those, this only writes into a per-instanceKey registry entry (not a
     shared global counter), so a late callback after destroy+reinit at
     worst creates one orphaned entry on the new adapter that self-cleans on
     that widget's own eventual dispose — no global state corruption, no
     policy/safety-counter impact.
  2. `runIntegrationSelfCheck()` (debug-only diagnostic) reads
     `consent.hasBeenAsked` rather than the new `qualifiesAsConsentFlow`
     distinction, so it can report "Consent flow ran: pass" after a
     CCPA-only `setDoNotSell()` call — same conceptual gap as R46-01, but in
     a debug tool that doesn't gate real ad serving.

## Fresh 8-area sweep — no new findings

Dedicated sub-agents covering (a) every other shared-state field in
`ad_manager.dart` beyond the 4 already known, (b) VIP/trial + consent files,
(c) widget "sibling callback" gaps beyond click/revenue, (d) offline/policy/
example — all reported clean. Full detail in each sub-agent's own findings,
summarized: `ad_safety_config.dart`'s background-transition flags were
already correctly split apart in an earlier round (cited as a positive
precedent for the exact lesson round 46 taught); the example app's own
`setConsent` usage is the qualifying, full-decision form and doesn't
demonstrate the R46-01 anti-pattern.

## Cross-check against the two independent external passes

- **`codex exec` did not complete this round** — it hit its usage limit
  mid-run and produced no report (see raw log,
  `/Users/LoiTP/.claude/jobs/a04f6215/tmp/codex47_stdout.log`, tail: "You've
  hit your usage limit... try again at 3:20 PM"). Given codex has been the
  single most reliable source of real findings across rounds 44-46 (it
  caught at least one MAJOR-or-equivalent issue every round it participated
  in, several missed by both this pass and `agy`), **this round's "clean"
  verdict is weaker evidence than rounds 44-46's** and should be understood
  as provisional pending a codex re-run.
- **`agy` (Gemini)** returned another unconditional **PASS** across all 8
  areas (its pattern across every round so far). It did, however, flag one
  genuinely useful housekeeping item this time: `test/api_golden_test.dart`
  had gone stale after round 46 added `qualifiesAsConsentFlow` to
  `setConsent`'s public signature — a real gap I had missed in my own
  verification (I never re-ran that specific test file after the signature
  change). Fixed same-day: regenerated `test/goldens/public_api_surface.txt`
  (and had to manually strip a "Running build hooks..." stdout-pollution
  artifact from the regeneration command — a previously-documented sandbox
  quirk I forgot to account for). This is a good illustration of why `agy`'s
  reports are still worth reading even though its top-line PASS verdict
  carries no independent weight: it can still surface real, if narrow,
  things a differently-focused reviewer misses.

See `audit_round47_consolidated.md` for the governing (provisional) verdict.
