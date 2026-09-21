# Audit round 70 — consolidated verdict

**Date:** 2026-09-21
**Codebase audited:** `main` HEAD post-3.0.9 (round 69's `AdManager`
debug-seam guard fix, 33 seams).

## Method

Round 69 fixed the debug-seam-guard gap in `AdManager` (33 seams). Before
declaring the *class* of bug closed, a quick scan checked whether the same
`@visibleForTesting`-without-runtime-guard pattern existed anywhere else in
files with debug seams of their own. It did: 11 candidates across the 4
largest other source files
(`lib/src/adapters/applovin_adapter.dart`,
`lib/src/adapters/admob_adapter.dart`,
`lib/src/core/ad_safety_config.dart`,
`lib/src/core/iab_storage.dart`). All 11 were read and verified directly
(no fork dispatch needed — small, well-scoped list) before fixing.

## Finding — [MAJOR, confirmed & fixed] Same debug-seam-guard gap in 4 more files, 11 seams

**Mechanism:** identical to round 68/69 — `@visibleForTesting` is an
analyzer lint, not a runtime check. Every one of these 11 is reachable from
a shipped release app via `AdManager().adapter as AppLovinAdapter` (or
`AdMobAdapter`), which is itself a normal, unguarded public cast — round
68/69's `AdManager`-level guard only protects *replacing* the adapter, not
calling methods on the real one once obtained this way.

**`applovin_adapter.dart` (4 seams):**
- `debugSimulateRewardedShowAndDismiss` — fires the reward-granting
  callback (`void Function(RewardResult)`) directly, with no real ad ever
  shown. The single most severe finding of this round: called with
  `dismissed: true` in a shipped app, this grants a fake reward (VIP time,
  in-app currency, whatever the host wires to it) for free.
- `debugSimulateInterstitialShowAndDismiss` — same shape, fires the
  show/dismiss callback without a real ad.
- `debugStartAppOpenWatchdog` — forces the App Open slot into `showing`
  state and arms a watchdog with an arbitrary callback, desyncing the
  state machine from reality.
- `debugSetBannerAdViewIdForTest` — lower severity (desyncs banner
  pause/resume bookkeeping) but same unguarded shape; included for
  consistency.

**`admob_adapter.dart` (4 seams):** the identical 4-seam shape —
`debugSimulateRewardedShowAndDismiss`, `debugSimulateInterstitialShowAndDismiss`,
`debugSimulateAppOpenShowAndArmWatchdog`, plus
`debugReplaceAppOpenAdUnsafe` (replaces the live `GmaFullscreenAd` object
outright — the name says "unsafe" in the method itself, but that warning
was a doc comment, not a guard).

**`ad_safety_config.dart` (2 seams):**
- `debugExpireSuspiciousPause` — directly zeroes the invalid-traffic
  suspicious-pause timestamp, defeating the exact throttle this class
  exists to enforce (confirmed by the new regression test: 5 rapid clicks
  arm a real 30-minute pause via `recordAdClick`, the seam clears it
  instantly while release-mode is simulated).
- `debugSetLastViolationTimestamp` — feeds a fabricated timestamp into the
  same violation-decay logic.

**`iab_storage.dart` (1 seam):** `debugResetForTest` clears the cached
`SharedPreferencesAsync` store reference. Lower severity than the above
(forces a cache re-open, not a direct fraud/consent bypass) but included
for consistency with the "guard every `@visibleForTesting` mutator unless
provably safe" policy this file's own class-level comment already states
elsewhere in the codebase.

**Fix:** each of the 4 files got its own copy of the same
`debugSimulateReleaseModeForTestSeams` / `_testSeamsBlocked` /
`_warnSeamBlocked` pattern `AdManager` already uses (these are separate
classes, not subclasses, so the guard infrastructure is duplicated per
file rather than shared — matches the existing codebase convention of
`isActuallyRelease()` as the shared *primitive*, with each class wiring
its own seam-blocking check on top of it).

**Tests:** 3 new regression tests in
`test/adapter_debug_seam_release_guard_test.dart` — one per file/category
(`AdMobAdapter` reward-forgery, `AdSafetyConfig` invalid-traffic-pause,
`IabStorage` no-throw) rather than one per seam; `AppLovinAdapter` shares
the identical verified mechanism and wasn't separately tested (more
complex to construct in a unit test, no additional risk-class coverage
gained). RED/GREEN-verified for the `AdMobAdapter` reward-forgery test by
temporarily disabling its guard and confirming the test fails, then
restoring it. The `AdSafetyConfig` test arms a *real* invalid-traffic
pause via the actual public `recordAdClick()` path (not a debug seam) to
avoid the test proving nothing by only ever observing a default `false`
state.

## Test status

`flutter analyze`: 0 issues.
`flutter test`: **2218/2218 passing** (2215 baseline + 3 new round-70
regression tests).

## Recommendation

Found and fixed 1 real MAJOR (11 seams across 4 files, same severity class
as round 68/69's `AdManager` finding), same-day, with regression tests.
This closes the debug-seam-guard gap class across every file in `lib/src/`
identified as having `@visibleForTesting` mutators of real state — 44 total
seams now guarded across the three rounds (round 68: 5 on `AdManager`;
round 69: 28 more on `AdManager`; round 70: 11 across the two adapters,
`AdSafetyConfig`, and `IabStorage`). No blocker for continued production
use.
