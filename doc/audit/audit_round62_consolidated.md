# Audit round 62 — consolidated verdict

**Date:** 2026-09-20
**Codebase audited:** `main` HEAD `c7acf0a` (round 61's fix + doc on top
of round 60's fix; published pub.dev **3.0.2**, `pubspec.yaml` still
`3.0.2`, CHANGELOG has `[Unreleased]` section).

## Method

Two in-session Claude forks. User explicitly deferred `codex`/`agy`
external review this round (opted to proceed with internal forks only,
even though codex's usage-limit retry window from round 57 had since
passed). Scope chosen as the least-recently-touched remaining
directories:

1. **Fork (compliance + utils)** — `lib/src/compliance/
   bypass_audit_trail.dart`, `compliance_report.dart`,
   `compliance_signing.dart`, `incident_recorder.dart`, plus
   `lib/src/utils/async_epoch.dart`, `experiment_bucket.dart`,
   `release_mode.dart`, `sensitive_data_redactor.dart`.
2. **Fork (config + consent)** — `lib/src/config/
   compatibility_matrix.dart`, `feature_flags.dart`,
   `placement_registry.dart`, `remote_ad_safety_provider.dart`, plus
   `lib/src/consent/ccpa_opt_out_strings.dart`, `ccpa_opt_out_toggle.dart`,
   `consent_fallback.dart`.

Both last independently touched by round 52's Fork E, 10 rounds ago.

## Findings

**2 real: 1 MAJOR, 1 MINOR.** Both fixed same-day (commit `47abc9c`),
never shipped.

### `applySignedFeatureFlags()`'s rollback guard was in-memory-only — stale payloads could replay after every restart

`AdManager._featureFlagsRevision` (backing `SignedFeatureFlags.verify(
previousRevision: ...)`) was a plain in-memory field, reset to `null` on
every app restart. A stale-but-still-validly-signed, still-unexpired
feature-flags payload could therefore be replayed after any cold start,
re-disabling a feature (`arbitrator`/`waterfallTuner`/`journeyPrefetcher`/
`selfHealingObserver` — this mechanism is disable-only) an app had
already moved past in a previous session. `remote_ad_safety_provider`'s
equivalent revision guard (`_lastAppliedRemoteSafetyRevision`) already
solves this correctly by persisting via
`AdPreferences.getRemoteSafetyRevision()`/`setRemoteSafetyRevision()` and
seeding from it lazily — direct evidence the codebase already knows this
pattern, just hadn't applied it here.

**Severity assessment:** the fork proposed MAJOR; this is a defensible
call given it's a genuine security/compliance-relevant gap (an app-level
kill-switch that can be silently undone by payload replay), even though
the blast radius is availability/degradation rather than an entitlement
or money-related bypass like the VIP mechanisms round 60 stress-tested.

**Fix:** added `AdPreferences.getFeatureFlagsRevision()`/
`setFeatureFlagsRevision()`, mirroring the remote-safety pattern exactly.
`applySignedFeatureFlags()` now seeds `previousRevision` from
`_featureFlagsRevision ?? prefs.getFeatureFlagsRevision()` and persists
(`unawaited`) on a successful apply; `_resetGuardState()` (destroy/reinit
path) clears the in-memory field alongside `_lastAppliedRemoteSafetyRevision`
for the same reason (a new session shouldn't inherit an old one's
in-memory value — the persisted fallback re-seeds it anyway). Added a
`debugFeatureFlagsRevision` test seam (mirroring
`debugLastAppliedRemoteSafetyRevision`) so `test/feature_flags_test.dart`
can simulate a restart without a full `destroy()`/`initialize()` cycle.
Confirmed RED by temporarily neutering the persisted fallback (test
failed: `Expected: false, Actual: true`), GREEN after restoring it.

### `redactSensitiveData()` never matched a JSON-quoted key

All 3 patterns in `lib/src/utils/sensitive_data_redactor.dart` required
whitespace/`:`/`=` immediately after the key name. A JSON-quoted key
(`"gaid": "abc-123-def"`) has a `"` there instead — not whitespace/`:`/
`=` — so the match never even started and the value passed through
unredacted. This backs `SafeLogger._emit()`'s defense-in-depth redaction
for every log message (including ones a host wires to Crashlytics/
Sentry via `onLog`), but tracing every current call site found none that
actually logs a JSON-quoted-key string through it today (GAID specifically
already avoids logging its real value since round 49 — `ad_bootstrap.dart`
logs `hasGaid=${gaid.isNotEmpty}`, never the value). **Dormant gap, not
an active leak** — fixed before any future call site (a very natural one:
logging `jsonEncode(someDebugMap)`) silently relies on protection that
wasn't actually there. `test/safe_logger_test.dart`'s existing redaction
test only exercised the handwritten-shape case — same "test doesn't
exercise the real shape" pattern rounds 59/60/61 already found elsewhere,
here in a security-relevant utility rather than a business-logic one.

**Fix:** each pattern's key group now allows an optional `["\x27]?` (a
regex hex-escape for `'`, since the pattern lives in a Dart raw string
that can't contain an unescaped `'` delimiter) before `\s*[:=]`. New
regression test in `test/safe_logger_test.dart` covers a JSON object with
double- and single-quoted keys across all 3 pattern categories (GAID,
test-device, VIP key).

### Rest of scope: no findings, full pass confirmed

`compatibility_matrix.dart`, `placement_registry.dart` (cross-verified
its `minIntervalOverrideMs` negative-rejection doc claim directly against
`ad_safety_config.dart:694-696,819-821`), `remote_ad_safety_provider.dart`
(the reference-correct pattern above), `ccpa_opt_out_strings.dart`,
`ccpa_opt_out_toggle.dart` (dispose/listener-reattach order verified
correct), `consent_fallback.dart` (fail-safe decode verified conservative
by design). `async_epoch.dart` (single call site, already audited rounds
52/57), `experiment_bucket.dart` (a suspected `|`-collision in
`installId` isn't reachable — that value is always a device UUID),
`release_mode.dart` (11 lines, correct OR logic), `compliance_signing.dart`/
`bypass_audit_trail.dart`/`incident_recorder.dart`/`compliance_report.dart`
(each already through many prior rounds — T155, round 23, round 51, T171,
T199 — every bug class attempted this round already has documented
defense in place).

## Test status

Full `packages/ad_sdk` suite: **2200/2200 passing** (2 new regression
tests). `flutter analyze`: 0 issues. Additionally smoke-tested on a real
Samsung S24 Ultra (SM-S928B): launched the example app, opened the
Consent demo screen, tapped "Consent provenance journal (T202)" —
exercises round 57's `_appendLocked` fix on a real device Flutter
runtime, not just `flutter test`'s VM. No crash; dialog showed "1
entries (chain OK)".

## Publish-gate status

Round 62 found & fixed 2 real issues (1 MAJOR, 1 MINOR) — not clean.
Rounds 57 through 62 have each found at least one real issue; the
two-consecutive-clean-rounds bar remains unmet after 62 rounds.

## Recommendation

No blockers — round 62's findings never shipped. Six consecutive rounds
(57-62) each finding genuine, previously-unknown, non-trivial issues,
across an unusually broad range of subsystems (consent, revenue
analytics, monetization tuning, security/compliance), is well outside
this codebase's typical audit-history hit rate at this depth of prior
coverage. This round's compliance/utils slice found nothing further in
the most security-sensitive file it covered (`compliance_signing.dart`),
and both slices' remaining scope came back genuinely clean after a real
adversarial attempt — some convergence is visible. Flagging back to the
human on whether to continue further rounds or ship what's accumulated;
this session will not auto-continue past this point without direction.
