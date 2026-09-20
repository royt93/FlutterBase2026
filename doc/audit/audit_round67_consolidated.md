# Audit round 67 — consolidated verdict

**Date:** 2026-09-20
**Codebase audited:** `main` HEAD `85f0577` (round 66's doc on top of
round 65's fix; published pub.dev **3.0.2**, `pubspec.yaml` still
`3.0.2`, CHANGELOG has `[Unreleased]` section).

## Method

One in-session Claude fork (single target — the last file in `lib/src/`
never given a dedicated full-pass audit this session, confirmed by
scanning all 83 files in `lib/src/` against every `doc/audit/*.md`).

1. **Fork M** — `lib/src/consent/consent_manager.dart` (417 lines).
   Only previously touched via call-site spot-checks (round 63's
   `bootstrap()` journal-field fix); never itself read end-to-end
   adversarially. Directed to specifically check for siblings of round
   63's own bug shape ("only reassign a field when the caller's argument
   is non-null") elsewhere in the same file.

Three small files with zero prior audit-doc mentions
(`ad_log_level.dart`, 13 lines; `ad_sdk_state_snapshot.dart`, 53 lines;
`ad_placement.dart`, 54 lines) were read directly rather than forked —
an enum, an opaque string wrapper, and an immutable value class with
consistent `==`/`hashCode`/`toString` over the same field set. No bug
surface in any of the three.

## Findings

**1 real, MAJOR.** Found and fixed same-day, never shipped.

### `ConsentManager._load()` racing an in-flight persist reverts a just-set consent value

`bootstrap()` calls `_load()` on every call, including a reinit-without-
`destroy()` on the same singleton — a scenario this file's own doc
comments already document as supported. `_load()` read
`_prefs.getConsentSettingsRaw()` immediately, with no regard for a
`set()`/`reset()` call already in flight on that same instance. The
persist path has a real async gap (the round-39 `_persistLock` exists
specifically because of it) — a `_load()` call landing inside that gap
reads the **pre-write** value and overwrites `_current`/
`_settingsListenable` with it. The in-flight `set()`/`reset()` call's own
epoch guard doesn't catch this: it only detects a *newer* `set()`/`reset()`
call superseding it, not an unrelated `_load()` reading in from outside
that machinery entirely.

Verified empirically: `set(hasUserConsent: true)` called, its persist
artificially delayed (`debugPersistDelay`); a `bootstrap()` reinit on the
same singleton fired mid-delay; disk read back the old `false` and
clobbered `_current`. When the original `set()`'s persist completed, its
epoch still matched (nothing newer had legitimately superseded it), so
it re-applied — but by then `_current` had already been stomped, so it
applied the stale, wrong value. Net effect: disk ends up correct
(`true`), but the in-memory `current` **and** the value actually sent to
AppLovin/AdMob (`setHasUserConsent`) both stay wrong (`false`) for the
rest of the running session — a real compliance-relevant regression
(a user who granted consent has it silently treated as denied), not
merely a display glitch.

**Fix:** `_load()` now `await`s the existing `_persistLock` (introduced
round 39 for a different race) before reading disk — no new mechanism,
reuses the file's own established serialization point, guaranteeing a
read always happens after any in-flight write has landed. New regression
test `test/consent_manager_reload_race_test.dart` (RED before fix,
GREEN after).

### Checked and ruled out (not bugs)

- Searched the rest of the file for siblings of round 63's exact bug
  shape ("only reassign a field when the caller's argument is
  non-null") — the journal field round 63 fixed is the only field with
  that shape; no other field in `consent_manager.dart` has it.
- `_current`/`_settingsListenable` write ordering between two
  overlapping `set()`/`reset()` calls (no `_load()` involved) — the
  synchronous-prefix assignment before each method's first `await`
  correctly makes the later call always win; matches the round-38
  design, no drift.
- `recordFallback()`/`clearFallback()` deliberately don't go through
  `_recordProvenance` or bump the epoch — they only record metadata
  about a fallback path, never change actual consent state, so no
  re-apply is needed. Correct as-is.
- No raw `DateTime.now()` reads anywhere in the file — nothing to clamp
  against clock rollback.
- The boundary with `ump_consent.dart`/`iab_storage.dart` (both audited
  clean round 66): `consent_manager.dart` only reads/writes through
  `AdPreferences`, never touches either file directly — nothing further
  to check on that side.

## Test status

Full `packages/ad_sdk` suite: **2205/2205 passing** (2204 baseline + 1
new regression test). `flutter analyze`: 0 issues. Also re-ran
`consent_manager_test.dart` + `consent_manager_persist_race_test.dart` +
`consent_manager_provenance_test.dart` (round 39/63's own regression
suites) in isolation — 22/22 passing, no regression to either prior fix.

## Publish-gate status

Round 67 found & fixed 1 real MAJOR — not clean. Round 66 was clean;
round 67 breaks that streak. The two-consecutive-clean-rounds bar
remains unmet. Rounds 57-67: 9 real MAJOR + 2 MINOR found and fixed
same-day across 11 rounds, with rounds 64 and 66 each independently
clean — the finding rate is dropping (2 clean rounds out of the last 4)
but has not yet reached zero.

## Recommendation

No blockers — round 67's finding never shipped. This closes the last
named gap in `lib/src/`: every file with meaningful logic has now had
either a dedicated full-pass audit this session, or (for the 3 trivial
files checked directly this round) a direct read confirming there's no
bug surface to find. Round 68, if it happens, would need to either
re-pass an already-"clean" area adversarially again (diminishing
returns) or accept that continued full-file sweeps have run out of new
ground — flagging back to human for the publish decision.
