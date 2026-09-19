# Audit round 48 — consolidated verdict (INTERNAL ONLY — both external passes unavailable)

**Date:** 2026-09-19
**Codebase audited:** local worktree with round 45/46/48 fixes applied
(`pubspec.yaml` still 3.0.0, unpublished).
**Method:** this round could NOT run its planned 3-way process:
- `codex exec` — still returning "You've hit your usage limit... try again
  at 3:20 PM" on every invocation this session (checked twice).
- `agy` (Gemini) — attempted twice, both times exited after ~5s having
  only launched an internal background verification task and never waited
  for it, producing no report file either time. A reproducible tool
  failure this session, not a one-off.

In their place: 4 parallel in-session Claude sub-agents (one deliberately
unstructured/cross-cutting, mimicking codex's non-file-scoped search style,
plus 3 standard-area sweeps), followed by one additional **single continuous
adversarial re-read** (not split by topic) of `ad_manager.dart`,
`ad_consent.dart`, `applovin_adapter.dart`, and `admob_adapter.dart` end to
end, explicitly distrusting every prior round's "verified correct and
complete" claim and trying to construct exploit sequences — substituting
for the missing independent pass per an explicit project decision (external
tools unavailable this round).

## Verdict: 0 new BLOCKER/MAJOR. 2 new MINOR/NIT (both fixed same-day).

| Finding | Severity | Status |
|---|---|---|
| Stale reconnect-debounce timer survives an online→offline flap, can fire a refill while genuinely offline | MINOR | Fixed (`cc776f3`) |
| `test/goldens/public_api_surface.txt` stale after round 46's `setConsent` signature change | Housekeeping | Fixed (`82c568e`, round 47) |
| Epoch/pending-apply invalidation in `setConsent()` ignores `qualifiesAsConsentFlow` — latent, NOT currently exploitable (verified: the only non-qualifying caller is pre-init-only; this machinery only matters post-init) | NIT | Warning comment added, no behavior change (this round) |

No new dual-provider, offline, lifecycle/memory, trial, VIP, consent, or
policy-compliance findings from any of the 5 passes this round.

## Why this round's evidence is weaker than rounds 44-47's

This is the **first round with zero external tool participation**. Every
prior round's real findings (rounds 44, 45, 46, and round 47's one genuinely
useful catch) came from `codex exec` or, once, from `agy` incidentally —
never purely from this project's own in-session sub-agents alone, despite
those sub-agents running every round. The adversarial single-pass re-read
added this round is a good-faith substitute, and it did find one real
(if non-exploitable) latent issue that the 4 topic-split sub-agents missed
— but it is still fundamentally the same reviewer (Claude) that already
missed R46-01/R46-02 in round 46. Treat round 48's "clean" verdict as the
weakest-evidence round in this whole audit series, not equivalent to a
normal clean round.

## Publish gate status

Per project decision, rounds 47 and 48 are being treated together as
insufficient to independently satisfy the original "two consecutive
externally-verified clean rounds" gate, given neither had a working
external pass. A future round with at least one working external tool
(codex once its usage limit resets, or agy if its failure mode is
transient) should be run before treating the gate as satisfied — this is
a standing recommendation, not a block on any other action the project
wants to take now.
