# Audit round 64 — consolidated verdict

**Date:** 2026-09-20
**Codebase audited:** `main` HEAD `5c21bfe` (round 63's fix + doc on top
of round 62's fix; published pub.dev **3.0.2**, `pubspec.yaml` still
`3.0.2`, CHANGELOG has `[Unreleased]` section).

## Method

Two in-session Claude forks, splitting `lib/src/core/ad_safety_config.dart`
(1357 lines — the SDK's single largest and most safety-critical file,
every ad show routes through its gates) roughly in half by logical
grouping, per the human's explicit choice to close this out before
deciding on publish.

1. **Fork 1** — `AdSafetyResult`/`AdSafetySnapshot`/`AdSafetyParams`
   classes, `AdSafetyConfig.init`/`updateParams`/`canShowFullscreenAd`/
   `canShowFullscreenAdPeek`/`dailyCapReached`/`placementDailyCapReached`/
   `recordPlacementAdShown`/`recordNetworkShown`/`isNetworkFatigued`/
   `_canShowFullscreenAdStrict` (~lines 1-757).
2. **Fork 2** — `canShowAppOpenOnResume`/`Peek`/`_canShowAppOpenOnResumeStrict`,
   click/background-click tracking, `getSessionAdCount`/
   `resetSessionCounters`/`resetSession`/`resetForReinit`/`getStatus`/
   `getStatusSnapshot`, suspicious-pause decay/trigger, risk score
   (~lines 757-1357, to end of file).

Both were explicitly directed to hunt for the two recurring bug shapes
this session (57-63) kept finding: a clock-rollback gap in a counter
added after round 31/37's fix, and the "two independent paths touching
one shared variable inconsistently" class from round 46 (round 49's
`resetSessionCounters` fix and round 63's consent-journal fix are both
instances of related shapes).

## Findings

**None.** Both slices came back genuinely clean after a real adversarial
attempt — the first fully clean round in this session's 57-64 sequence.

### Fork 1 (first half): no findings

- `recordNetworkShown`/`isNetworkFatigued`'s elapsed-ms rolling window
  (added as T126, after round 31/37's calendar-day fixes) was specifically
  checked for the same clock-rollback gap — a backward clock jump makes
  `now - t` negative, which makes the window look **not yet expired**
  rather than reset. That's the safe direction (over-blocking, not a
  bypass), not a bug.
- `placementDailyCapReached`'s persisted backing correctly uses
  `_todayUtcClamped()` (round 37's high-water-mark clock-rollback guard),
  not raw `_todayUtc()`.
- `_hourlyAdTimestamps`/`_lastFullscreenAdTime` throttle: same elapsed-ms
  analysis — a clock rollback can only make these checks stricter, never
  bypassable.
- `AdSafetyParams.copyWith()` was cross-checked field-by-field against the
  class's own field list (16/16) — the exact shape of bug that hides when
  a new field is added but a `copyWith` override isn't updated. No gap.
- `canShowFullscreenAdPeek`'s "no side effect" doc claim verified: the
  fraud-pause trigger only runs when `recordViolation: true`; the
  timestamp-list trimming that runs on both branches is idempotent
  cleanup, not a result-changing side effect.
- Cross-checked fork 2's flagged lead (see below) — resolved as not a bug.

### Fork 2 (second half): no findings

- **Round 49's `resetSessionCounters()` fix re-verified directly against
  current code**, not the commit message: still does not touch
  `_fullscreenImpressions`/`_fullscreenClicks`/
  `_ctrPauseTriggeredAtImpressionCount`. Cross-checked `resetSession()`
  (a strict superset of `resetSessionCounters()`'s field list plus fraud
  history) and `resetForReinit()` (layers cold-start/background-flag
  resets on top) for the round-46 "two paths, one shared variable" bug
  class specifically — no divergence found between the three reset
  methods' field coverage.
- `_triggerSuspiciousPause`'s exponential backoff
  (`(_suspiciousViolationCount - 1).clamp(0, 6)`) has no overflow/
  wraparound risk — matches round 31's own documented fix reasoning.
- `consumeBackgroundedFromAdClick`: synchronous read-then-clear with no
  `await` inside — Dart's single-threaded execution makes a TOCTOU gap
  structurally impossible here.
- `policyRiskScore` is purely derived and refreshed after every mutator
  including every reset — no independent state to go stale.
- **Lead raised for fork 1 to check:** `_hourlyAdTimestamps.removeWhere`
  (inside fork 1's territory) trims using raw `now - t`, not a
  clock-rollback-clamped comparison — flagged rather than investigated
  out-of-scope. Fork 1 confirmed (see above) this is the safe direction,
  not a bug.

## Test status

No code changes this round — no findings to fix. Full suite unchanged at
**2202/2202 passing** (last verified in round 63's fix commit `12a4e9b`).
`flutter analyze`: 0 issues (unchanged).

## Publish-gate status

Round 64 found **zero** real issues across both slices — the first clean
round since the two-consecutive-clean-rounds gate was established
(tracked since round 55). Round 63 immediately before it was not clean
(1 MAJOR). Per this repo's own established convention, one clean round
does not close the gate — round 65 would need to also come back clean to
satisfy it.

## Recommendation

No blockers. `ad_safety_config.dart` — the widest-blast-radius,
most safety-critical file in the codebase — is now genuinely clean after
a real full pass split across two adversarial forks, closing the last
major gap flagged as unaudited this session. Combined with round 63's
`ad_config.dart` clean verdict, every file this session identified as
"large and not yet given a dedicated full pass" now has one. This is a
natural stopping point for this audit sprint: 8 rounds (57-64), 7 real
MAJOR + 2 real MINOR found and fixed same-day (none ever shipped), and
the first clean round arriving right as the deliberately-targeted list of
large under-audited files ran out. Flagging back to the human for the
publish decision — this session will not auto-continue to round 65
without direction.
