# Audit round 54 — consolidated verdict

**Date:** 2026-09-20
**Codebase audited:** `main` HEAD `daa5d80` (round 53's regression test on
top of unreleased round-49 fixes; published pub.dev **3.0.1**;
`pubspec.yaml` still `3.0.1`, CHANGELOG has `[Unreleased]` section).

## Method

Different approach from rounds 50-53 (fresh files): a **meta-audit** —
re-examining the round 49/51/52 fixes themselves for bad interactions with
each other or with code that wasn't re-read since, the exact failure class
round 46 already demonstrated (round 44 + round 45's fixes sharing one
state variable produced a new bug). Plus one genuinely-unaudited area:

1. **`codex exec` (external CLI)** — diffed `5e63d6b..HEAD` (every round
   45-53 change) and specifically hunted for new fields/state one fix
   introduced that other, unrelated code might read incorrectly.
2. **In-session Claude fork, slice I** — `packages/ad_sdk/example/lib/`
   (the reference demo app), never audited as its own scope in rounds
   50-53, only touched per-fix when a fix needed a new demo button.
3. **In-session Claude fork, slice J** — the same meta-audit angle as
   codex, working independently through the same diff and the same list
   of new fields, from a different starting point.

Per the user's explicit request this round, every finding below that
required a production change also got a widget-level test and, where
meaningfully exercisable, an integration test — not just a unit test.

## Findings — 2 real (both MINOR), verified and fixed

### Slice J came back clean; codex and slice I each found one real issue independently

**Slice J**: worked through the same 7-point checklist as codex (test-ID
footgun flag, `_openedAt` persistence, consent-provenance-journal cloning,
`BypassAuditTrail.clear()`'s new catchError, the three offline-guard
siblings, `att_consent.dart`'s try/catch interacting with the T161
duplicate-call guard, `ad_crash_guard.dart`'s per-handler install
interacting with `AdManager`'s own `_ownsCrashGuard` flag) — no new bad
interaction found on any of them.

### 1. MINOR — `clearSdkData()` didn't reset a live `ProviderFailoverAdvisor`'s in-memory state

**Found by:** `codex`.
**Files:** `lib/src/monetization/provider_failover_advisor.dart` (new
`resetInMemoryState()`), `lib/src/core/ad_manager.dart` (`clearSdkData`).

`ProviderFailoverAdvisor`'s persisted keys (`_consecutiveFailures`,
`_lastProviderTag`, and round 51's new `_openedAt`) are not entitlement
keys, so `AdPreferences.clearSdkData()`'s generic `ad_sdk_`-prefix sweep
already erases them at **either** scope, including the default one. But if
a host has a live advisor enabled (`AdManager().enableProviderFailoverAdvisor`),
that instance's own RAM copy of the same three fields survived untouched —
its next `AdEvent` write-chain would silently re-persist the pre-erasure
values right back, undoing the erasure a user just requested. Same
"reset the live instance too" gap `clearSdkData()` already explicitly
handles for `VipManager`/`ConsentProvenanceJournal`, just not extended to
this later-added subsystem.

**Fix:** added `ProviderFailoverAdvisor.resetInMemoryState()` (clears all
4 in-memory fields, touches no persistence), called from `clearSdkData()`
via `_providerFailoverAdvisor?.resetInMemoryState()` right after the
generic sweep. **Verification (full pyramid, per this round's explicit
instruction):**
- Unit: `test/provider_failover_advisor_test.dart` — `resetInMemoryState()`
  clears a tripped circuit and the streak count directly.
- Unit/integration-style: `test/t200_clear_sdk_data_test.dart` — a live,
  tripped advisor's `shouldFailoverNextSession` goes `false` after
  `clearSdkData()`, and a subsequent success/failure event doesn't
  resurrect it.
- Widget: `example/test/clear_sdk_data_demo_page_test.dart` — tapping the
  actual "Clear SDK data (safe)" button a host app would tap resets a live,
  tripped advisor. (Needed wrapping the advisor setup in `tester.runAsync()`
  — `advisor.ready` resolves through a real `SharedPreferences` plugin-
  channel gap that fake-async's synchronous pump loop can't service; first
  attempt hung for this exact reason, matching this repo's own documented
  `testWidgets` fake-async pitfall.)
- On-device integration: `example/integration_test/t200_clear_sdk_data_test.dart`
  — same scenario against real `SharedPreferences` on a physical
  device/simulator (not run this round — needs an emulator, source-level
  addition only, per this repo's standing convention for audit rounds).

Confirmed red without the fix (all 3 runnable tiers), green with it.

### 2. MINOR — `NativeDemoPage._simulateWatchdogTimeout()` missing a `mounted` guard (example app only)

**Found by:** in-session fork, slice I.
**File:** `example/lib/main.dart`.

Every other async handler in `_NativeDemoPageState` (6+ methods) guards
with `if (!mounted) return;` immediately after its `await`, before calling
`setState()`. This one method — added later, apparently missed the
pattern — didn't: navigating away from the page while
`await adapter.preloadNative(_demoKey)` was still in flight would call
`setState()` on an already-disposed widget, throwing a `FlutterError`.
This is example/demo code only, not the SDK itself, but real host apps
copy this demo's patterns directly.

**Fix:** added the missing `if (!mounted) return;` in the same place every
sibling handler has it. **Verification:** this is a pure widget-lifecycle
guard with no non-UI logic to unit test, and (unlike finding 1) this demo
page's widget-test tier deliberately never sets up a live/fake adapter for
any test in this file (its own header comment: the pre-init fallback path
is all this tier covers; full real-adapter proof lives in the SDK
package's own `admob_widget_load_watchdog_test.dart` /
`native_ad_widget_test.dart`) — reproducing the exact disposed-widget
crash here would require adapter-injection test infrastructure no sibling
test in this file uses either. Ran the existing `native_demo_page_test.dart`
suite (still 2/2 passing) to confirm no regression; did not add new test
infrastructure disproportionate to a MINOR demo-only fix.

## What did NOT hold up / known gaps (carried forward, unchanged)

- GPP US-state bit-offset parsers (`iab_storage.dart:427-495`) still
  unverified against an IAB reference encoder.
- `ConsentProvenanceJournal`'s local-only hash chain still cannot detect
  truncation/forgery by whoever controls the device's own storage.

## Test status

Full `packages/ad_sdk` suite: **2184/2184 passing** (2 new: 1
`resetInMemoryState` unit test, 1 `t200_clear_sdk_data_test.dart` case).
Full `example` widget-test suite: **67/67 passing** (2 new: 1
`clear_sdk_data_demo_page_test.dart` case, plus the existing
`native_demo_page_test.dart` suite re-confirmed passing after the
mounted-guard fix). `flutter analyze`: 0 issues in both packages.
`test/goldens/public_api_surface.txt` regenerated for
`ProviderFailoverAdvisor.resetInMemoryState`.

## Publish-gate status

Round 54 found 2 real MINORs (fixed same round) — round 53 was clean, so
this breaks a potential streak rather than extending one. The
two-consecutive-clean-rounds bar remains unmet.

## Recommendation

No blockers. Both findings fixed and tested across every tier that could
meaningfully exercise them (unit, widget, and — for finding 1 — on-device
integration source added, not yet run on a physical device this round).
