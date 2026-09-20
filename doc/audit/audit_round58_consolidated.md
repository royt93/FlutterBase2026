# Audit round 58 — consolidated verdict

**Date:** 2026-09-20
**Codebase audited:** `main` HEAD `2167f72` (round 57's fix + doc on top
of round 56's fixes; published pub.dev **3.0.2**, `pubspec.yaml` still
`3.0.2`, CHANGELOG has `[Unreleased]` section).

## Method

Two in-session Claude forks, per round 57's recommendation to move to
fresh/long-stale areas instead of re-scanning `lib/src/widget/` (already
at saturation).

1. **Fork Q** — `lib/src/adaptive/`, last independently audited round 53
   (5 rounds ago).
2. **Fork R** — `lib/src/adapters/`, focused on `applovin_adapter.dart`
   and `admob_adapter.dart` specifically (stale 12-13 rounds — last
   touched rounds 44/45; the smaller support files in this directory were
   already covered directly by round 52 and were not re-opened without a
   new lead).

`codex exec` was not attempted this round — still inside the usage-limit
retry window from round 57 (16:55).

## Findings

**1 real, MINOR.** No MAJORs.

### Fork Q: `AdaptiveFrequencySignals.setSink()` race on overlapping `initialize()`

`lib/src/core/ad_manager.dart:3241` — `AdaptiveFrequencySignals.setSink(
_eventLog!.recordAdaptiveSignal)` runs early in `initialize()`, before the
epoch/supersede check further down (~line 3499) that exists specifically
to confirm "this attempt is still the live one." `_sink` is a static
field. Two overlapping `initialize()` calls (e.g. `destroy()` immediately
followed by a fresh `initialize()` while the first attempt is still
awaiting `AdPreferences.getInstance()`) both call `setSink()` unguarded —
whichever call reaches it last wins, independent of which attempt the
epoch check later judges to be the live one. A live session's
adaptive-frequency telemetry could land in a torn-down session's
`AdEventLog`, or vice versa.

**Why MINOR, not MAJOR:** `lib/src/adaptive/adaptive_frequency.dart`
documents itself as "Phase 1 instrumentation only... WITHOUT adjusting
any cap" — nothing reads this signal to gate an ad, so the blast radius
is a few misattributed diagnostic log lines, not a user-visible behavior
change, crash, leak, or compliance issue. The ring buffer is capped (500
entries) and `resetForReinit()` (`ad_safety_config.dart:1148`, invoked via
`ad_manager.dart:6616` on `destroy()`) already cleans up correctly on the
normal teardown path — this is specifically about which live session a
signal gets attributed to during an overlapping-initialize window, not a
leak or corruption.

**Decision: documented, not fixed.** This repo already has a materially
identical, deliberately-undone case in the same file — the comment at
`ad_manager.dart:3517-3524` ("not independently pinnable... Deleting this
block keeps the suite green") accepts the same class of epoch-guard gap
for a different piece of state, on the same reasoning: a diagnostic-only
signal doesn't justify the guard's cost today. Revisit if/when Phase 2
(the adaptive-frequency signal actually adjusting a real cap) ships — at
that point this becomes user-visible and the severity should be
re-assessed as MAJOR.

### Fork R: no confirmed findings — one unverified lead flagged for later

Traced the full load→show→dismiss→reload cycle for App Open, Interstitial,
and Rewarded on `applovin_adapter.dart`. The round-42 `_isStaleAd`
creativeId guard is present and correct on every `onAdDisplayed`/
`onAdRevenuePaid`/`onAdDisplayFailed`/`onAdHidden` callback across all 3
ad types (12 call sites checked individually, no copy-paste drift). The
`_teardownStarted` guard on both load callbacks matches AdMob's parallel
`_fullscreenDisposed` flag (4 sites), consistent lineage. `dispose()`
clears all native listeners synchronously and early (documented
"order matters" from a round-25-era fix), which is why only the load path
needs the narrower `_teardownStarted` check.

**Unverified lead (not a confirmed finding):** `onAdClickedCallback` for
all 3 fullscreen types (`applovin_adapter.dart:1289,1648,1898`) has no
`_isStaleAd` guard, unlike displayed/hidden/revenue/displayFailed on the
same ad instances. A late click callback from a superseded ad cycle could
plausibly double-record into `AdSafetyConfig.recordAdClick()`'s CTR-fraud
counter — but unlike displayed/hidden (which carry an explicit in-code
note that they're "unreliable, fires late 10-30s"), no equivalent note
exists for click, and whether AppLovin MAX's native SDK can actually fire
a click callback after a newer ad cycle has already loaded cannot be
determined from source alone. This needs native-SDK documentation or a
real device repro to confirm before it can be reported as a real finding,
per this repo's convention against speculative findings (see
`audit-must-be-slow-and-adversarial` — verify the mechanism, don't just
pattern-match "guard present on siblings, absent here" into a bug).
**Flagged for whoever next has device access to `applovin_adapter.dart`.**

## Test status

No code changes this round. Full suite unchanged at **2189/2189 passing**
(last verified in round 57's fix commit `d7a701f`). `flutter analyze`: 0
issues (unchanged).

## Publish-gate status

Round 57 found & fixed 1 real MAJOR (same-day, never shipped). Round 58
found 1 real MINOR (documented, not fixed — see rationale above), which
by this repo's own convention (round 55's 1 MINOR broke that round's
"clean" status the same way) means round 58 is **not** clean either.
Two-consecutive-clean-rounds bar remains unmet after 58 rounds; rounds 59
and 60 would need to both come back with zero real findings to close it.

## Recommendation

No blockers. Neither round 57 nor round 58 found anything that reached a
published version or is user-visible today. Diminishing returns are
visible in the shape of these two rounds' findings (1 same-day
self-introduced bug caught before shipping, 1 documented-not-fixed
Phase-1-diagnostic-only race, 1 unverifiable-without-device-access lead)
compared to round 56's genuine 43-round-old compliance gap — this is
consistent with the codebase converging rather than regressing. Whether
to keep chasing the two-consecutive-clean gate with rounds 59+ (fresh
scope candidates: `lib/src/monetization/` sub-areas not covered by round
51/54, or a real-device repro session for round 58's click-callback lead)
or stop here and ship is a product-priority call, not an audit-completeness
one — flagging back for that decision rather than auto-continuing.
