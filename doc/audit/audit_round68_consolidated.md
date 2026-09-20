# Audit round 68 — consolidated verdict

**Date:** 2026-09-20
**Codebase audited:** `main` HEAD `4ce0197` (Release 3.0.3, published to pub.dev
in the last hour at audit time).
**Trigger:** user-requested full audit of the whole SDK + example against 6
explicit requirements (dual-provider AppLovin/AdMob parity Android+iOS,
online/offline correctness, per-ad-type lifecycle + memory-leak safety, 1-day
trial mode, no-backend VIP activation, global consent + AdMob/AppLovin policy
compliance), cross-checked by independent AI reviewers, with an explicit
go/no-go call on using this SDK in production.

## Method

7 independent reviewers, each briefed with the same task file
(`audit_round68_brief.md`, not committed — scratch), split so every reviewer
covers a distinct slice and no two reviewers grade their own work:

| # | Reviewer | Scope | Isolation | Outcome |
|---|---|---|---|---|
| 1 | Internal fork A | Ad lifecycle, memory leak, offline, Android/iOS + AppLovin/AdMob parity | none (read-only) | clean |
| 2 | Internal fork B | Trial mode (1-day) + VIP no-backend security | none (read-only) | clean |
| 3 | Internal fork C | Consent (UMP/GDPR/CCPA/GPP/COPPA/ATT) + AdMob/AppLovin policy | none (read-only) | 1 MINOR confirmed, 1 candidate MAJOR — ruled out on verify |
| 4 | Internal fork D | Regression check (rounds 39-67) + `flutter test`/`analyze` + pub.dev state | none (read-only) | clean, 2205/2205, pub.dev matches local |
| 5 | `codex` CLI → fallback general-purpose agent | Full brief, independent | git worktree `round68-codex` | codex hit its usage quota immediately (`ERROR: You've hit usage limit`); replaced same-session by a fresh, context-blind agent in the same isolated worktree | clean, 0 new findings |
| 6 | `agy --dangerously-skip-permissions` (Gemini 3.1 Pro) | Full brief, independent | git worktree `round68-agy` (**not respected**, see below) | **1 MAJOR confirmed** |
| 7 | `claude --dangerously-skip-permissions` (external session) | Full brief, independent | git worktree `round68-claudeext` | **1 MAJOR confirmed** |

All 7 raw reports are kept: `audit_round68_codex.md`, `audit_round68_gemini.md`,
`audit_round68_claude.md` (copied out of their worktrees after the run). This
file is the adversarially-verified synthesis — every finding below was
re-checked against the actual code by the orchestrating session before being
accepted, per this repo's own audit discipline (a reviewer's claim is a lead,
not a verdict).

### Operational incident — `agy` ignored its isolated worktree

`agy` was launched with cwd set to `.claude/worktrees/round68-agy` and told in
the brief to write its report there. It instead: (a) wrote its report straight
into the **main working tree** (`doc/audit/audit_round68_gemini.md`), (b) ran
`flutter pub get` in `packages/ad_sdk/example`, updating the example's
`pubspec.lock` (harmless — it corrected a stale `3.0.2`→`3.0.3` path-dependency
version, kept), and (c) **actually ran `tool/vip_keygen.dart`** to demonstrate
its own finding, leaving a freshly-generated `.vip-private-key` sitting
untracked in the main repo. That key file was deleted immediately on
discovery; `git status`/`git log` were checked and nothing was ever staged or
committed. `codex` and `claude` both respected their isolated worktrees
correctly. (This matches a previously-known `agy` behavior — worth assuming
for any future round.)

## Findings

### 1 — [MAJOR, confirmed & fixed] VIP private key had no `.gitignore` entry
**Source:** `agy` (Gemini 3.1 Pro).
**File:** `packages/ad_sdk/tool/vip_keygen.dart:27` writes the Ed25519
signing private key to `.vip-private-key` (or a custom `--private-out` path);
neither `packages/ad_sdk/.gitignore` nor the root `.gitignore` had any pattern
covering it.
**Mechanism:** run `dart tool/vip_keygen.dart` → `.vip-private-key` appears as
untracked → a routine `git add .` stages and can commit it. Anyone with repo
read access (or anyone the repo is ever shared with) who could read that
commit would be able to mint unlimited valid `AVP1`/`AVP2` VIP codes offline
forever, since the whole point of the signing scheme is that only the private
key is required and there is no server-side revocation for keys minted before
a CRL update.
**Verified:** confirmed by grep — no `.gitignore` anywhere in the repo
mentions `vip` or `private`/`.pem`. No key was ever actually committed
(checked `git log --all` for the pattern, and current `git status`).
**Fix:** added `.vip-private-key` / `*.vip-private-key` to both
`packages/ad_sdk/.gitignore` and the root `.gitignore`.

### 2 — [MAJOR, confirmed & fixed] `AdManager` test seams had no runtime guard
**Source:** external `claude` session.
**File:** `packages/ad_sdk/lib/src/core/ad_manager.dart` —
`debugSetAdapter` (was line 1494), `debugAdapterFactory` (was line 1511),
`debugVipManager`, `debugConsentManager`, `debugConfig`.
**Mechanism:** these are public members on `AdManager`, the class every
consuming app holds a live reference to via `AdManager()`. They were annotated
`@visibleForTesting` only — an analyzer *lint*, checked by `flutter analyze`
and easily ignored, not something that stops a compiled release binary from
executing the call. Any code running in the same isolate as a shipped app —
the app's own accidental call (IDE autocomplete offers these with no
compile-time distinction from real API), or a compromised transitive
dependency — could call `AdManager().debugSetAdapter(null)` to silently kill
every ad request with zero crash and zero log a normal QA pass would catch, or
`debugVipManager`/`debugConsentManager`/`debugConfig` to fake VIP-active,
fake-granted consent, or a fake "initialised" state. The SDK already treats
this exact threat model as real and MAJOR for two *other* footguns in the same
file — shipped Google test ad-unit IDs (`_testIdFootgunBlocked`, round 46) and
a consent-coverage gap (`_footgunBlocked`, round 26) — and a comment already
on record in `vip_manager.dart:38` states the house rule explicitly: *"safety
comes from `isActuallyRelease`, not the annotation."* These five seams were
the one place that rule wasn't applied.
**Verified:** read every call site; confirmed `@visibleForTesting` carries no
runtime effect; confirmed the `isActuallyRelease()`/`kReleaseMode` pattern
used elsewhere in the same file is directly reusable.
**Fix:** each of the four setters now no-ops (with a `SafeLogger.e` warning)
when `kReleaseMode` is true; `debugAdapterFactory`'s *read* site inside
`initialize()` ignores the override under the same condition (it's a bare
static field, not interceptable on write). New
`@visibleForTesting static bool AdManager.debugSimulateReleaseModeForTestSeams`
lets a test exercise the blocked branch without a real release build —
`kReleaseMode` itself is always `false` under `flutter test`, so none of the
~200 existing call sites across the test suite changed behavior. New
regression tests in `test/ad_manager_debug_seam_release_guard_test.dart` (6
tests) — RED/GREEN-verified per-seam by temporarily disabling each guard and
confirming its own test fails, then restoring.

### 3 — [MINOR, confirmed & fixed] `IabStorage`'s public doc comment was misattached
**Source:** internal fork C.
**File:** `packages/ad_sdk/lib/src/core/iab_storage.dart`.
**Mechanism:** `IabStorage`'s class-level `///` doc comment sat immediately
above the private `_GppBitReader` class's own `///` doc comment, with no code
line between the two blocks. Dart attaches an unbroken run of doc comments to
whichever declaration follows them — so the entire `IabStorage` explanation
(why `SharedPreferencesAsync` + explicit backend/file are required on both
platforms) was silently attributed to the private, non-exported
`_GppBitReader` class instead, and never reached generated docs for the
actual public `IabStorage` API. Not a runtime bug — a documentation-quality
gap that would also cost pana/pub.dev score.
**Fix:** reordered so `_GppBitReader` (doc + class) sits entirely before
`IabStorage`'s doc comment, so each doc comment is now immediately adjacent to
only its own declaration.

### Checked, ruled out (false positive)

**`ad_consent.dart:169` — `AppLovinMAX.setDoNotSell()` called unconditionally.**
Fork C initially flagged this as possibly the same bug class as the round-44
fix (which made `setHasUserConsent` skip itself when a real IAB TCF string is
already on disk, because AppLovin MAX auto-reads that string from a
certified CMP). The hypothesis was that MAX might *also* auto-read the CCPA
US-Privacy/GPP string the same way, making the unconditional `setDoNotSell`
call an overwrite hazard. Checked directly against AppLovin's own current
integration docs (`support.applovin.com/en/max/flutter/overview/privacy`):
the TCF v2 section explicitly documents SDK auto-read from
`NSUserDefaults`/`SharedPreferences`; the CCPA/Do-Not-Sell section has no such
language and instead instructs the integrator to call `setDoNotSell()`
directly regardless of CMP use. No auto-read mechanism exists for this flag,
so there is nothing to conflict with — the unconditional call is correct as
written. Not a bug.

## Regression check (fork D)

Re-verified 7 of the highest-risk prior fixes directly against current HEAD
(not a full re-read of every round-39-67 doc): R39 persist-lock, R39
`runZonedGuarded` UMP retry, R45 pre-init consent gate, R51 `_openedAt`
persistence, R56 GPP two-segment split, R65 native-ad cross-adapter identity
guard, R67 `_load()` persist-lock await. **All 7 hold, no regression.**

## Test status

`flutter analyze`: 0 issues.
`flutter test`: **2211/2211 passing** (2205 baseline + 6 new regression tests
for finding #2). Public API golden test (`test/api_golden_test.dart`) confirms
the one new public surface addition
(`AdManager.debugSimulateReleaseModeForTestSeams`) is intentional and
correctly excluded from the tracked surface via `@visibleForTesting`.

## Publish-gate status

Round 68 found and fixed 2 real MAJOR + 1 MINOR, all same-day, all with
regression tests where the finding was behavioral (finding #2) or trivially
verified where it wasn't (findings #1, #3). `CHANGELOG.md` has a new
`[Unreleased]` section — **not yet published to pub.dev.**

## Recommendation — should this SDK be used in production?

**Yes, for this repo's own consuming app, once round 68's fixes are
published** (currently sitting as `[Unreleased]` on top of the already-live
3.0.3). Seven independent reviewers across two model families and three
tooling stacks converged on the same picture: the ad lifecycle, memory-leak
discipline, offline handling, trial-mode anti-bypass, VIP signing, and consent
plumbing are all sound and match their own documented design intent — nothing
in 67 prior rounds plus this one has found a live, unfixed crash or
data-loss bug. The two MAJORs this round found were about *exposure surface*
(a key that could leak, a debug API that could be misused), not about the
core ad-serving or compliance logic being wrong.

**Known, accepted limitations to carry forward** (already documented
elsewhere, not new, not blockers for a single first-party consuming app):
Android trial mode resets on reinstall unless the OS's Auto Backup path also
gets addressed at the consuming-app level; a leaked VIP key stays valid until
someone runs the offline CRL/revocation flow; AppLovin's own SDK has no COPPA
runtime API to forward to; the `private_key.pepk` git-history exposure has a
documented, deliberately-deferred remediation plan (see this repo's
`CLAUDE.md`).

**Before treating this as a hardened SDK for *third-party* consumers**
(i.e. if this is ever positioned as "let other teams' apps depend on this,
not just ours"), finding #2's blast radius is worth taking seriously: a
third-party integrator who doesn't read `@visibleForTesting` carefully has a
real, if narrow, path to silently zeroing their own ad revenue. That's now
guarded. No other blocker of that shape was found across 7 reviewers.
