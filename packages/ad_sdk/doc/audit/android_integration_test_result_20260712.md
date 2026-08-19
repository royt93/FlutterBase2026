# Android integration_test result — packages/ad_sdk (2026-07-12)

## Scope

Verify `packages/ad_sdk` (AppLovin MAX + Google AdMob/GMA mediation) on Android via
the 15 `integration_test/*.dart` files in `packages/ad_sdk/example`, across both ad
providers (AppLovin default, AdMob via `--dart-define=AD_PROVIDER_ADMOB=true`).

Target: real physical device, Samsung Galaxy S24 Ultra (model `SM_S928B`, adb
serial `R5CX613VZBR`) — the sole device connected this session (confirmed via
`adb devices -l` per project rule R3).

## Matrix: 24/30 cells pass, both providers

| # | File | AppLovin | AdMob |
|---|------|----------|-------|
| 1 | app_boot_test | PASS | PASS |
| 2 | anomaly_event_test | PASS | PASS |
| 3 | banner_ad_test | PASS | PASS |
| 4 | compliance_export_test | PASS | PASS |
| 5 | consent_dialog_test | PASS | PASS |
| 6 | log_viewer_test | PASS | PASS |
| 7 | revenue_dashboard_test | PASS | PASS |
| 8 | safety_status_test | PASS | PASS |
| 9 | policy_risk_score_test | PASS | PASS |
| 10 | slot_state_panel_test | PASS | PASS |
| 11 | vip_api_playground_test | PASS | PASS |
| 12 | vip_redeem_flow_test | PASS | PASS |
| 13 | interstitial_ad_test | FAIL (environmental) | FAIL (environmental) |
| 14 | rewarded_ad_test | FAIL (environmental) | FAIL (environmental) |
| 15 | app_open_ad_test | FAIL (environmental) | FAIL (environmental) |

`packages/ad_sdk/lib` — **zero lines changed**. No real SDK defect found on
Android (unlike iOS, where a real show/dismiss zombie-state race was found and
fixed in `lib` during the iOS pass). `packages/ad_sdk`'s own unit/widget suite
stayed 465/465 green throughout, re-confirmed after the test-file merge below.

## interstitial/rewarded/app_open failures — not an SDK bug

All three fullscreen formats render the same AppLovin MAX test-ad creative
("Congrats! You're seeing a test ad.", pink triangle/thumbs-up, "MAX by
AppLovin" branding) with no accessible/tappable dismiss element. Verified with
stronger, more methodical evidence than the equivalent iOS-Simulator finding:

- **Screenshots** (`adb exec-out screencap`) at multiple stages (before/after
  tap, after back-button, after 15s+ wait) — no visible X/close/skip control in
  any corner.
- **`adb shell uiautomator dump`** (raw accessibility-tree, not just Flutter's
  semantics tree) — the ad renders as a single opaque WebView node; the only
  interactive children are a "Google Play" pill and a small info-icon
  bottom-left. No node anywhere matches close/skip/dismiss.
- **Raw-coordinate `adb shell input tap`** (bypassing the accessibility tree
  entirely) on the one plausible candidate (the info-icon) produced a genuine
  ad **click-through** (SDK logs: `🎯 click`, `AdSafety Click | CTR=100%`,
  navigation to Google Play), not a dismiss. Slot state stayed `showing`
  throughout; no self-dismiss timer fired within 18+ seconds.

Consequence: `_waitForNotShowing`'s 60s poll times out whenever a real ad fill
succeeds — indistinguishable, by design, from an actual SDK zombie-state bug.
The assertion was deliberately **not weakened** so a future real regression in
this exact bug class (the one found and fixed on iOS) still surfaces loudly.

Process-level symptom differs by provider: on AppLovin the outer `flutter
test` process itself hung past the in-test 60s poll (killed externally via
`timeout`/`pkill`, device recovered via `adb shell am force-stop
com.roy.admobwrapper`); on AdMob the in-test `fail()` assertion was reached
cleanly at the 60s mark (clean exit code 1, no hang) — same root cause,
different manifestation.

## Two test-methodology bugs found and fixed (test-file-only, not SDK)

### 1. VIP-grace window masked the real ad lifecycle (false PASS)

`interstitial_ad_test.dart`, `rewarded_ad_test.dart`, `app_open_ad_test.dart`
originally never revoked the first-install VIP grace window
(`DemoConfig.firstInstallVipGrace`), during which `AdManager` silently no-ops
every load/show call — these three tests were reporting PASS without ever
exercising the real ad show/dismiss lifecycle. Fixed with
`AdManager().vip!.revokeAll()` (mirrors `vip_redeem_flow_test.dart`'s existing
pattern). Confirmed working: after the fix, logs show tap → load → show
reaching real ✅ displayed/shown states on both providers, every run (including
reward-grant for rewarded: `🏆 type=coins amount=10`, `onEarnedReward:
result=true`) — proving this fix is solid, and that the remaining failures are
purely the dismiss-affordance limitation above, not a regression it caused.

### 2. Consent dialog intercepting the tap right after VIP-grace revoke

A second-order effect of fix #1: revoking VIP grace mid-test unmasks the SDK's
already-scheduled post-splash consent dialog
(`AdManager._maybeScheduleConsentDialog`, ~1s post-splash delay, re-checks VIP
at both schedule-time and fire-time). It was scheduled while VIP was still
inactive-pending, then fired right after `revokeAll()`, swallowing the tap
meant for the demo tile underneath (confirmed via `[AdScreen~Router] ➡️ PUSH:
null` + hit-test-miss warnings in the original broken run's logs). Fixed via a
shared helper added to all three files:

```dart
Future<void> _revokeVipGraceAndClearConsentDialog(WidgetTester tester) async {
  await AdManager().vip!.revokeAll();
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 300));
    final allow = find.text('Allow personalized ads');
    if (allow.evaluate().isNotEmpty) {
      await tester.tap(allow);
      await tester.pump(const Duration(milliseconds: 300));
      break;
    }
  }
}
```

### Recurring viewport-culling bug (log_viewer_test / revenue_dashboard_test)

Same pattern already fixed on iOS for `compliance_export_test.dart`'s last
tile: `ListView(children: [...])` still viewport/cache-extent-culls widgets
outside the visible area even with an explicit (non-lazy-builder) children
list. "Log viewer" (tile 8/10) and "Revenue dashboard" (tile 9/10) had no
`Element` in the tree at default phone height. Fixed with a tall synthetic
viewport (`tester.view.physicalSize = const Size(1080, 4000)`, reset via
`addTearDown`) + `tester.scrollUntilVisible(...)` before tap. This fix was
already present in the main repo's copies of these two files by the time the
Android matrix ran (carried over from the earlier iOS-side pattern), so no
further edit was needed for them this pass — only the three ad-lifecycle
files needed merging in from the isolated worktree the test run used.

## Process note: isolated worktree, now merged and cleaned up

The nested test-running agent did its work in an isolated git worktree
(`.claude/worktrees/agent-ae9c8d30742f811fd`, branch
`worktree-agent-ae9c8d30742f811fd`) to avoid colliding with other in-flight
work on the same device. Its 5 modified `integration_test/*.dart` files were
diffed and merged into the main repository by hand (`git apply` failed due to
line-context drift — two of the five files already carried the equivalent
viewport fix from the iOS work, so only the 3 ad-lifecycle files needed real
changes). `flutter analyze` confirmed clean post-merge; the worktree and its
branch have been removed.

## Conclusion

`packages/ad_sdk` integration behavior is verified correct and consistent
across AppLovin and AdMob providers for 12/15 scenarios on real Android
hardware, with zero SDK-source changes required. The 3 failing scenarios are a
confirmed environmental/tooling limitation (no dismissable element in the real
ad-fill creative), evidenced more rigorously here than on iOS Simulator via
raw-coordinate taps and accessibility-tree dumps unavailable on that platform.
Two real test-methodology gaps (VIP-grace false-PASS, consent-dialog tap
interception) were found and fixed as a byproduct of exercising the real ad
lifecycle for the first time.

## Combined cross-platform status

| Platform | Surface | Result |
|---|---|---|
| iOS | Simulator | 14/15 pass (both providers); 1/15 environmental fail (app_open dismiss) |
| iOS | Physical device | Blocked — structural `flutter_tools` bug (`disablePortPublication` on iOS `flutter test`), not fixable from this repo; skipped with user approval |
| Android | Physical device (S24 Ultra) | 12/15 pass (both providers); 3/15 environmental fail (interstitial/rewarded/app_open dismiss) |

`packages/ad_sdk/lib` received one real fix this cycle (iOS: show/dismiss
zombie-state race) and zero Android-side fixes — Android served as
confirmation, not discovery, for SDK-source correctness. The example app's
`integration_test/` suite itself absorbed several real fixes (viewport
culling, VIP-grace false-PASS, consent-dialog interception) across both
platforms.
