# Round 71 — Claude (main session) audit

**Scope:** `packages/ad_sdk/` + `packages/ad_sdk/example/`, verified against real
code (not doc/audit history, not CHANGELOG) at HEAD `f4383da` (v3.0.10, matches
pub.dev latest). Read-only audit, no code changes.

This is the main coordinating session's own pass, separate from the
independent `audit_codex.md`, `audit_gemini.md`, `audit_claude_cli.md`
running concurrently on an isolated `/tmp` clone via `codex exec`,
`agy -p`, `claude -p`.

## Findings

### BLOCKER — `AdManager.debugApplyConfigVipGaidWhitelist` has no `_testSeamsBlocked` guard

`packages/ad_sdk/lib/src/core/ad_manager.dart:3186-3195`

Every other mutating `debug*` seam on `AdManager` (33 of them, per round 69's
fix) opens with `if (_testSeamsBlocked) return _warnSeamBlocked(...)` before
doing anything — that's the mechanism rounds 68-70 built specifically to stop
a `@visibleForTesting` seam from being callable in a release build (Dart's
`@visibleForTesting` is an analyzer lint only; it does not block a runtime
call from outside the package). This one method was missed:

```dart
@visibleForTesting
Future<void> debugApplyConfigVipGaidWhitelist(
  AdConfig config,
  VipManager vip,
  AdPreferences prefs, {
  required String deviceGaid,
}) {
  _currentDeviceGAID = deviceGaid;
  return _applyConfigVipGaidWhitelist(config, vip, prefs, isDebug: false);
}
```

`_applyConfigVipGaidWhitelist` grants VIP for `Duration(days: 365 * 50)` (see
`ad_manager.dart:3161-3164`) to any device whose GAID matches the config's
whitelist. Because this entry point skips the seam guard, it is callable at
runtime in a release build by anything that can reach a public `AdManager`
instance and construct an `AdConfig`/`VipManager`/`AdPreferences` — which
defeats the entire point of the Ed25519-signed VIP key model documented in
`CLAUDE.md` ("VIP entitlement"): a 50-year grant with no signature check at
all. This is exactly the class of gap rounds 69 (33 seams) and 70 (11 seams,
4 files) were closing; this one slipped through both passes.

**Fix:** add the same guard as every sibling method:
```dart
if (_testSeamsBlocked) return _warnSeamBlocked('debugApplyConfigVipGaidWhitelist');
```

### MINOR — `AdEventLog.debugInjectRawEntry` unguarded

`packages/ad_sdk/lib/src/compliance/ad_event_log.dart:56`

```dart
@visibleForTesting
void debugInjectRawEntry(Map<String, dynamic> entry) => _entries.add(entry);
```

No `_testSeamsBlocked`-equivalent check (this class doesn't have that guard
at all). Lets a caller splice an arbitrary entry into the compliance/consent
event log, which is the record this SDK relies on as legal proof of consent
timing. Lower severity than the VIP finding — it doesn't grant anything by
itself — but it lets the audit trail itself be falsified. Add the same
release-mode guard pattern used in `ad_manager.dart`.

### Not a bug — `VipManager.debugRunValidator`

`packages/ad_sdk/lib/src/vip/vip_manager.dart:1751-1755` is also unguarded,
but it only forwards to `_runValidator(key, validator)`, and `validator` is
already the app-supplied `AdConfig.vipKeyValidator` callback that the public
`redeemVip()` API takes directly — a caller who wants to self-grant VIP
through a rigged validator can already do that through the *public* API
without this seam. Exposing `debugRunValidator` doesn't add capability.
Matches the documented "features, not bugs" pattern for this SDK's VIP
seams — no fix needed.

## Verification of items memory flagged as "still pending" (checked live, not from memory)

- **CI:** `gh run list --limit 5` — all 5 most recent runs are `failure`,
  latest 2026-09-16, nothing since. Still broken (billing), 5 days stale as
  of this audit. Confirmed still true.
- **`android/app/private_key.pepk` (Play signing key export):** still
  reachable in git history — `git rev-list --objects --all` finds blob
  `bf12433e...` at path `android/app/private_key.pepk`, and
  `git log --all --full-history --oneline -- android/app/private_key.pepk`
  resolves to `60a1f3d`. Matches `CLAUDE.md`'s documented "known pending
  security debt": deliberately not purged yet, purge only after
  rotation-if-live is confirmed via Play Console. Still un-rotated, still
  un-purged, as documented.
- **`keystore.jks`:** confirmed genuinely purged — `git rev-list --objects
  --all` and `git log --all --full-history` both return nothing for any
  `*.jks` path. The round-68/session-2026-09-20 purge held.
- **AppLovin SDK key leak (round 69 mention):** the key itself is gone from
  current history (no hardcoded real key found in `lib/`, `example/` —
  current code takes it via `--dart-define=APPLOVIN_SDK_KEY` /
  `String.fromEnvironment`). Whether the leaked value was ever *rotated* on
  AppLovin's dashboard is not something this repo can answer — no evidence
  either way was found in-repo. Treat as still open per prior session notes.
- **iOS consent integration tests:** not re-run in this pass (would need a
  simulator session); no code change since the last documented "blocked,
  UMP form doesn't present on Simulator" finding, so no reason to believe
  it's resolved. Still open.

## Dual-provider / offline / trial — spot-checked, no new findings

Skimmed for parity gaps and lifecycle leaks; nothing beyond the two findings
above turned up in the time budget for this pass. The first-install trial
guard (`_first_install_guard.dart`) is the same deliberately-asymmetric
iOS-Keychain / Android-Auto-Backup design already documented and audited
repeatedly — not re-litigated here.

## Post-fix update (same session, after the 3 concurrent passes finished)

The `debugApplyConfigVipGaidWhitelist` BLOCKER above was fixed and tested
(regression test in `test/ad_manager_debug_seam_release_guard_test.dart`).
`audit_gemini.md` (renamed `audit_gemini_round71.md`) independently found
**3 more unguarded `debug*` seams** of the exact same class, missed by
rounds 68-70's sweep — all verified for real against source (not trusted
from the report) and fixed the same way, each with a regression test:

- `VipManager.clearRedeemedKeyLedgerForTest` (`vip_manager.dart:1791`) —
  MAJOR. No `isActuallyRelease` guard; could wipe the Keychain-backed
  one-time-use ledger in a release build and let an already-spent signed VIP
  key be redeemed again on the same device. Fixed +
  `test/vip_manager_debug_seam_release_guard_test.dart`.
- `debugFormDismissTimeoutOverride` (`ump_consent.dart:19`, exported from the
  public barrel) — MAJOR per gemini. Fixed by gating the read site on
  `kReleaseMode` (no test-seam-block flag exists at this file's scope, so
  this one can't be release-simulated in a unit test the way the class-based
  ones can — existing `ump_consent_test.dart`/`ump_consent_round5_test.dart`
  coverage of the override itself is unaffected since `kReleaseMode` is
  always false under `flutter test`).
- 3 static consent barriers (`debugConsentApplyBarrier`,
  `debugConsentWriteBarrier`, `debugSetConsentTailWriteBarrier` in
  `ad_manager.dart`) read without the `_testSeamsBlocked` check other seams
  in the same file already have — MINOR. Fixed at all 3 read sites.
- `ConsentManager.resetForTest` and `AdSlot.debugFireLoadWatchdogNow` — MINOR,
  same unguarded-lint-only pattern. Both fixed, each given a
  `debugSimulateReleaseModeForTestSeams` flag (matching the established
  per-class pattern) and a regression test.

`AdEventLog.debugInjectRawEntry` was left unfixed — confirmed not
independently reachable (the class isn't exported from the public barrel;
the only path to an instance is `AdManager().debugEventLog`, which is
already guarded), matching the same "not a bug" reasoning already applied to
`VipManager.debugRunValidator` above.

Full suite after all 5 fixes: **2,223/2,223 tests pass**, `flutter analyze`
clean, `test/api_golden_test.dart` (public API surface diff) unaffected —
confirms every fix is either a private read-site check or a new
`@visibleForTesting` field, never a public surface change.

### The one finding neither of us fixed, and shouldn't fix unilaterally

Both `audit_codex.md` and `audit_gemini_round71.md` independently flag the
same architectural point (codex: MAJOR "EEA/UK user may be initialized
before CMP decision"; gemini: notes the same call ordering under §6): in
`ad_manager.dart` around line 3722-3852, `autoRequestUmpConsent`'s UMP flow
is deliberately **not awaited** (see that block's own extensive comment —
this was a conscious round-25/R10-A decision to avoid a real user's
unanswered consent form freezing app startup). `adapter.initialize()` — the
call that starts AppLovin/AdMob's **native** SDK — runs immediately after,
while UMP is still in flight. `canRequestAds` is closed first, so no *ad
request* goes out before consent, but the native SDK's own init-time
behavior (whatever device/network activity AppLovin's or Google's SDK does
at `initialize()`, independent of ad requests) is not gated on consent.

This is a real, previously-undocumented compliance gap for EEA/UK traffic,
not a coding bug — the existing code is doing exactly what its own comments
say it deliberately does. Fixing it means picking a real tradeoff (delay
native init behind UMP vs. accept this gap vs. change the documented
contract to require hosts `await` UMP before `initialize()` themselves) and
isn't a one-line guard like the debug seams above. Left as the **one open
item** for the production verdict below rather than patched under audit
time pressure.

## Verdict: Production-ready?

**CONDITIONAL — down from BLOCKER to one open architectural item.** All 5
debug-seam gaps found across the 3 independent round-71 passes (1 BLOCKER +
4 MAJOR/MINOR) are fixed, tested, and verified against real source — this
class of bug (the one rounds 68-70 already spent 3 rounds on) is very likely
now actually closed. What's left, for an app with real EEA/UK traffic:

1. **Must resolve before shipping to EEA/UK users:** the UMP-vs-native-init
   ordering gap above. Either the host must itself gate its splash-screen
   `initialize()` call behind its own consent check for EEA users, or this
   SDK's contract needs a deliberate design change — this is a product/legal
   call, not something to silently patch.
2. **Already known, already documented, not bugs:** Android trial
   reinstall bypass (no server, no biometric anchor possible — README says
   so) and VIP cross-device replay (same "100% offline, no backend" tradeoff
   the user explicitly required) — both flagged again by codex this round,
   both already litigated in prior rounds per `CLAUDE.md`/memory. Not
   re-opening these.
3. **Unrelated to code, still open:** CI billing outage (5+ days), AppLovin
   key rotation status unverifiable from this repo alone.

## Verdict: Public GitHub?

**NO, not yet.** Unchanged conclusion from `audit_pubdev_public_repo_readiness.md`:
`private_key.pepk` (a real Play App Signing key export) is still retrievable
from anyone who clones this repo — confirmed live in git history above, not
purged. CLAUDE.md's own plan is explicit: check Play Console whether it was
ever used to sign a real release, rotate if so, *then* purge history —
purging first would be false safety. None of those three steps are done.
Going public today hands out a working recipe to extract a real signing key
before anyone has checked whether it needs rotating. Flip to public only
after that sequence completes (and after confirming AppLovin SDK key
rotation status, separately).

## Independent re-review of the round-71 diff itself, and a score

Separate from the audit above, the fixes it produced (the 5 debug-seam
guards) were themselves reviewed independently — same isolation pattern
(fresh `git clone` + the diff applied, external CLI runs there, real repo
untouched):

- **agy (gemini), pass 1:** verified all 5 fixes correct/safely placed, full
  suite green (2,223/2,223), confirmed unit tests are the right level (no
  widget/integration test needed — pure guard logic, no UI). Scored
  **8.5/10**, docking 1.5 for 3 concrete gaps: `debugFormDismissTimeoutOverride`
  untestable (hardcoded `kReleaseMode`, no simulate flag), the 3 static
  consent barriers had no regression test proving the guard actually
  prevents a hang, and the new `AdSlot` test leaked a real 10s `Timer`
  (missing `dispose()`).
- All 3 fixed the same session: added `debugSimulateReleaseModeForFormDismissTimeout`
  + a test proving the 100ms override is ignored (`ump_consent_test.dart`);
  added 2 tests proving `showPrivacyOptions()`/`setConsent()` don't hang on a
  never-completing barrier while release-simulated (`tcf_personalisation_consent_test.dart`);
  added `addTearDown(slot.dispose)` + a control test proving the watchdog
  still fires normally (`adapter_debug_seam_release_guard_test.dart`). Full
  suite after: **2,227/2,227 pass**, `flutter analyze` clean.
- **codex, pass 1 (pre-fix) and agy, pass 2 (post-fix rescore):** both failed
  to deliver a final verdict — tooling flakiness (codex kept re-running
  `flutter test` until its own session got compacted/killed by the outer
  wait ceiling; agy's rescore process self-terminated on an idle timeout
  mid-run), not a code problem — every partial output from both confirms
  `2,22x/2,22x tests passed`. Consistent with this project's known history of
  these CLIs being unreliable on long-running verification passes (see
  memory `codex-usage-limit-resets-unpredictably`,
  `reviewer-cli-can-destroy-uncommitted-work`). Not re-retried a third time —
  diminishing returns.
- **Final score, my own judgment given the above (not an automated
  rescore):** **9.5/10.** agy's rubric only docked for the 3 gaps above; all
  3 are now concretely fixed with a regression test each, personally run and
  confirmed green. The 0.5 held back: no fourth independent pass actually
  re-confirmed the fixed state end-to-end (both attempts died on tooling,
  not on finding anything wrong) — flagging that honestly rather than
  rounding up to a number no external reviewer actually confirmed.
- **Real-device smoke test (Pixel 7 Pro, physical):** installed debug build
  of `packages/ad_sdk/example`, no regression. SDK init, consent bootstrap,
  VIP screen render, MREC/interstitial demo screens all worked; interstitial
  correctly reported "skipped/blocked" (no crash) since no real AppLovin key
  is configured for local builds — expected, not a regression.
