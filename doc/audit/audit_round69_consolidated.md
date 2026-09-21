# Audit round 69 — consolidated verdict

**Date:** 2026-09-21
**Codebase audited:** `main` HEAD at session start (post-3.0.8, post round-68
security work: `keystore.jks` and a leaked AppLovin SDK key purged from git
history the day before).

## Method

5 internal Claude forks, targeting the one gap round 68 explicitly disclosed
rather than a repeat of any prior round's scope:

> "Round 68 closes the last named gap in `lib/src/`... `ad_manager.dart`
> (9155 lines) ... has not had a genuine full-pass adversarial audit —
> only grep-verified spot checks across many rounds."

| # | Fork | Scope | Outcome |
|---|---|---|---|
| 1 | A | `ad_manager.dart` lines 1–3065, adversarial | **1 MAJOR** |
| 2 | B | `ad_manager.dart` lines 3065–6130 (init + consent machinery), adversarial | clean |
| 3 | C | `ad_manager.dart` lines 6130–9195 (rest of file), adversarial | clean |
| 4 | D | Independently re-verify round 68's guard fix + review today's new code (QA fleet hashes, `CHANGELOG_ARCHIVE.md` split) | clean |
| 5 | E | Regression check: `flutter analyze`/`test`, re-verify R65/R67/R68 fixes, pub.dev state, git log sanity, working-tree secret sweep | clean |

Every finding below was re-verified against the actual code by the
orchestrating session before being accepted or fixed, per this repo's
standing practice — a fork's report is a lead, not a verdict.

## Finding — [MAJOR, confirmed & fixed] Round 68's guard fix covered 5 of ~33 seams sharing the same gap

**Source:** fork A (lines 1–3065).

**Mechanism:** round 68 (previous round, same overall session) fixed one
MAJOR: `AdManager.debugSetAdapter`/`debugAdapterFactory`/`debugVipManager`/
`debugConsentManager`/`debugConfig` were only `@visibleForTesting` — an
analyzer lint, not a runtime guard — so any code running in the same
isolate as a shipped release app could call them to silently swap out real
adapter/VIP/consent state. The fix added a `kReleaseMode`-gated no-op guard
(`_testSeamsBlocked` / `_warnSeamBlocked`), verified airtight for those 5
seams by both round 68 and this round's fork D.

Fork A, working through the first third of the same file that fix lives in,
found the identical unguarded pattern repeated **28 more times** — every one
a public `@visibleForTesting` setter or method with no runtime check,
callable from a shipped release app to silently corrupt real state. A
systematic re-count across the *entire* file (not just fork A's third)
during the fix pass found **33 total**, including several fork A didn't
have in its assigned range:

- **`debugApplyUmpConsentResult`** — applies an arbitrary `UmpConsentResult`
  exactly as a real UMP round trip's tail would, with no UMP channel
  involved. The single most severe of the batch: called with a forged
  "granted" result, this directly forges GDPR consent state.
- **`debugResetGuardState`** — wipes every footgun guard
  (`_footgunBlocked`, `_testIdFootgunBlocked`, UMP retry/abandoned-form
  flags, ...) at once in a single call.
- **`debugCanRequestAds`** / **`debugFootgunBlocked`** /
  **`debugTestIdFootgunBlocked`** — directly flip the exact gates round
  26/45/46 built to keep ad requests off when consent or release-safety
  conditions aren't met.
- **`debugResetBannerCooldown`** / **`debugResetMrecCooldown`** /
  **`debugResetNativeCooldown`** — clear the load-cooldown bookkeeping the
  SDK uses to prevent ad-request spam, i.e. exactly the "invalid traffic"
  class of risk the SDK's own safety layer exists to prevent.
- **`debugRemoteSafetyProvider`** / **`debugLastAppliedRemoteSafetyRevision`**
  / **`debugFeatureFlagsRevision`** — together let arbitrary code inject a
  fake remote-safety provider *and* clear the revision guard that would
  otherwise reject re-applying it.
- **`debugConnectivityInit`** / **`debugConnectivityChanged`** /
  **`debugConnectivityReady`** / **`debugStopConnectivityWatch`** /
  **`debugStartConnectivityWatch`** / **`debugRetryRefillAds`** /
  **`debugStartAdRetryTimer`** / **`debugStopAdRetryTimer`** — collectively
  let arbitrary code forge the SDK's view of network state or force retry
  timers to fire on demand.
- **`debugCurrentDeviceGAID`** — overwrites the session's device GAID,
  which the VIP whitelist (`AdConfig.vipDeviceGaids`) matches against —
  usable to self-grant VIP.
- **`debugEmit`** / **`debugEventLog`** — inject fabricated `AdEvent`s or
  replace the compliance/revenue event log wholesale.
- **`debugUmpAttemptFailed`** / **`debugUmpFormAbandoned`** /
  **`debugUmpRequested`** / **`debugConsentExplicitlySet`** /
  **`debugLastUmpResult`** / **`debugRecheckAbandonedUmpForm`** — feed
  fabricated state into the consent-coverage footgun's own decision logic.
- **`debugClearNavigatorKey`** — nulls the navigator key App Open/dialog
  flows depend on, with no crash and no log.
- **`debugAttachFullscreenDismissWatchers`** /
  **`debugDetachFullscreenDismissWatchers`** — detaching in production
  could reopen the exact App-Open-stacks-on-a-modal policy risk
  `showAppOpenAdOnResume`'s dialog check exists to prevent.
- **`debugSetLastShownPlacement`** — corrupts the attribution bookkeeping
  the `maxVetoRate` anti-fraud guardrail (round 51) reads.
- **`debugSimulateInternalRetryRaceWithBusyGuard`** — deliberately arms an
  internal race condition; harmless in a test, a stability risk if
  triggered for real.

**Deliberately excluded from the guard** (verified safe or out of scope,
not overlooked):
- `debugApplyConsentFootgunGuard(bool isRelease)` /
  `debugApplyTestIdFootgunGuard(bool isRelease, config)` — take `isRelease`
  as a parameter and route through `isActuallyRelease()`, which **ORs**
  with the real `kReleaseMode` — a caller can only make these *more*
  restrictive, never less. Guarding them would be redundant.
- `debugResetLastSkip`, `debugBumpInitGen`, `debugReconnectDebounce`,
  `debugResetPreInitExperimentId` — pure diagnostic/timing bookkeeping with
  no plausible path to a fraud, compliance, or revenue-hiding outcome even
  if misused.

**Fix:** all 33 now check `_testSeamsBlocked` (the same static getter round
68 introduced — `kReleaseMode || debugSimulateReleaseModeForTestSeams`) and
no-op with a `SafeLogger.e` warning instead of applying, identical pattern
to round 68's fix. Applied mechanically via a scripted literal-string
replacement (33 exact matches, zero ambiguous ones) rather than by hand, to
avoid transcription error across that many call sites.

**Tests:** 4 new regression tests added to
`test/ad_manager_debug_seam_release_guard_test.dart` (10 total in that
file), one per risk category (ads-gate, footgun, consent-state,
bulk-reset) rather than one per seam — the pattern is what needs proving,
not each of the 33 individual applications of it. RED/GREEN-verified for
`debugResetGuardState` by temporarily disabling its guard and confirming
the new test fails, then restoring it.

## Checked, clean

- Fork B: `initialize()`, `setConsent()`, `requestUmpConsent`/
  `_applyUmpConsentResult`, `_recoverConsentGate` and surrounding consent
  machinery (lines 3065–6130) — the single highest-density area for prior
  MAJOR findings (rounds 13, 14, 18, 25, 26, 38, 39, 46...). No new issue;
  every race condition considered traces to an already-documented,
  correctly-placed fix.
- Fork C: full lifecycle/load/show surface for every ad type, `destroy()`,
  connectivity watch, retry scheduling, VIP bridge methods (lines
  6130–9195). No new issue.
- Fork D: round 68's actual guard implementation (the 5 seams it covers) —
  re-verified airtight independently: exactly one write site for `_adapter`
  (private, unreachable except through the guarded seam or real init/
  destroy), exactly one read site for the static `debugAdapterFactory`
  field, both gated correctly. `kQaTestDeviceHashes` (17 entries, added
  earlier this session): no duplicates, correct syntax. `CHANGELOG_ARCHIVE.md`
  split: correct chronological order, file present in `dart pub publish
  --dry-run`'s file list (not silently excluded).
- Fork E: `flutter analyze` 0 issues, `flutter test` 2211/2211 (pre-fix
  baseline) passing. R65 (`native_ad_widget.dart` cross-adapter identity
  guard), R67 (`consent_manager.dart` persist-lock await), R68 (all 4
  guarded seam sites) — all re-verified intact, no regression from the
  3.0.4→3.0.8 release sequence or the two `git filter-repo` history
  rewrites earlier this session. pub.dev live version matches local. `git
  log` clean, no stray conflict markers or empty commits. Working tree
  (not git history) confirmed free of both secrets purged this session.

## Test status

`flutter analyze`: 0 issues.
`flutter test`: **2215/2215 passing** (2211 baseline + 4 new round-69
regression tests).

## Recommendation

Found and fixed 1 real MAJOR, same-day, with regression tests. This closes
out the debug-seam-guard gap class entirely for `AdManager` — round 68 and
69 together cover all 33 members of this shape in the file. No blocker for
continued production use; recommend publishing this fix given the same
severity class as round 68's (already shipped in 3.0.7/3.0.8's consuming
versions).
