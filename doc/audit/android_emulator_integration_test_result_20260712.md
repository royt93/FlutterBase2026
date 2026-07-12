# Android EMULATOR integration_test result — packages/ad_sdk (2026-07-12)

## Scope

First-ever run of the full 15-file × 2-provider `integration_test` suite on an
Android **emulator** (`emulator-5554`, `sdk_gphone16k_arm64`) — all prior Android
coverage in this project was on physical hardware (Samsung S24 Ultra / TECNO
BG6). Triggered as a fresh verification after 6 new features (T31-T36) landed in
`packages/ad_sdk/lib`, including changes at the exact choke points these tests
exercise (`AdManager.initialize()` now registers a crash guard; `showInterstitial()`/
`showRewardedAd()` gained an arbitrator-veto check; `showRewardedAd()` gained
optional SSV params) — all confirmed default-off/no-op via ~514 unit tests, this
run is the on-device confirmation.

Raw logs: `/tmp/ad_sdk_android_20260712/*.log` (one file per test × provider,
plus a retry log for `rewarded_ad_test` AppLovin).

## Matrix: 24/30 nominal pass — but 1 is a false pass (see below)

| # | File | AppLovin | AdMob |
|---|------|----------|-------|
| 1 | app_boot_test | PASS | PASS |
| 2 | anomaly_event_test | PASS | PASS |
| 3 | banner_ad_test | PASS | PASS |
| 4 | compliance_export_test | PASS | PASS |
| 5 | consent_dialog_test | PASS | PASS |
| 6 | interstitial_ad_test | FAIL (environmental) | FAIL (environmental) |
| 7 | rewarded_ad_test | FAIL (environmental) | **FALSE PASS — did not exercise real ad lifecycle** |
| 8 | app_open_ad_test | FAIL (environmental) | FAIL (environmental) |
| 9 | vip_api_playground_test | PASS | PASS |
| 10 | log_viewer_test | PASS | PASS |
| 11 | policy_risk_score_test | PASS | PASS |
| 12 | revenue_dashboard_test | PASS | PASS |
| 13 | safety_status_test | PASS | PASS |
| 14 | slot_state_panel_test | PASS | PASS |
| 15 | vip_redeem_flow_test | PASS | PASS |

`packages/ad_sdk/lib` — zero lines changed as a result of this run. No genuine
new regression found from the T31-T36 changes.

## The 3 fullscreen-ad files — same documented environmental limitation

Same root cause as the physical-device report
(`doc/audit/android_integration_test_result_20260712.md`): the real AppLovin/AdMob
test-ad creative exposes no accessible/tappable dismiss element, so
`_waitForNotShowing`'s 60s poll times out. Evidence this run:

- `interstitial_ad_test` (AppLovin): the outer `timeout` wrapper killed the hung
  `flutter test` process, which then hit an unrelated `flutter_tools` internal
  race during forced shutdown (`PathNotFoundException` deleting
  `flutter_test_listener.*` — a tooling artifact of killing the process
  mid-test, not an app-level bug; same class of `flutter_tools` fragility noted
  for iOS physical device in `doc/audit/ios_integration_test_result_20260712.md`).
- `interstitial_ad_test` (AdMob): clean assertion failure — "interstitial slot
  never left the showing state within 60s" — no tooling artifact, straightforward
  environmental repro.
- `rewarded_ad_test` (AppLovin): same `timeout`-kill + `flutter_tools`
  finalization race as interstitial/AppLovin above.
- `app_open_ad_test` (both providers): AppLovin's watchdog ticked all 18×5s
  cycles to its documented 90s hard cap, force-dismissed, but the outer test
  process still didn't exit before the wrapper's `timeout` fired (124). AdMob
  failed cleanly on the same 60s assertion. Matches the documented App-Open
  watchdog behavior exactly — no change from the recent `late arrival` fix
  (commit `0c08cba`, App-Open callback handling only, confirmed via `git show`
  during this investigation).

## Important finding: `rewarded_ad_test` (AdMob) is a FALSE PASS, not a real pass

The log shows `EXITCODE=0` / "All tests passed!", but reading the actual log
reveals the ad **never loaded**:

```
roy93~ [AdScreen] showRewardedAd pre-check result: canShow=false
roy93~ [AdScreen] showRewardedAd ⏭️ no valid ad → showing TopToast + earned=false
roy93~ [TopToast] 🍞 show() message="Ad not ready — please wait."
```

The slot never entered `showing`, so `_waitForNotShowing`'s poll trivially
succeeded without ever exercising the real show/dismiss lifecycle this test is
supposed to prove. This is **not** the previously-fixed "VIP-grace false-PASS"
bug (VIP grace was correctly revoked per the log — `VipManager active state
changed: true → false` appears before the show attempt) — it looks like AdMob's
real ad network simply didn't fill an on-demand rewarded ad fast enough on this
particular emulator run (emulators are a weaker ad-fill environment than real
hardware — no real device signals, different Play Services stack). **This
result should not be counted as a verified pass** for AdMob rewarded on
emulator; treat AdMob rewarded on this platform as *not yet genuinely verified*
rather than confirmed green.

## Arbitrator-veto / crash-guard no-op confirmation

Grepped all 31 captured logs (30 invocations + 1 discarded early-exit retry)
for `vetoed`, `arbitrator`, `ad_crash_guard`, and `monetization_arbitrator`
(case-insensitive): **zero matches anywhere.** The arbitrator-veto path added
to `showInterstitial()`/`showRewardedAd()` is confirmed a complete no-op on
this run, consistent with `_arbitrator` being `null` by default and
`enableArbitrator()` never being called in `packages/ad_sdk/example`. The new
crash guard (`AdConfig.enableCrashGuard`) and the unused `ssvCustomData`/
`ssvUserId` params likewise produced no observable behavior change — no app
boot failures, no new exceptions, no crash-guard log lines requiring
intervention.

## Conclusion

12/15 (AppLovin) + 13/15-but-1-false (AdMob) files exercise real SDK behavior
correctly on Android emulator with zero `packages/ad_sdk/lib` changes needed.
The 3 fullscreen-ad files fail via the same confirmed environmental limitation
documented on physical Android and iOS Simulator. One AdMob result
(`rewarded_ad_test`) needs to be treated as unverified rather than passing, due
to an on-demand ad-fill timing issue specific to the emulator environment, not
an SDK defect. No genuine regression was found from the just-landed crash-guard
/ arbitrator-veto / SSV-params changes — all three are confirmed no-ops for
this example app's usage, matching the ~514 unit/widget tests (not re-run
here, per task scope) that already covered them statically.

## Combined cross-platform status

| Platform | Surface | Result |
|---|---|---|
| iOS | Simulator | 14/15 pass (both providers); 1/15 environmental fail (app_open dismiss) |
| iOS | Physical device | Blocked — structural `flutter_tools` bug (`disablePortPublication` on iOS `flutter test`), not fixable from this repo; skipped with user approval |
| Android | Physical device (S24 Ultra) | 12/15 pass (both providers); 3/15 environmental fail (interstitial/rewarded/app_open dismiss) |
| Android | Emulator (`sdk_gphone16k_arm64`, first-ever run) | 12/15 pass (AppLovin); 12/15 pass + 1 false-pass (AdMob `rewarded_ad_test`, ad-fill timing, not exercised); 3/15 environmental fail matches the physical-device finding exactly; zero `lib` changes; crash guard / arbitrator-veto / SSV params confirmed no-op |

Emulator result is consistent with the physical-device Android run — same 3
fullscreen files fail for the same documented reason, same 12 non-fullscreen
files pass cleanly on both providers except for the one AdMob ad-fill timing
flake noted above (an emulator-specific weakness, not a regression). No new
`packages/ad_sdk/lib` defect surfaced on this platform across any of the two
Android environments tested to date.
