# Audit round 51 — consolidated verdict

**Date:** 2026-09-20
**Codebase audited:** `main` HEAD `6040a25` (round 50's clean audit doc on
top of unreleased round-49 fixes; published pub.dev **3.0.1**;
`pubspec.yaml` still `3.0.1`, CHANGELOG has `[Unreleased]` section).

## Method

Run per the user's explicit choice to pursue this repo's "two consecutive
clean rounds with working external tooling" publish-gate convention after
round 50 came back clean. Three independent passes, scoped to slices
disjoint from round 50's coverage (lifecycle/dispose, safety/fraud/consent/
VIP) to avoid re-treading the same ground:

1. **`codex exec` (external CLI, real subprocess)** — adversarial sweep of
   `lib/src/monetization/` (all 10 files: digital_twin, arbitrator, anomaly
   detector, integrity ledger, self-healing observer, waterfall tuner,
   journey prefetcher, both fill-rate monitors, failover advisor),
   `lib/src/compliance/` (all 5 files), and `admob_adapter.dart`/
   `gma_bridge.dart`.
2. **In-session Claude fork, slice C** — the same `lib/src/monetization/`
   decision/math-logic files, independently.
3. **In-session Claude fork, slice D** — the same `lib/src/compliance/`
   signing/audit-trail files plus the AdMob-specific adapter files,
   independently.

## Findings — all fixed same round

### Codex found 4 new real findings; both in-session forks (slices C, D) came back "no new findings" on their overlapping scope

This is itself worth noting: `codex` found real bugs in files two
independent in-session forks had just read closely and cleared — consistent
with this repo's standing lesson that a clean internal pass does not mean
clean, and external tooling catches what in-session review misses on its
own blind spots. All 4 were verified by direct source read before being
trusted (not taken on codex's word).

**1. MAJOR — `ProviderFailoverAdvisor`'s open-circuit state lost across a restart right after tripping.**
`lib/src/monetization/provider_failover_advisor.dart`. `_openedAt` (the
field `circuitState` derives `open`/`halfOpen`/`closed` from) was never
persisted — only `_consecutiveFailures` and `_lastProviderTag` were. A host
process killed right after the circuit tripped (failures reached
`consecutiveFailureThreshold`) restarts with the failure count intact but
`_openedAt == null`, so `circuitState` reads `closed` and
`shouldFailoverNextSession` reads `false` again, silently discarding an
already-earned failover recommendation until one more real failure landed.
Existing restart test only covered a streak of 2/3 (not yet tripped) before
restart — missed this because it never restarted an already-open circuit.

**Fix:** added `AdPreferences.getProviderFailoverOpenedAt()`/
`setProviderFailoverOpenedAt()` (epoch millis), wired into
`_loadPersisted()`/the existing write chain alongside the other two fields.
**Verification:** added `provider_failover_advisor_test.dart` test
constructing an advisor, tripping it, disposing, reconstructing a second
instance, asserting `shouldFailoverNextSession` stays `true` with no new
failure. Confirmed red without the fix, green with it.

### 2. MAJOR — `ConsentProvenanceJournal.verifyChain()` cannot detect truncation or full forgery, contrary to its own doc comment

`lib/src/compliance/consent_provenance_journal.dart`. `verifyChain()`
recomputes the SHA-256 hash chain purely from `_entries` currently in
memory/storage — there is no secret, signature, or external anchor.
Dropping the tail of the chain and recomputing from what remains is still
internally self-consistent, so it verifies `true`; a wholesale forged chain
built from scratch does too. The doc comment claimed `false` means an entry
was "removed after being recorded" — provably false for exactly this
truncation case. Unlike `BypassAuditTrail`/`IncidentRecorder`/
`ComplianceReport`, this journal had no signed-export path at all, so it
had zero of the (limited, already-documented) tamper-evidence value those
siblings get from `signJsonPayload`.

**Fix:** added `ConsentProvenanceJournal.toPayloadJson()` +
`signConsentProvenanceJournal()` (mirrors `signBypassAuditTrail`/
`signIncidentBundle` exactly — same on-device Ed25519 key, same
"tamper-evidence not non-repudiation" threat model already documented on
`SignedComplianceReport`), plus `AdManager().exportSignedConsentProvenanceJournal()`
convenience wrapper for API parity with `exportSignedBypassAuditTrail`.
Corrected `verifyChain()`'s doc comment to state the real, narrower
guarantee instead of the false one. **Verification:** added a test proving
truncation still verifies `true` (documents the known limitation rather
than pretending it's fixed — this is a design constraint of local-only
hash chains, not something fixable without a server-side anchor) plus two
tests for the new signed export (round-trips via `verifySignedJsonPayload`,
a tampered payload fails).

### 3. MINOR — `FillRateBaselineMonitor` still counted offline load failures, unlike its round-49-fixed siblings

`lib/src/monetization/fill_rate_baseline_monitor.dart`. `FillRateMonitor`
and `ProviderFailoverAdvisor` both got the `if (!event.success &&
!AdManager().isConnected) return;` guard in round 49 (M49-04) — this third
sibling, doing the same kind of load-failure tallying into a 7-day
persisted baseline, was missed.

**Fix:** added the identical guard. **Verification:** added a test forcing
5 offline failures via `AdManager().debugConnectivityChanged(false)`,
confirming today's persisted history entry for that slot stays absent.

### 4. MINOR — revenue-regression gate checked load-sample count, not revenue-sample count

`lib/src/monetization/fill_rate_baseline_monitor.dart`,
`_checkRegression()`. `minSamples` gated `session.attempts`/
`baseline.attempts` (load attempts) before considering either fill-rate or
revenue regression — but the revenue comparison itself only requires
`revenueCount >= 1` on each side to produce an average. With
`minSamples = 5`: 5 loads + exactly 1 paid event on each side passes both
attempt gates, then a single $1 vs $1,000,000 comparison can swing ~100%
and fire a revenue-regression alert off pure n=1 noise.

**Fix:** added `session.revenueCount >= minSamples && baseline.revenueCount
>= minSamples` to the `revenueRegressed` condition. **Verification:** added
a test with 5 loads/1 paid event on each side, confirming no alert fires;
confirmed the existing round-45-era revenue-regression test (20/20 baseline
paid events, 5 session paid events — both already `>= minSamples`) still
passes unchanged.

### R51-01 (MINOR, tooling, found by slice D) — `BypassAuditTrail.clear()` missing the same `.catchError` its siblings in this file already have

`lib/src/compliance/bypass_audit_trail.dart`. `_schedulePersist()` and
`flush()` both got a `.catchError` across 3 prior rounds (T155) after a
persist failure was found to leave `_persistChain` permanently rejected —
`clear()`, added later, was never brought in line and would throw
uncaught out to its own caller (e.g. a consuming app's `clearSdkData`-style
erasure flow) on a transient write failure.

**Fix:** added the identical `.catchError` + `SafeLogger.w` pattern.
**Verification:** existing `bypass_audit_trail_test.dart` suite (20 tests)
still passes; no dedicated failure-injection test added, matching this
file's own precedent — the two earlier `.catchError` fixes in the same
file don't have one either (no mockable persist-failure seam exists for
`AdPreferences` in this codebase).

## What did NOT hold up / known gaps (carried forward, unchanged)

- GPP US-state bit-offset parsers (`iab_storage.dart:427-495`) still
  unverified against an IAB reference encoder.
- The round-31/49 UMP mismatch-warning edge case — still not confirmed
  reachable through any real public API path.
- `ConsentProvenanceJournal`'s local-only hash chain cannot detect
  truncation/forgery by whoever controls the device's own storage — this is
  now honestly documented rather than silently overclaimed, but it is not
  "fixed" in the sense of becoming tamper-proof; that would need a
  server-side anchor this SDK has no backend to provide.

## Test status

Full `packages/ad_sdk` suite: **2178/2178 passing** (6 new regression tests:
1 for the failover-advisor restart fix, 3 for the consent-provenance-journal
fixes, 2 for the baseline-monitor fixes). `flutter analyze`: 0 issues.
`test/goldens/public_api_surface.txt` regenerated for the 3 new public
members (`AdManager.exportSignedConsentProvenanceJournal`,
`ConsentProvenanceJournal.toPayloadJson`, `signConsentProvenanceJournal`).

## Publish-gate status

Round 50 was clean; round 51 found and fixed 4 real findings (3 MAJOR, 1
MINOR) plus 1 tooling MINOR — so round 51 does **not** count as the second
consecutive clean round either. The two-in-a-row bar remains unmet; would
need a round 52 with zero new findings across external + internal passes to
satisfy it. This is the same pattern round 49→50 already showed: a fix-then
verify round resets the "clean streak," it doesn't extend it.

## Recommendation

No blockers left open. All 4 substantive findings plus the 1 tooling
finding are fixed, tested, and merged into this round's work. Whether to
run round 52 for the formal two-in-a-row, or treat this round's real (and
now-fixed) findings as sufficient evidence the codebase is being exercised
properly and proceed to publish 3.0.2, is a product call — not a code one.
