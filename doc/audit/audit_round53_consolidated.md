# Audit round 53 — consolidated verdict

**Date:** 2026-09-20
**Codebase audited:** `main` HEAD `be9b1db` (round 52's fixes on top of
unreleased round-49 fixes; published pub.dev **3.0.1**; `pubspec.yaml`
still `3.0.1`, CHANGELOG has `[Unreleased]` section).

## Method

`lib/src/core/ad_manager.dart` (9119 lines, the single largest and most
central file in the codebase) had never gotten one pass dedicated entirely
to it in rounds 50-52 — only touched piecemeal per specific finding. Split
three ways by line range:

1. **`codex exec` (external CLI)** — lines 1-3100 (class fields, init/destroy
   lifecycle, public getters, early load/show logic).
2. **In-session Claude fork, slice G** — lines 3100-6100 (`initialize()`'s
   full body, consent/UMP/privacy-options flows, remote safety overrides).
3. **In-session Claude fork, slice H** — lines 6100-9119 (destroy/teardown,
   the four `show*Ad` methods, `canShowX()` peek functions, lifecycle
   observer, retry/connectivity watch) plus `lib/src/adaptive/
   adaptive_frequency.dart` (69 lines, never independently audited this
   cycle).

## Findings — 1 claimed by codex, investigated and does NOT hold up (false positive)

Both in-session forks (slices G, H) came back clean — consistent with
those sections being the most heavily re-reviewed in the codebase's
history (the consent-apply epoch/token mechanism alone cites 21+ prior
independent review rounds in its own comments). `codex` flagged one MAJOR
in its slice:

**Claimed: App Open load coalescer (`ad_manager.dart:2537`,
`_coalesceAppOpenLoad`) gets stuck forever if the adapter's Future resolves
without ever calling `onAdLoaded`** — cited `applovin_adapter.dart:1366`'s
catch block (`_bridge.loadAppOpenAd` throws synchronously → only
`appOpenSlot.markFailed()` is called, not `onAdLoaded?.call(false)`
directly) as the trigger.

**Investigated and does not hold up.** Traced the actual call chain instead
of trusting the claim: `appOpenSlot.pendingCallback` is armed (to a wrapper
that calls `onAdLoaded`) several lines *before* the `try`/`catch` around
`_bridge.loadAppOpenAd`. `AdSlot.markFailed()` unconditionally calls
`_firePending(false)`, which fires `pendingCallback` synchronously — so
`onAdLoaded(false)` still runs, synchronously, before `loadAppOpen()`'s
async function body even returns. By the time the coalescer's `.then()`
sets `adapterFutureDone = true`, `callbackReceived` is already `true`
(set on the same earlier microtask that never leaves the function). Wrote
a test (`applovin_adapter_test.dart`, `_ThrowingLoadAppOpenBridge`) forcing
exactly this synchronous throw and asserting the callback still fires —
confirmed **green** on the current, unmodified code. No production change
made. Kept as a permanent regression test (not discarded) so a future
refactor that reorders `pendingCallback` arming relative to the
`try`/`catch` would be caught immediately.

This is the inverse of rounds 51-52's pattern (where codex found real bugs
in-session review missed) — a useful reminder that codex's own findings
still need the same "verify the mechanism, don't pattern-match" discipline
applied to internal-fork findings, not automatic trust either way.

## What did NOT hold up / known gaps (carried forward, unchanged)

- GPP US-state bit-offset parsers (`iab_storage.dart:427-495`) still
  unverified against an IAB reference encoder.
- `ConsentProvenanceJournal`'s local-only hash chain still cannot detect
  truncation/forgery by whoever controls the device's own storage (round 51
  — documented limitation, not a defect).

## Test status

Full `packages/ad_sdk` suite: **2182/2182 passing** (1 new permanent
regression test added — a verification/false-positive-documentation test,
not a bug fix). `flutter analyze`: 0 issues.

## Publish-gate status

**Round 53 is clean** — no real findings survived verification, no
production code changed. This is the second clean-ish round since round 49
(round 50 was fully clean; rounds 51-52 found and fixed real bugs; round 53
is clean again). Whether this satisfies the "two consecutive clean rounds"
convention depends on how round 53 is counted given it directly follows
two dirty rounds — it does NOT yet make two **consecutive** clean rounds on
its own; round 54 coming back clean too would.

## Recommendation

No blockers. No code changes this round beyond one new regression test. The
codebase's most central file (`ad_manager.dart`) has now had a dedicated,
full, three-way adversarial pass with no surviving findings.
