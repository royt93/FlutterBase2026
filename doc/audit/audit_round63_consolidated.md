# Audit round 63 — consolidated verdict

**Date:** 2026-09-20
**Codebase audited:** `main` HEAD `6a3dd64` (round 62's fix + doc on top
of round 61's fix; published pub.dev **3.0.2**, `pubspec.yaml` still
`3.0.2`, CHANGELOG has `[Unreleased]` section).

## Method

Two in-session Claude forks, per the human's explicit choice to target
the two largest files deliberately excluded from round 62's config/
and consent/ slices for time-budget reasons.

1. **Fork (ad_config)** — `lib/src/config/ad_config.dart` (658 lines),
   the SDK's single host-facing configuration entry point. Never given a
   dedicated full pass this session.
2. **Fork (consent core)** — `lib/src/consent/consent_manager.dart` (409
   lines) and `consent_settings.dart` (144 lines), excluded from round
   62's consent/ slice. Specifically directed to re-verify round 57's
   same-day `onConsentProvenanceEntryAppended`/journal wiring.

## Findings

**1 real, MAJOR.** Fixed same-day (commit `12a4e9b`), never shipped.

### `ConsentManager.bootstrap()` didn't honor a later call disabling the provenance journal

`bootstrap()`'s journal-reassignment was conditional on the
`provenanceJournal` argument being non-null:
`if (provenanceJournal != null) { m._journal = provenanceJournal; }`.
`ConsentManager` is a singleton that **survives a reinit without
`destroy()`** by its own documented design (the same property behind
"Audit finding B", already fixed in an earlier round for the opposite
direction — enable-then-enable-with-a-different-journal-instance).
Concrete scenario: session 1 calls `initialize()` with
`enableConsentProvenanceJournal: true` → the singleton's `_journal`
points at journal A. Session 2 (reinit, no `destroy()`) calls
`initialize()` with `enableConsentProvenanceJournal: false` →
`AdManager().consentProvenanceJournal` correctly reports `null` (a host
checking this believes the feature is off), but `ConsentManager._journal`
still points at journal A — every subsequent `set()`/`reset()` (through
`_recordProvenance`) kept silently appending entries to it, now
unreachable through any public API for reading or clearing. A real
data-minimization/compliance concern for a feature specifically about
provable consent history.

Additionally found: a stale, incorrect comment in `ad_manager.dart`
directly above the `ConsentManager.bootstrap()` call site, claiming "the
very first bootstrap() call (the only one that honors this param...)" —
this directly contradicted `ConsentManager.bootstrap`'s own correct doc
comment (which explicitly says `provenanceJournal` IS re-adopted on every
call, unlike `prefs`), and could have misled a future reader into
"fixing" the wrong thing.

**Fix:** the reassignment is now unconditional — `m._journal =
provenanceJournal;` — matching the already-correct behavior for every
non-null value. Also corrected the stale `ad_manager.dart` comment. 2 new
regression tests in `test/consent_manager_provenance_test.dart` confirm:
(1) a second `bootstrap()` call with `provenanceJournal: null` stops
recording to the journal wired by the first call, and (2) a third call
re-enabling it resumes recording. Confirmed RED before the fix (2 entries
recorded where 1 was expected after the "disable" call), GREEN after.
2202/2202 suite, `flutter analyze` clean.

### `ad_config.dart`: no findings, full pass confirmed

Traced every field's real call sites in `ad_manager.dart` rather than
trusting doc comments. The constructor's provider/config-mismatch
`assert` (stripped in release builds) was specifically checked for a
release-mode null-unwrap risk — every `config.appLovin`/`config.admob`
use found is null-safe; worst case is silently-empty ad-unit IDs, not a
crash, and `releaseFootgunWarnings()` already surfaces the dangerous case
loudly. `AppOpenTrigger`'s 3 gating call sites (the specific shape to
check for round 46's "two fixes sharing one variable" bug class) are
consistent with each other and their own doc comments — no drift.
`firstInstallVipGrace` is backed by the Keychain/SharedPreferences-backed
`FirstInstallGuard`, not an in-memory flag — immune to round 62's
"guard doesn't survive restart" bug shape by construction.

### `consent_settings.dart`: no findings

Pure data class — `copyWith`'s `clearAskedAt`/`clearCountry` asserts and
`fromJson`/decode fail-safe behavior verified correct.

## Test status

Full `packages/ad_sdk` suite: **2202/2202 passing** (2 new regression
tests). `flutter analyze`: 0 issues.

## Publish-gate status

Round 63 found & fixed 1 real MAJOR — not clean. Rounds 57 through 63
have each found at least one real issue (7 MAJOR fixed total across
57/59/60/61/62/63, plus round 57's own same-day self-introduced-and-fixed
bug, plus 2 MINOR); the two-consecutive-clean-rounds bar remains unmet
after 63 rounds.

## Recommendation

No blockers — round 63's finding never shipped. `ad_config.dart` (the
widest-blast-radius file in the codebase) is now genuinely clean after a
real full pass. Consent-related code specifically has now had 3
same-day rounds' worth of dedicated attention (round 57's new hook,
round 62's CCPA/fallback files, round 63's core manager/settings) and
found one more real, previously-13-round-unnoticed bug — this argues
for real remaining risk in under-audited large files rather than
diminishing returns purely from round count. `ad_safety_config.dart`
remains the largest file in the codebase never given a dedicated full
pass this session, if audit continues.
