# Audit round 59 — consolidated verdict

**Date:** 2026-09-20
**Codebase audited:** `main` HEAD `b0f0f1c` (round 58's doc on top of
round 57's fix; published pub.dev **3.0.2**, `pubspec.yaml` still
`3.0.2`, CHANGELOG has `[Unreleased]` section).

## Method

Two in-session Claude forks, per round 58's recommendation to target
`lib/src/monetization/` sub-areas not covered by rounds 51/54, plus a
second slice on long-stale `lib/src/core/` files. `codex exec` still
inside its usage-limit retry window from round 57 (16:55) — not attempted.

1. **Fork (monetization)** — `lib/src/monetization/ad_diagnostics.dart`,
   `revenue_anomaly_detector.dart`, `revenue_integrity_ledger.dart`,
   `self_healing_observer.dart` — the 4 files in that directory that had
   never appeared by name in any prior audit doc. (`fill_rate_monitor.dart`
   / `digital_twin.dart` / `journey_prefetcher.dart` /
   `monetization_arbitrator.dart` / `waterfall_tuner.dart` were touched by
   rounds 23/34/35/36/49 and not re-opened without a new lead.)
2. **Fork (core)** — `lib/src/core/ad_screen.dart`,
   `ad_bootstrap.dart`, `ad_crash_guard.dart`, `ad_route_observer.dart`,
   `integration_self_check.dart` — last touched by round 52's codex pass,
   7 rounds ago. Re-verified round 49's 3 mounted-guards on `ad_screen.dart`
   and round 52's crash-guard/bootstrap fixes are still correctly in place.

## Findings

**1 real, MAJOR.** Fixed same-day (commit `de9b0cf`), never shipped.

### `AdEventLog._eventExtra()` dropped `requestId`, silently disabling 2 of 5 revenue-anomaly kinds

`lib/src/compliance/ad_event_log.dart`'s `_eventExtra()` serialized
`AdRevenueEvent` into the persisted compliance log without its
`requestId` field (present on the class since T185; same omission
existed for `AdShowEvent.requestId`). `RevenueAnomalyDetector.analyze()`
(`lib/src/monetization/revenue_anomaly_detector.dart`), reachable via the
public `AdManager().revenueAnomalies()`, reads `requestId` from that same
persisted map to power `RevenueAnomalyKind.duplicateImpression` and
`.requestIdCollision` — two of its five documented anomaly kinds. Since
the key was never written, every real production entry read back `null`
for it, so both kinds could **structurally never fire** on real data —
silently, with no error or log line indicating the feature was inert.
Worse than the feature not existing: a host calling `revenueAnomalies()`
got a false sense that duplicate-revenue/misattribution detection was
active.

**Why this stayed hidden:** `test/revenue_anomaly_detector_test.dart`'s
fixture builder hand-builds its map with `'requestId': id` set directly,
never going through `AdEventLog.recordEvent()`'s real serialization —
same test-mocks-the-shape-not-the-pipeline gap as round 51's
fill_rate_baseline_monitor findings.

**Fix:** added `requestId` to both `AdRevenueEvent`'s and
`AdShowEvent`'s serialized fields in `_eventExtra()`. Added a new
`test/ad_event_log_test.dart` regression test per event type (confirms
`requestId` round-trips through the real persisted log), plus a
`revenue_anomaly_detector_test.dart` pipeline test that runs
`AdEventLog.recordEvent()` → `RevenueAnomalyDetector.analyze()` (no
hand-built map) and confirms `duplicateImpression` actually fires on
real serialized data. Confirmed RED (both new `ad_event_log_test.dart`
tests, and the pipeline test) before the fix, GREEN after — 2192/2192
suite, `flutter analyze` clean.

### Checked and found NOT bugs (both slices)

**Core slice:** round 49's 3 mounted/disposed guards on `ad_screen.dart`
(`showInterstitialAd`/`showRewardedAd`/`showRewardedInterstitialAd`
completion callbacks) — all still correctly present, no regression, every
async gap re-checked. Round 52's `ad_crash_guard.dart`/`ad_bootstrap.dart`
fixes (independent per-handler reinstall check, null-safe first-install
guard, `hasGaid` redaction) — present exactly as documented.
`ad_route_observer.dart`'s popup-depth counter — hand-traced all 4
`didPush`/`didPop`/`didRemove`/`didReplace` combinations, correct in
every case, clamped at 0. `integration_self_check.dart` — trivial data
holder, nothing to find.

**Monetization slice:** `RevenueIntegrityLedger` — unaffected by the
`requestId` finding above; it reads `requestId` from the live `AdEvent`
stream object, not the persisted log. `SelfHealingObserver` — already
mature (T136 rounds 2/3 + codex P2 clock-rollback fix), no new gap.
`AdDiagnostics.toSafeJsonString`'s truncation loop — bounded correctly.

## Test status

Full `packages/ad_sdk` suite: **2192/2192 passing** (3 new regression
tests). `flutter analyze`: 0 issues.

## Publish-gate status

Round 59 found & fixed 1 real MAJOR — not clean. Rounds 57, 58, and 59
have each found at least one real issue; the two-consecutive-clean-rounds
bar remains unmet after 59 rounds.

## Recommendation

No blockers — round 59's finding never shipped. This session paused
active audit-round spawning here per the human's own next-step choice
(prioritizing a device-based verification of round 58's unconfirmed
click-callback lead, blocked on a real AppLovin SDK key not available to
the agent). Round 60+ scope candidates when resumed: the remaining
`lib/src/monetization/` files not yet independently re-verified
(`fill_rate_monitor.dart`, `digital_twin.dart`, `journey_prefetcher.dart`,
`monetization_arbitrator.dart`, `waterfall_tuner.dart` — all last touched
2+ months/20+ rounds ago even though a prior round covered them), or
`lib/src/vip/` (last independent slice: round 52's Fork F).
