# Audit round 52 — consolidated verdict

**Date:** 2026-09-20
**Codebase audited:** `main` HEAD `c51fe5c` (round 51's fixes on top of
unreleased round-49 fixes; published pub.dev **3.0.1**; `pubspec.yaml`
still `3.0.1`, CHANGELOG has `[Unreleased]` section).

## Method

Same three-way split as rounds 50-51, scoped to files not yet independently
audited this cycle:

1. **`codex exec` (external CLI)** — `lib/src/widget/` (all 8 files),
   `lib/src/utils/` (all 6 files), and 8 misc `lib/src/core/` files
   (`ad_bootstrap`, `ad_crash_guard`, `ad_provider_adapter`,
   `ad_route_observer`, `att_consent`, `event_bus`,
   `integration_self_check`, `ump_consent`).
2. **In-session Claude fork, slice E** — `lib/src/config/` (5 files),
   `lib/src/consent/` (5 files), `lib/src/state/` (6 files).
3. **In-session Claude fork, slice F** — `lib/src/vip/`'s remaining
   files (signed_vip_key, vip_dialog, vip_redeem_screen,
   vip_revocation_provider, `_redeemed_key_ledger`, `_vip_entries_store`,
   vip_entry) plus `lib/src/adapters/`'s support files
   (`_inline_visibility`, `inline_ad_instance_registry`,
   `applovin_bridge`, `applovin_ad_revenue`, `fake_adapter`).

## Findings — codex found 3 new real findings; both in-session forks (slices E, F) came back "no new findings"

Same pattern as round 51: `codex` caught real bugs in areas two independent
in-session forks had just read closely (config/consent/state; VIP+adapter
support) and cleared. All 3 verified by direct source read, and one
(ad_crash_guard.dart) required a follow-up fix to a regression the first
attempt introduced — see below.

### 1. MAJOR — `requestAttIfNeeded()` leaks the fullscreen-ad mutex on a synchronous throw from the ATT plugin call

`lib/src/core/att_consent.dart:249`. The guard acquired via
`markUmpFormOnScreen()` was only released via `.whenComplete()` chained onto
`requestAuthorization()`'s **returned Future** — if the call itself threw
synchronously (missing plugin registration, a platform quirk) before ever
returning a Future, control jumped straight to the outer `catch`, which
degrades to `AttStatus.denied` but never calls `releaseAttForm()`. This is
the exact same bug class `ump_consent.dart`'s `requestPrivacyOptionsFlow()`
was already fixed for (round-8 QC, with an explicit code comment
documenting it) — just never applied to the ATT path, which was added
later (round 31).

**Fix:** wrapped the `requestAuthorization()` call itself in `try`/`catch`,
calling `releaseAttForm()` before rethrowing to the outer catch. **Verification:**
added a test forcing a synchronous `throw StateError(...)` from the
override, confirming `umpFormOnScreen.value` returns to `false` and the
result still degrades to `denied`. Confirmed red without the fix (mutex
stayed `true`), green with it.

### 2. MAJOR — `installAdCrashGuard()`'s all-or-nothing reinstall check corrupts the saved "previous" handler when only one of two global handlers was externally replaced

`lib/src/core/ad_crash_guard.dart:87`. The early-return check required
**both** `FlutterError.onError` and `PlatformDispatcher.onError` to still
be this guard's own installed wrapper to skip reinstalling. If a host
replaced only `FlutterError.onError` since the last install (leaving
`PlatformDispatcher.onError` as this guard's own untouched wrapper from
the prior install), the combined check failed and the code reinstalled
**both** — re-capturing the still-installed platform wrapper as "the
previous handler," permanently burying the real original host handler
underneath a second layer. A later `uninstallAdCrashGuard()` then restored
the guard's own stale wrapper instead of the true original, so a
platform-error handler kept intercepting calls forever after `destroy()`.

**Fix:** each handler is now checked and (re)installed independently
(`if (!identical(current, installed)) { ...(re)install... }` per handler,
rather than one combined `&&` gate). **Regression caught during the fix
itself:** the first version of this fix broke an existing test — a fresh
process/test isolate has `_installedOnPlatformError == null` AND
`PlatformDispatcher.instance.onError == null` (nothing installed yet), and
`identical(null, null)` is `true`, so the naive per-handler
`!identical(current, installed)` check wrongly treated "never installed"
as "already installed and matching," silently skipping the very first
install. Added an explicit `_installed... == null ||` guard to force
installation whenever nothing has been installed yet. Caught by running
the full existing `ad_crash_guard_test.dart` suite immediately after the
first fix attempt — a concrete instance of this repo's own standing lesson
to verify every fix against the full test suite, not just the new test.
**Verification:** added a test that installs with a host `PlatformDispatcher`
handler already in place, replaces only `FlutterError.onError`, reinstalls,
and confirms the platform wrapper is untouched and `uninstallAdCrashGuard()`
correctly restores the original host platform handler (not a stale SDK
wrapper). Confirmed red without the null-safe fix, green with it; full
`ad_crash_guard_test.dart` + `ad_crash_guard_owner_test.dart` suites still
pass.

### 3. MINOR — `AdBootstrapResult.toString()` printed the raw device GAID

`lib/src/core/ad_bootstrap.dart:76`. Unlike `AttResult.toString()` (which
deliberately prints `hasIdfa: bool`, never the raw IDFA), `AdBootstrapResult`
interpolated the raw `gaid` string directly. `bootstrap()`'s result is a
public return value a host may log, print, or hand to a crash reporter
directly — entirely outside this SDK's own `SafeLogger` redaction path
(`sensitive_data_redactor.dart`'s regex only helps for messages that
actually go through `SafeLogger`).

**Fix:** changed to `hasGaid: bool` (`gaid.isNotEmpty`), matching
`AttResult`'s existing convention exactly. **Verification:** added a test
constructing a result with a real-looking GAID and asserting the raw value
never appears in `toString()`.

## What did NOT hold up / known gaps (carried forward, unchanged)

- GPP US-state bit-offset parsers (`iab_storage.dart:427-495`) still
  unverified against an IAB reference encoder.
- `ConsentProvenanceJournal`'s local-only hash chain still cannot detect
  truncation/forgery by whoever controls the device's own storage (round 51
  — now honestly documented, not fixable without a server-side anchor).

## Test status

Full `packages/ad_sdk` suite: **2181/2181 passing** (3 new regression
tests: 1 for the ATT synchronous-throw fix, 1 for the crash-guard
asymmetric-replacement fix, 1 for the GAID-redaction fix). `flutter
analyze`: 0 issues.

## Publish-gate status

Round 51 found 4 real findings; round 52 found 3 more (2 MAJOR, 1 MINOR) —
in files two independent in-session forks had just cleared. This is now
three rounds in a row (50 clean, 51 dirty, 52 dirty) where external tooling
(`codex`) found real bugs that in-session review missed on adjacent files.
The two-consecutive-clean-rounds bar remains unmet.

## Recommendation

No blockers left open — both MAJORs and the MINOR are fixed, tested, and
ready to merge. Given codex has now found real, fixable bugs in 2 of the
last 3 rounds (51, 52) despite this codebase already having been through
49+ prior rounds, there is a real, non-hypothetical argument for continuing
past just one more round before treating "clean" as achieved — but that is
a product/scheduling call, not a code correctness one. All fixes in this
round are independently sound regardless of what round 53 finds elsewhere.
