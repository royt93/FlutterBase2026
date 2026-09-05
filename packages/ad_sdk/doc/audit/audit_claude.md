# Audit round 39 — independent review (Claude, primary repo, 2026-09-05, v2.9.18)

**Method:** Read source directly in the real repo (not a nested CLI, not a worktree copy), read-only,
no edits, no commits. Ran in parallel with 3 other independent sources (codex/agy/claude-cli, each in
its own isolated git worktree) — no cross-referencing during analysis.

Scope re-verified against `doc/audit/audit_round38_consolidated.md` and `CHANGELOG.md` `[2.9.18]` first,
so already-fixed round-38 findings (AppLovin `NativeAdWidget` permanent-blank, the main `setConsent()`
epoch race, admob dispose-while-showing, backoff overflow, daily-cap clock-rollback, double-tap dialog
guard, GPP 21/21 state parity) are **confirmed still in place** and not re-reported. Then audited the
same 7 areas fresh: dual-provider parity, offline resilience, per-ad-type lifecycle, 1-day trial, no-backend
VIP crypto, consent for every jurisdiction, and general AdMob/AppLovin policy risk — this time specifically
hunting for the same *shape* of bug round 38 found twice in a row ("the fix landed on one code path but
was never ported to its sibling").

---

## MAJOR-1 (new): `AdManager.setConsent()`'s COPPA re-init branch writes to the native SDK with no epoch guard — sibling of the just-fixed race, in the one branch the round-38 fix never touched

**Files:** `lib/src/core/ad_manager.dart:3949-3982` (COPPA re-init branch), vs. the now-guarded main
tail write at `:4031-4049`.

Round 38 (MAJOR-2, re-audited and re-fixed same day per `CHANGELOG.md`) closed a race where an older,
delayed `setConsent()` call could finish its native-provider write *after* a newer overlapping call's
write had already landed, silently re-applying a stale consent value. The fix: capture
`final consentEpoch = _consentIntentEpoch;` at entry (line 3869), then gate every later
`applyConsentToProviders()` / `_adapter?.applyConsent()` call on `consentEpoch == _consentIntentEpoch`
immediately before issuing it (lines 4031, 4048).

That guard covers the **normal path**. It does not cover the **COPPA child-directed flip branch** a few
lines earlier:

```dart
if (!isAdMobProvider &&
    cfg != null &&
    consent.isAgeRestrictedUser != previousAgeRestricted) {
  ...
  await applyConsentToProviders(consent, config: cfg);   // line 3962 — no epoch check
  ...
  return;                                                 // line 3981 — never reaches the guarded path
}
```

This branch triggers whenever `consent.isAgeRestrictedUser` differs from `_consent.isAgeRestrictedUser`
captured at function entry — and crucially, `_consent = consent` is assigned **synchronously** at line
3889, before any `await`. So two overlapping `setConsent()` calls that both flip the COPPA flag (e.g. a
parental-control toggle switched off then immediately back on, or a host restoring a persisted value
racing a user tap) will **both** independently see a different `previousAgeRestricted` than their own
`consent.isAgeRestrictedUser`, both enter this branch, both call the unguarded
`applyConsentToProviders()`, and both `return` before ever reaching the epoch-guarded code at
4031/4048.

**Concrete failure scenario:** call A = `setConsent(ageRestricted: true, ...)`, call B =
`setConsent(ageRestricted: false, ...)` issued immediately after (both hit AppLovin, `isAdMobProvider ==
false`, `cfg != null`). Both enter the COPPA branch and each calls
`await applyConsentToProviders(...)` with their own consent value. If A's platform-channel round trip
resolves after B's (plausible — B's config value happens to skip AppLovin's `setIsAgeRestrictedUser`-style
work depending on branch), A's stale (chronologically earlier, logically superseded) write lands *last*
on the real AppLovin/AdMob SDK, even though `_consent` and everything the host reads back correctly say
`B`. This is exactly the divergence class round 38's MAJOR-2 fixed — reachable here because the fix was
applied to the general tail write, not to this earlier, separate write site that also talks to the
native SDK and also `return`s before the guarded code runs.

**Why this matters for compliance, not just correctness:** `isAgeRestrictedUser` is the COPPA /
child-directed signal. A stale write landing last here means the native SDK could end up running under
the *wrong* child-directed configuration — the more serious direction being a `false` (adult) config
silently landing over a newer `true` (child-directed) intent, i.e. persisted-serving under a
non-child-safe configuration while the SDK's own reported state says child-directed is active.

**Suggested fix:** capture the epoch already computed at line 3869 and check it before line 3962's write,
same pattern as 4031/4048:
```dart
if (consentEpoch == _consentIntentEpoch) {
  await applyConsentToProviders(consent, config: cfg);
}
```
(The `_updateCanRequestAds(false)` hard-stop just above can stay unconditional — closing the gate early
is always safe; only the native-write call itself needs the guard.) One-line fix, no refactor.

---

## Re-verified clean (not re-reported, checked against real mechanism, not pattern-matched)

- **`lib/src/widget/native_ad_widget.dart:144`** — `disposeNativeInstance` is now called from
  `_onNativeErrorChanged`'s retry timer before `_initNative()`. Round-38 MAJOR-1 fix confirmed present.
- **Consent main path** (`ad_manager.dart:3869/4031/4048`) — epoch capture-then-check-immediately-before-write
  pattern confirmed present and correctly ordered (checked, not just grepped).
- **`lib/src/vip/signed_vip_key.dart` / `vip_manager.dart`** — Ed25519 offline verify + comma-separated
  rotation-key list + cached CRL (revocation) check still intact; no server round trip required to redeem,
  matching the documented no-backend design. Not re-litigated further — this exact mechanism has been
  independently re-verified across many prior rounds (see memory: "VIP offline gate ... is a feature").
- **1-day trial / VIP clock rollback** — `ad_preferences.dart`'s `ad_sdk_vip_max_observed_clock_ms`
  high-water-mark guard is present and distinct from the daily-cap's own HWM key, protecting the trial
  grant from a rolled-back device clock. Consistent with the already-documented "impossible to fully fix
  in pure Dart" residual (a device that has *never* observed a later timestamp can still be started with
  its clock pre-set backward before first launch — an accepted, documented limitation, not new).
- **AdMob adapter dispose-while-showing** — `!slot.isShowing` guard present in all four `load*()` sites
  in `admob_adapter.dart`, confirmed by direct read.

No new findings in: offline/connectivity handling, banner/interstitial/rewarded lifecycle outside the
COPPA-branch race above, or general AdMob/AppLovin policy-risk surface (frequency capping, ad-overlap
guards, test-vs-real-ad gating) — these were read against source and found consistent with prior rounds'
conclusions.

---

## Score: 9.5/10

One new MAJOR (COPPA-branch consent race — narrow trigger condition: requires the isAgeRestrictedUser
flag itself to flip, and requires two overlapping `setConsent()` calls specifically racing on that
branch; not reachable through the far more common single-call or non-COPPA-toggle usage). No BLOCKER.
Everything else re-verified clean against actual mechanism. The fix is a one-line epoch check mirroring
code that already exists three lines away in the same file — low risk, ready to apply.

## Conclusion: YES, production-ready — with the one MAJOR above fixed first

The SDK's core architecture (dual-provider parity, offline resilience, per-ad-type lifecycle discipline,
1-day trial, no-backend VIP crypto, multi-jurisdiction consent) is sound and has now survived 39 audit
rounds with a shrinking, narrower defect surface each time. Ship after patching the COPPA-branch epoch
guard (one line); nothing else here blocks a production release.
