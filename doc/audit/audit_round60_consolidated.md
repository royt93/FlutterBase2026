# Audit round 60 — consolidated verdict

**Date:** 2026-09-20
**Codebase audited:** `main` HEAD `3d06eda` (round 59's fix + doc on top
of round 58's doc; published pub.dev **3.0.2**, `pubspec.yaml` still
`3.0.2`, CHANGELOG has `[Unreleased]` section).

## Method

Two in-session Claude forks, per round 59's recommendation. `codex exec`
still inside its usage-limit retry window from round 57 (16:55) — not
attempted this round either.

1. **Fork (vip)** — all 10 files in `lib/src/vip/` (4740 lines), last
   independently audited round 52's Fork F, 8 rounds ago. Focused depth
   on `vip_manager.dart` (1850 lines, never individually named in round
   52's doc) and `_first_install_guard.dart` (round 49's fix target).
2. **Fork (monetization)** — `fill_rate_monitor.dart`, `digital_twin.dart`,
   `journey_prefetcher.dart`, `monetization_arbitrator.dart`,
   `waterfall_tuner.dart` — each last touched by rounds 23/34/35/36/49
   respectively. Also specifically checked whether `fill_rate_monitor.dart`
   / `monetization_arbitrator.dart` share round 59's "test hand-builds
   fixture data instead of going through the real persistence pipeline"
   bug class — they read live `AdEvent` objects off `AdManager().events`
   directly, not `AdEventLog`'s persisted map, so they're structurally
   immune to that specific gap.

## Findings

**1 real, MAJOR.** Fixed same-day (commit `de446d4`), never shipped.

### `MonetizationDigitalTwin` mixed banner/mrec/native revenue into a fullscreen-only forecast

`lib/src/monetization/digital_twin.dart`'s `_groupByDay()` correctly
scoped `shown`/`blockedByDailyCap` to fullscreen-only events (`AdShowEvent`
is never emitted by banner/mrec/native — confirmed via `AdEvent`'s own doc
comment), but summed `revenueMicros` from **every** `AdRevenueEvent`
regardless of slot type — confirmed via `admob_adapter.dart` that
banner/mrec/native each emit their own `AdRevenueEvent`.
`forecastDailyCap()` computes `avgRevenuePerShow = revenueMicros / shown`
(fullscreen impressions only) to answer "what would raising/lowering the
fullscreen daily cap do to revenue" — mixing in banner/mrec/native revenue
inflates that average by however much of the day's revenue came from
formats the cap being forecast doesn't even affect. Concrete scenario: an
app running $50/day of banner revenue plus 5 real $2 interstitials
(entirely normal for this dual-format SDK) gets `avgRevenuePerShow = $12`
instead of the true $2 — a ~6x overstatement that could lead a host to
raise its fullscreen cap based on a forecast that was never really about
fullscreen ads at all.

**Why this stayed hidden:** `test/digital_twin_test.dart`'s existing
fixtures never mixed a banner/mrec/native revenue event into the same day
as a fullscreen one — round 27 (agy) and round 51 both listed this file
as "clean"/in-scope without exercising the cross-format-mixing path.

**Fix:** added a `_fullscreenSlotTypes` constant set
(`appOpen`/`interstitial`/`rewarded`/`rewardedInterstitial` — the same set
`AdShowEvent` covers) and scoped the revenue sum to it. 2 new regression
tests confirm the exclusion (banner/mrec/native revenue absent from the
forecast) and the non-regression (all 4 fullscreen formats, not just
interstitial, still count). Confirmed RED before the fix (`152000000.0`
instead of the expected `2000000`), GREEN after. 2194/2194 suite,
`flutter analyze` clean.

### Fork (vip): no findings — highest-stakes area, genuinely tried to break it

Traced `redeemSignedKey()`'s one-time-use claim (atomic check +
`_signedKidsInFlight.add()`, no await between; release in `finally`
covering every exit path including the mid-flight `_disposed` check);
`addVip()`'s 90-day stack clamp (computed from `now.add(cap)`, no
unbounded accumulation across repeated stacks, no overflow risk — inputs
already bounded by `signed_vip_key.dart`'s `_maxSeconds`); every
await-gap in `redeemSignedKey` (network poll, `PackageInfo`, CRL load,
`addVip`'s `_save()`) re-checks `_disposed` after the await, before
burning the key, matching round 25's fix. Re-verified the first-install
Keychain-flag-before-prefs-flag ordering at `ad_manager.dart:3380-3463`
directly — the `alreadyGranted` branch correctly skips re-writing an
already-present Keychain flag, not a bug. The CRL self-attestation gap is
already a documented, 3-reviewer-confirmed accepted risk from round 42,
not a new finding. One non-finding noted for the record: `AVP2`'s
`expEpoch` field has no upper-bound check unlike `duration`'s
`_maxSeconds` clamp — not exploitable since the field lives inside the
Ed25519-signed payload an attacker without the private key cannot set.

### Fork (monetization): `journey_prefetcher.dart` / `waterfall_tuner.dart` only skimmed, not a full pass

Both showed a consistent `_disposed` guard pattern against a
subscribe-during-hydrate race, matching an already-established pattern
elsewhere — but the fork's own report flagged this was a time-boxed skim,
not the same depth of adversarial attempt as `digital_twin.dart` got.
**Not claiming these two files are clean** — round 61, if it runs, should
give them a dedicated full pass rather than treating this skim as
coverage.

## Test status

Full `packages/ad_sdk` suite: **2194/2194 passing** (2 new regression
tests). `flutter analyze`: 0 issues.

## Publish-gate status

Round 60 found & fixed 1 real MAJOR — not clean. Rounds 57 through 60
have each found at least one real issue (3 MAJOR fixed, 1 MINOR
documented-not-fixed); the two-consecutive-clean-rounds bar remains
unmet after 60 rounds.

## Recommendation

No blockers — round 60's finding never shipped. Four consecutive rounds
each finding a real, previously-unknown, non-trivial bug (async-callback
leak, dead anomaly-detection feature, revenue-forecast skew, and round
57's own self-introduced bug caught same-day) is not typical for this
codebase's audit history at this depth of prior coverage — this is worth
flagging back to the human rather than mechanically continuing to round
61, both because of the value being found and because of the
resource cost of each round. Two concrete leads remain if audit
continues: `journey_prefetcher.dart`/`waterfall_tuner.dart` need a real
adversarial pass (only skimmed this round), and round 58's AppLovin
click-callback staleness lead still needs a real-device repro with a real
SDK key.
