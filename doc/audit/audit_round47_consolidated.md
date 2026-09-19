# Audit round 47 — consolidated verdict (PROVISIONAL)

**Date:** 2026-09-19
**Codebase audited:** local worktree with round 45 + round 46 fixes applied
(`pubspec.yaml` still 3.0.0, unpublished).
**Method:** in-session Claude (5 parallel sub-agents) + `agy`
(`--dangerously-skip-permissions`, Gemini) both completed. **`codex exec`
hit its usage limit mid-run and produced no report** — see
`/Users/LoiTP/.claude/jobs/a04f6215/tmp/codex47_stdout.log`, which shows
~400K tokens of legitimate exploration before terminating with "You've hit
your usage limit... try again at 3:20 PM."

## Verdict: PROVISIONAL CLEAN — 0 new BLOCKER/MAJOR/MINOR from the two passes that completed

| Pass | Result |
|---|---|
| In-session Claude (5 sub-agents) | 0 new MAJOR/MINOR; 2 NIT (both low-risk, non-blocking) |
| `agy` (Gemini) | Unconditional PASS (per its established pattern — not independently weighted); caught one real housekeeping gap (stale API golden file, fixed) |
| `codex exec` | **Did not complete — no data this round** |

**Why "provisional," per project decision:** `codex exec` has been the
single most reliable independent reviewer across rounds 44, 45, and 46 —
it found the MAJOR (or equivalent) finding in every one of those rounds,
each time missed by both the in-session Claude pass and `agy`. Its absence
this round means the "clean" verdict above rests on two passes with a
track record of missing exactly the class of subtle, shared-state
interaction bugs round 46 revealed. Project decision (2026-09-19): accept
this as provisionally clean and proceed to round 48 rather than block on a
codex retry, but do not treat round 47 as fully equivalent to a normal
clean round when evaluating the two-consecutive-clean publish gate — if
round 48 (run with all three passes) finds a new MAJOR, round 47's
provisional clean status carries no weight toward the gate.

## Round-46 fix re-verification

All 3 of round 46's fixes (R46-01 consent-guard bypass, R46-02 shared
footgun flag, R46-03 click staleness/cross-adapter guards) were
re-confirmed correct and complete by the two completed passes. Two NIT-tier
items surfaced, neither blocking, both documented in `audit_claude.md` for
future opportunistic cleanup:
1. Native ad's `onAdLoadedCallback`/`onAdLoadFailedCallback` lack the
   `capturedAdapter` identity check click/revenue got — low risk (writes
   only to a self-cleaning per-instanceKey entry, not shared global state).
2. `runIntegrationSelfCheck()`'s debug-only "Consent flow ran" check reads
   `hasBeenAsked` rather than distinguishing a qualifying consent flow from
   a CCPA-only `setDoNotSell()` call — same concept as R46-01 but in a
   diagnostic tool that doesn't gate real ad serving.

## Fixed same-round (unrelated to the above, found by `agy`)

`test/goldens/public_api_surface.txt` had gone stale after round 46 added
`{bool qualifiesAsConsentFlow = true}` to `AdManager.setConsent`'s public
signature. Regenerated and committed (`82c568e`).

## Next step

Round 47 stands as the provisional first of the two required clean rounds.
Round 48 must run with all three passes (including a working `codex exec`)
and must also come back clean for the publish gate to be satisfied. If
round 48 finds a new BLOCKER/MAJOR, round 47's provisional clean status is
retroactively worth nothing (it never had codex's check) and the
two-consecutive-clean count resets from whatever round follows the fix.
