# Audit round 46 — consolidated verdict

**Status update (2026-09-19):** all 3 findings below (R46-01 MAJOR, R46-02/03
MINOR) have been fixed, TDD, same-day. See `CHANGELOG.md`'s `[Unreleased]`
section for the exact fix per finding and the new regression tests
(`test/ad_manager_core_test.dart`, `test/native_ad_widget_test.dart`). Combined
touched-file test run: 435/435 pass. `flutter analyze` clean. Round 46 itself
is the record of what was found BEFORE these fixes — per the project's
publish gate (two consecutive independent audit rounds with zero new
MAJOR/BLOCKER), round 46 does not count as clean, so **round 47 must also be
run fresh against the now-fixed code**, and if it's clean, round 48 must be
clean too, before publishing.

**Date:** 2026-09-19
**Codebase audited:** local worktree with round-45's 4 fixes applied
(`pubspec.yaml` still 3.0.0, unpublished; round 45's own findings are
tracked separately in `audit_round45_consolidated.md`).
**Method:** three fully independent passes — in-session Claude (1 fork
dedicated to re-verifying round 45's 4 fixes are complete, by tracing every
caller of the underlying mechanism, not just the changed lines; 4 more forks
doing a fresh sweep of the 8 standard scope areas), `codex exec
--dangerously-bypass-approvals-and-sandbox`, and `agy --dangerously-skip-permissions`
(Gemini) — each against an isolated throwaway copy with no visibility into
each other's output.

| Pass | Result file | Verdict as filed |
|---|---|---|
| In-session Claude (5 parallel sub-agents) | see findings below | 1 new MINOR (banner/mrec click), round-45 fix R45-02 flagged incomplete |
| `codex exec` | `audit_codex_round46.md` | **Not clean — 1 new MAJOR (R46-01), 2 new MINOR (R46-02, R46-03)** |
| `agy` (Gemini) | `audit_gemini_round46.md` | **CLEAN/PASS — 0 new MAJOR/BLOCKER** (missed R46-01 and R46-02 entirely) |

## Why the verdicts disagree, a third time running the same shape

This is the **third round in a row** (42, 44, 46) where `agy`/Gemini returned
an unconditional PASS while `codex exec` and/or a manual re-read found a real
MAJOR. Its round-46 report correctly found the same banner/MREC click gap my
own sub-agents did, but never asked "what else writes to the flag I'm reading"
or "what else reads the flag this function I'm verifying just wrote" — the
exact question that would have surfaced R46-01 and R46-02. Treat `agy`'s
CLEAN/PASS verdicts as *not independently informative* about MAJOR-level
correctness at this point — three-for-three is a pattern, not noise. See
`[[audit-must-be-slow-and-adversarial]]` (project memory) for the running
log of this.

## Confirmed findings (fixed same-day — see CHANGELOG `[Unreleased]`)

### R46-01 — MAJOR — pre-init `setDoNotSell` bypassed the missing-consent-flow guard
Round 44's fix routing pre-init `setDoNotSell()` through `setConsent()` (so
it wasn't silently dropped) had an unintended side effect: `setConsent()`
unconditionally set `_consentExplicitlySet = true`, which
`consentFootgunWarning()` treats as proof "a consent flow ran" — even though
`setDoNotSell` only supplies the CCPA/US-Privacy axis, not a GDPR/UK consent
decision. A release build with `autoRequestUmpConsent: false` and no AppLovin
CMP could call `setDoNotSell(true)` pre-init and silently defeat the guard
meant to catch exactly that configuration, serving EEA/UK users with no
consent flow at all. **Two individually-correct fixes from different rounds
combined into a new gap neither round's author could see in isolation** —
the general lesson this adds to the project's audit process: after fixing
mechanism A, also check what ELSE reads any shared state A's fix touches.

### R46-02 — MINOR (a regression in round 45's own R45-04 fix) — shared footgun flag
`_applyTestIdFootgunGuard` (R45-04) and `_applyConsentFootgunGuard` shared one
`_footgunBlocked` flag. `setConsent()` unconditionally clears it whenever a
consent flow resolves — which happens moments after init in any real app (the
UMP flow finishing) — silently erasing the test-ID release block almost
immediately in the realistic sequence. Now its own dedicated
`_testIdFootgunBlocked` flag.

### R46-03 — MINOR — click callbacks missing stale/cross-session guards
`BannerAdWidget`/`MrecAdWidget` click callbacks lacked the
`isStaleAppLovinCallback` check their revenue callbacks already had (round
33) — independently found by my own sub-agents, codex, and agy (the one
finding all three passes agreed on). Separately, codex found that
`NativeAdWidget`'s round-45 `isNativeInstanceDisposed` guard is a
per-`AppLovinAdapter`-instance tombstone set: a late callback surviving a
`destroy()` + re-`initialize()` finds an empty tombstone set on the NEW
adapter and would pass that check, contaminating the new session. Native
click/revenue callbacks now also require `identical(AdManager().adapter,
capturedAdapter)`.

## Round-45 fix re-verification (this round's other job)

- R45-01 (AppLovin pre-init consent): **re-confirmed correct and complete**
  by all three passes.
- R45-02 (native click after dispose): **found incomplete** — see R46-03
  above (banner/MREC sibling gap + cross-adapter-instance gap).
- R45-03 (rewarded interstitial skip event): **re-confirmed correct and
  complete**, does not misfire for AdMob.
- R45-04 (release test-ID hard block): **found incomplete** — see R46-02
  above (cleared by the very next `setConsent()` call).

## Next step

Round 47 must be run fresh against this round's fixes. Only once round 47
AND a subsequent round both find zero new BLOCKER/MAJOR does the project's
publish gate open.
