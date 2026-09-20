# Audit round 50 — consolidated verdict

**Date:** 2026-09-20
**Codebase audited:** `main` HEAD `65eed52` (unreleased round-49 fixes on top of
published pub.dev **3.0.1**; `pubspec.yaml` still `3.0.1`, CHANGELOG has
`[Unreleased]` section).

## Method

Three independent passes ran in parallel, scoped to disjoint slices to avoid
overlap and re-litigating known/accepted items:

1. **`codex exec` (external CLI, real subprocess)** — full adversarial sweep
   of `packages/ad_sdk/lib/src/`, briefed on round 49's findings and the 4
   known-deliberate VIP/trial behaviors to exclude. Ran narrow regression
   (`ad_screen_test.dart`, `consent_us_privacy_propagation_test.dart`, 25
   tests) itself before reporting — all passed. **Usage limit issue from
   rounds 47-49 has cleared** — codex is usable again as of this round.
2. **In-session Claude fork, slice A** — lifecycle/dispose/callback races
   across the whole `lib/src/` tree (banner/mrec/native widgets, all
   fullscreen adapter listeners, connectivity subscription), specifically
   hunting for places the round-46 stale-adapter/stale-callback guard pattern
   (`isStaleAppLovinCallback`, `identical(adapter, capturedAdapter)`) should
   exist but doesn't.
3. **In-session Claude fork, slice B** — safety/fraud gate reset functions
   beyond `resetSessionCounters()` (round 49's fix), consent/footgun flag
   interactions in `ad_manager.dart`, VIP stack/expiry math, and the
   AppLovin pre-init consent guard added in round 45 (R45-01).

`gemini` CLI still not attempted — confirmed deprecated server-side as of
round 49, no reason to expect that changed in one day.

## Findings

**No new findings across all three passes.**

- **codex**: "no new findings. Đã đối chiếu các finding/ngoại lệ round 49, rà
  lifecycle callback, consent/UMP/Privacy Options, US-privacy reconcile và
  safety gates."
- **Slice A**: checked banner/mrec/native dispose+timer cancellation (OK);
  AppLovin fullscreen listeners (interstitial/rewarded/appOpen) already carry
  `_teardownStarted` + `_isStaleAd(creativeId)` guards on every
  state-mutating callback. One candidate investigated and ruled out as a
  false positive: `onAdClickedCallback` has no stale-ad check across all
  three fullscreen types, but `AdSafetyConfig.recordAdClick` is a
  session-global counter and `AdClickEvent`'s payload carries no per-cycle
  state (unlike revenue events, which correctly gate on `requestId`
  staleness) — so a late/stale click callback can't corrupt anything.
  Connectivity subscription already has a generation-token guard against
  double-subscribe (pre-round-48 fix).
- **Slice B**: `ad_safety_config.dart`'s other reset paths
  (`resetSession`/`resetForReinit`), the `_footgunBlocked` /
  `_testIdFootgunBlocked` / `_consentExplicitlySet` /
  `qualifiesAsConsentFlow` flag interactions, `VipManager.addVip`'s
  stack/clamp math, and `applovin_adapter.dart`'s pre-init consent guard
  (lines 834-853, symmetric with `ad_consent.dart`'s post-init guard at
  156-167) all read correctly and match their doc comments.

## What did NOT hold up / known gaps (carried forward, unchanged)

- GPP US-state bit-offset parsers (`iab_storage.dart:427-495`) still
  unverified against an IAB reference encoder — same gap since round 43.
- The round-31 UMP mismatch-warning edge case noted in round 49 (fires once
  at init only, so a post-init `setConsent(isAgeRestrictedUser: true)`
  followed by an actual UMP re-request wouldn't re-check) — still not
  confirmed reachable through any real public API path, not fixed.

## Test status

No code changes this round (no findings to fix). Full suite unchanged from
round 49's last confirmed run: **2172/2172 passing**, `flutter analyze`: 0
issues.

## Publish-gate status

Per this repo's own convention (two consecutive clean rounds with working
external-tool participation before publishing): round 49 itself found 4 real
findings (fixed same round), so it does not count as "clean" toward the
gate even though `codex`/external tooling worked. **Round 50 is the first
fully clean round (zero findings, real external tool ran) since that
bar was last met.** One more clean round would satisfy the two-in-a-row
convention outright — but round 49's findings were fixed and
test-covered same day, and round 50 found nothing new after a real
external-tool pass plus 2 independent internal slices, so the remaining
gap is process-convention, not a known open defect.

## Recommendation

No blockers. Round 49's fixes remain the only pending change
(`[Unreleased]` in CHANGELOG, `pubspec.yaml` still 3.0.1). Decision on
whether to treat round 50 as sufficient to publish 3.0.2, or run round 51
first for the formal two-in-a-row, is a product call, not a code one.
