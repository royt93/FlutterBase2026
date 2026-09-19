# Audit round 49 — consolidated verdict

**Date:** 2026-09-19
**Codebase audited:** local worktree, HEAD at `5e63d6b` (published pub.dev
**3.0.1**). All fixes below are applied in this worktree, unreleased —
`pubspec.yaml` still says `3.0.1`, CHANGELOG has an `[Unreleased]` section.

## Method

Five independent passes ran in parallel, then every finding was re-verified
against source by hand before being trusted (per this repo's standing
"adversarial, not self-graded" audit rule):

1. **`agy` (external CLI, real subprocess)** — full 7-area sweep. Report:
   `audit_agy_round49.md`.
2. **`claude -p --dangerously-skip-permissions` (external subprocess,
   independent context — no memory of this conversation)** — full 7-area
   sweep, ran 6 of its own sub-agents internally and cross-checked their
   output against source itself before reporting. Report:
   `audit_claude_round49.md`.
3–5. **Three in-session Claude forks**, each scoped to a disjoint slice of
   the brief (dual-provider/offline/lifecycle; trial/VIP; consent/policy),
   briefed on rounds 46–48 to avoid re-reporting known/accepted items.

`codex exec` was attempted but returned "You've hit your usage limit" on
every invocation (same failure as rounds 47–48 — not transient across three
rounds now). `gemini` CLI is no longer usable at all: the account tier was
deprecated server-side ("This client is no longer supported for Gemini Code
Assist for individuals... migrate to the Antigravity suite") — this is not
a retry-able failure like codex's; a future round should stop attempting
`gemini` until/unless this project moves to Antigravity or a different
Gemini access path.

The 3 in-session forks and `agy`'s policy/consent/dual-provider/lifecycle
sections found **nothing new** — every angle they tried was already covered
and fixed by rounds 1–48. `agy` did find one real, independently-verified
tooling bug (R49-01 below). The external **`claude -p`** pass is the one
that found something the other four missed: 3 new MAJORs. Each of its 4
claims was independently re-derived from source by the main session
(reading the exact lines, and in 3 of 4 cases writing a regression test
that fails without the fix and passes with it) before being accepted here
— see "Verification" under each finding.

## Findings — all fixed same round

### M49-01 (MAJOR) — `clearSdkData(allIncludingEntitlements)` let a user re-grant their own trial with no reinstall

**Found by:** external `claude -p` pass.
**File:** `lib/src/core/ad_manager.dart` (`clearSdkData`), erase call removed;
`lib/src/vip/_first_install_guard.dart` (`erase()` doc comment updated).

The SDK's own documented, near-mandatory "erase my data" flow
(`AdManager().clearSdkData(scope: allIncludingEntitlements,
confirmedEntitlementErasure: true)` — required for Apple Store Guideline
5.1.1(v) and GDPR/CCPA erasure rights, and shipped as a demo button in
`example`) also called `FirstInstallGuard().erase()`, wiping the iOS
Keychain flag whose entire documented purpose is to survive exactly this
kind of local-data wipe so a device can't re-grant itself the first-install
24h VIP trial without an actual uninstall+reinstall. A normal user tapping
the SDK-encouraged "delete my data" button and reopening the app got a
fresh 24h trial every time — no reinstall needed, direct revenue-abuse
vector.

This one intersected a prior deliberate decision (T200 wired this call in
on purpose, reasoning "a confirmed entitlement-erasure request is exactly
the case to really wipe this"), so it isn't a plain oversight — but it
isn't in this repo's list of confirmed-with-product-owner accepted
tradeoffs either (`vip-offline-gate-and-qa-hashes-are-features` memory
covers 4 specific items; this isn't one of them, and is strictly worse than
the Android reinstall gap that memory *does* cover, since it needs no
reinstall at all). Brought in line with this same codebase's own existing
precedent: `RedeemedKeyLedger` and `ConsentProvenanceJournal` already carve
themselves out of entitlement erasure for the identical
anti-abuse-data-survives-erasure reasoning. A real, paid VIP grant is still
erased normally — only the anti-farming flag is now excluded.

**Verification:** read `_entitlementKeys`/`clearSdkData` in
`ad_preferences.dart` and the grant-gate in `ad_manager.dart` (~line 3340)
to confirm the Keychain guard is checked independently of the
SharedPreferences flag, so removing only the `erase()` call (not touching
the SharedPreferences side, which was already an intentional T200 choice)
is sufficient and minimal. Added
`test/t200_clear_sdk_data_test.dart`'s new test with a mocked
`FlutterSecureStorage`; confirmed it fails (`hasAlreadyGranted()` false)
without the fix and passes with it.

### M49-02 (MAJOR) — full-screen ad completion callbacks could crash a disposed screen

**Found by:** external `claude -p` pass.
**File:** `lib/src/core/ad_screen.dart` — `showInterstitialAd`,
`showRewardedAd`, `showRewardedInterstitialAd`.

All three methods correctly guarded `mounted`/`_isDisposed` *before*
showing an ad (at entry, and again after the `showAdBuffer` delay) — but
not when the ad actually **finished**. An ad can stay on screen for an
arbitrary amount of time (user backgrounds the app, reads a rewarded
disclosure, takes a phone call mid-ad); if the host navigates away and the
screen disposes while the ad is still up, the native SDK's asynchronous
"ad closed" callback fires later against a widget that's already gone —
calling the host's `onDone`/`onEarnedReward` there risks `setState` after
dispose or "Looking up a deactivated widget's ancestor" crashes. This
directly contradicted the **round 48 fork's own claim** ("every show method
checks `_isDisposed`/`mounted` ... before calling back into user code") —
that check covered every *earlier* point in the flow but missed this one,
a clean example of why this repo insists on independent re-verification
over trusting a prior round's "clean" claim.

**Verification:** read all three call sites directly; confirmed
`onDoneFlow`/`onEarnedReward` had no guard around the final `onDone(...)`
call, and `showRewardedInterstitialAd` passed `onDone` straight through
with no wrapper at all. Added a `_DeferredReadyAdapter` test double to
`test/ad_screen_test.dart` that holds the adapter-level callback instead of
firing it synchronously, so a test can dispose the screen and *then* fire
it — reproducing the exact race. Confirmed both new tests
(`interstitial:`/`rewarded: onDone... never reaches a disposed screen`)
fail with the pre-fix code and pass with the fix.
`showRewardedInterstitialAd` got the identical code fix. It had **no
widget-test coverage in this repo at all** before this round (not even
pre-round-49) — closed the gap same round, per user decision: added a
`rewardedInterstitial` demo button + adapter support to
`test/ad_screen_test.dart` and a third dispose-safety test alongside the
other two. Confirmed red without the fix, green with it, same as the other
two.

### M49-03 (MAJOR) — `resetSessionCounters()` could permanently defeat the click-fraud gate

**Found by:** external `claude -p` pass.
**File:** `lib/src/core/ad_safety_config.dart` — `resetSessionCounters()`.

This method's own doc comment and log line ("Session counters reset (fraud
history preserved)") already promised not to touch fraud-detection state —
it was carved out of the old `resetSession` specifically because *that* one
defeated the progressive-cooldown fraud gate (round 6/M2). But it was still
zeroing `_fullscreenImpressions`/`_fullscreenClicks`/
`_ctrPauseTriggeredAtImpressionCount` — exactly the state
`canShowFullscreenAd`'s CTR-anomaly gate needs 5 cumulative impressions
before it evaluates a ratio at all (`ad_safety_config.dart:722`). A host
calling this reset repeatedly before 5 fullscreen impressions land between
calls — the exact same "wired to a common action" pattern the M2 incident
already warned about — could keep the impression count under 5 forever,
so the CTR gate would never fire no matter how high the real click-through
rate was. This is the account-suspension risk the M2 split was created to
prevent, reintroduced through a different counter in the same method.

**Verification:** read the gate condition directly
(`_fullscreenImpressions >= 5 && ...`). Added a test to
`test/ad_safety_reset_scope_test.dart`: 4 fullscreen impressions+clicks,
`resetSessionCounters()`, 1 more impression+2 clicks (cumulative 5
impressions / 6 clicks = 120% CTR), then `canShowFullscreenAd
(minIntervalOverrideMs: 0)` (bypassing the unrelated, legitimate
throttle) must return `'CTR too high'`. Confirmed the test fails
pre-fix (gate never evaluates — only 1 impression visible after the
reset wiped the other 4) and passes post-fix.

### M49-04 (MINOR) — offline mid-flight load failures could trip a false provider-failover/fill-rate signal

**Found by:** external `claude -p` pass.
**Files:** `lib/src/monetization/provider_failover_advisor.dart`,
`lib/src/monetization/fill_rate_monitor.dart`.

Both classes counted any `AdLoadEvent(success:false)` toward their
respective thresholds with no connectivity check. The offline *pre-check*
already emits a distinct `AdSkipEvent` instead (correctly excluded), but a
load that **starts** while connected and then loses the network mid-flight
(e.g. during a network flap, or a reconnect-debounce-triggered refill) still
surfaces as an ordinary `AdLoadEvent(success:false)` — indistinguishable
from a genuine provider-quality failure. A flappy connection could run
enough of these to trip `ProviderFailoverAdvisor`'s consecutive-failure
threshold or drag down `FillRateMonitor`'s trailing rate, both opt-in
features. Lower severity than M49-01–03: both self-heal (the circuit
breaker's half-open probe, the trailing-window fill rate), no crash, no
data loss, no direct policy risk — but still a real false-positive source.

**Verification:** both now skip counting a failure when
`!AdManager().isConnected`. Added a test to
`test/provider_failover_advisor_test.dart` using the existing
`debugConnectivityChanged` test seam: 5 failures while forced offline must
not build a streak; 3 failures once back online still must. Confirmed red
without the fix, green with it. `fill_rate_monitor_test.dart`'s existing
suite still passes unchanged (no new test added there — identical fix,
lower marginal value given M49-04 is already MINOR and the mechanism is
byte-for-byte the same as the tested one).

### R49-01 (MINOR, tooling) — `dart run` corrupts VIP CLI stdout on Dart 3.10+

**Found by:** `agy`.
**Files:** `tool/vip_mint.dart`, `tool/vip_crl_mint.dart`,
`tool/vip_keygen.dart`, `test/vip_cli_security_test.dart`, `README.md`,
`example/lib/main.dart`.

On a Dart 3.10+ toolchain (confirmed: local Dart 3.11.5; CI's pinned
Flutter 3.35.1 uses an older Dart and doesn't hit this), `dart run
tool/vip_mint.dart` prints `Running build hooks...` to **stdout** before
the script's own output runs — reproduced directly:
`dart run tool/vip_keygen.dart` → first line is
`Running build hooks...Running build hooks...Ed25519 VIP signing key
pair...`. This silently corrupts any real-world `KEY=$(dart run
tool/vip_mint.dart ...)` capture into an unredeemable string (exit code 0,
no error — a minted key or CRL that just won't verify), and was actively
failing 4 of `vip_cli_security_test.dart`'s 6 tests locally before the fix.

**Verification:** reproduced the corrupted output directly via `dart run`,
confirmed bare `dart tool/vip_keygen.dart` (no `run` subcommand) has clean
stdout, confirmed the previously-4-failing tests pass after switching
`_runDart`'s subprocess invocation and all doc examples to the bare form.
`agy`'s own suggested remedy (`dart run --no-build-hooks`) does not exist
as a real flag in this Dart version — verified by running `dart run
--help`; the bare-invocation fix was independently derived and confirmed
working instead.

## What did NOT hold up / known gaps

- `agy`'s NIT (doc wording suggesting 3 different remedies) is superseded
  by the actual fix above — moot.
- GPP US-state bit-offset parsers (`iab_storage.dart:427-495`) remain
  unverified against the IAB reference encoder — same gap noted in round 43,
  still out of scope for a source-reading pass.
- A narrow, unconfirmed edge case flagged by one fork: if a host calls
  `setConsent(isAgeRestrictedUser: true)` *after* init without also setting
  `AdConfig.umpTagForUnderAgeOfConsent`, and then somehow re-triggers a UMP
  form request post-init, the round-31 mismatch warning (which only fires
  once, at init) wouldn't catch it. Not verified as reachable through any
  actual public re-request path; not fixed this round — flag for round 50
  if it recurs.

## Test status

Full `packages/ad_sdk` suite: **2172/2172 passing** (7 new regression
tests added this round: M49-01 ×1, M49-02 ×3 including the newly-built
`rewardedInterstitial` coverage, M49-03 ×1, M49-04 ×1, plus one corrected
stale comment in an existing test). `flutter analyze`: 0 issues. `example/integration_test/` (on-device suite) was **not** run this
round — needs an emulator/simulator per `CLAUDE.md`, out of scope for a
source-reading audit pass.

## Scores

**Production-readiness (can this be published/used by other developers):
8/10.** Packaging, docs (README/CHANGELOG/example), and API stability are
solid and battle-tested across 49 audit rounds; pana/pub.dev score is
capped ~10 points below max by a documented, unavoidable Flutter/Dart
floor mismatch (see root `CLAUDE.md`), not a defect in this package. The
`dart run` tooling bug (now fixed) shows the CLI tools hadn't been
exercised on a current Dart SDK before this round — worth a CI check on a
newer Dart version alongside the pinned one, not just the pinned one alone.

**Safety (safe to use in a production ad-monetized app): 7.5/10 as of this
report, before today's fixes were verified in a real device run.** All 4
new MAJOR/MINORs this round were reachable through the SDK's own public,
documented, encouraged API surface (a legally-required data-erasure
button, a common navigation pattern, a debug/reset action, a routine
network flap) — not theoretical or requiring malicious intent — which is
why they scored as high as they did despite this being round 49 on
already-hardened code. All four are now fixed and test-covered
(unit/widget level); none were previously known/accepted tradeoffs. No
BLOCKER, no crash-on-startup, no unbounded memory leak, no policy
violation found live in production paths.

## Recommendation

**Yes, usable in production**, with the same caveat every recent round has
carried: verify this round's fixes on a real device before the next
release (the trial-regrant and disposed-screen-crash fixes in particular
are exactly the kind of thing that reads correctly in a unit test but
deserves a real tap-through — delete-my-data → reopen → confirm no fresh
trial; show an interstitial → navigate away mid-ad → confirm no crash).
Recommend bumping to **3.0.2** and publishing once that device pass is
done; CHANGELOG's `[Unreleased]` section is ready.
