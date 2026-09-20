# Audit round 61 — consolidated verdict

**Date:** 2026-09-20
**Codebase audited:** `main` HEAD `fa748db` (round 60's fix + doc on top
of round 59's fix; published pub.dev **3.0.2**, `pubspec.yaml` still
`3.0.2`, CHANGELOG has `[Unreleased]` section).

## Method

One in-session Claude fork, dispatched specifically to close a gap round
60 explicitly flagged as unresolved: `lib/src/monetization/
journey_prefetcher.dart` and `waterfall_tuner.dart` had only been
time-boxed-skimmed, not given a full adversarial pass. `codex exec` still
inside its usage-limit retry window from round 57 — not attempted.

Scope: both files, full read, with an explicit directive to check for the
same two bug classes rounds 59 and 60 had just found (test fixtures that
hand-build data instead of exercising the real event pipeline; averaging
over populations that don't actually correspond to each other) before
concluding either file clean.

## Findings

**1 real, MAJOR.** Fixed same-day (commit `4665ab1`), never shipped.

### `WaterfallTuner.recommendation()` trusted a revenue score backed by a single outlier sample

`lib/src/monetization/waterfall_tuner.dart`'s `minSampleSize` (6) gate
only counted trailing **load** attempts before trusting a provider
comparison. But `_score()` (`fillRate * avgEcpmMicros`) depends on
`_revenueMicros`, a separate, independently-sized list from
`_loadResults` — a load succeeding doesn't mean that impression ever
showed and paid out. 6 load attempts could coexist with a single revenue
sample driving the entire score. Reproduced with a real, non-mocked test
(`WaterfallTuner` + `AdManager().debugEmit`): current provider with 6
loads + 6 revenue events averaging $0.10, other provider with 6 loads but
only **1** revenue event at $0.50 — `recommendation()` returned a
non-null switch recommendation driven entirely by that one outlier. This
is a production-facing feature (`AdManager().enableWaterfallTuner()`),
directly in this SDK's "dual-provider revenue-integrity" core promise — a
host acting on this recommendation could switch providers next session
based on statistical noise from a single data point.

**Fix — and a design correction found while fixing it:** the first
attempt gated revenue-sample count on *both* the current and recommended
provider, which broke `self_healing_observer_test.dart`'s existing "0%
fill rate → recommend switching away" scenario: a provider that never
fills legitimately has 0 revenue samples too, and that's a confident
signal (from a well-sampled fill rate), not noise the gate should block.
Corrected to gate only the *recommended* provider's revenue-sample count
— the side whose score a switch decision actually has to trust. Added a
regression test locking in this asymmetry (0%-fill current provider still
gets a recommendation away from it) alongside the two tests reproducing
the original bug and its fix. 4 pre-existing tests had fixtures that
emitted too few revenue events to exercise the load-attempt-threshold
logic they were actually testing (a gap that predates this bug but was
only surfaced by adding the new, correct gate) — updated to emit enough.
2197/2197 suite green across 3 full runs (a handful of unrelated,
timing-sensitive tests — `r23_coppa_midinit_flip_test.dart`,
`vip_redeem_screen_test.dart` — flake under full-suite parallel
contention but pass reliably in isolation; not caused by this change),
`flutter analyze` clean.

### `journey_prefetcher.dart`: no findings, full pass confirmed

Read completely, traced call sites, adversarially attempted to reproduce
multi-key type collisions, `DateTime` ties, stale pending signals without
a TTL, and key-splitting bugs when a signal string itself contains the
`|` separator — every one already has correct defense in the code (T133's
`maxPendingSignalAge` TTL, a T136-style race guard, the T162 pipe-split
fix, T198's route-observer `didPop`/`didReplace` handling, round 35's
sequence tie-break). `test/journey_prefetcher_test.dart` drives events
through the real `AdManager().debugEmit()` → real `AdEvent` objects, not
hand-built maps — immune to the round 59/60 bug class by construction.

## Test status

Full `packages/ad_sdk` suite: **2197/2197 passing** (3 new regression
tests, 4 pre-existing fixtures corrected). `flutter analyze`: 0 issues.

## Publish-gate status

Round 61 found & fixed 1 real MAJOR — not clean. Rounds 57 through 61
have each found at least one real issue (4 MAJOR fixed across 57/59/60/61,
1 MAJOR self-introduced-and-fixed-same-day in round 57, 1 MINOR
documented-not-fixed in round 58); the two-consecutive-clean-rounds bar
remains unmet after 61 rounds.

## Recommendation

No blockers — round 61's finding never shipped. This closes the specific
gap round 60 flagged (`journey_prefetcher.dart`/`waterfall_tuner.dart`
now both have a real full pass on record). Five consecutive rounds each
finding genuine, previously-unknown, non-trivial issues is an unusually
high hit rate for this codebase's audit history at this depth of prior
coverage — flagging back to the human on whether continued rounds are
worth their resource cost versus shipping what's already fixed and
verified. Two leads remain outside this session's reach if audit
continues: round 58's AppLovin click-callback staleness lead (needs a
real device + real AppLovin SDK key, not available to the agent), and
whatever `codex exec` would have found across rounds 57-61 had it not
been usage-limited the entire time.
