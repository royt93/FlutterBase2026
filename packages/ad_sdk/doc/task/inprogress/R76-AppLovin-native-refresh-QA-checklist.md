# R76 — AppLovin Native refresh QA checklist

## Purpose

Verify on a physical QA device that `InlineAdController.refresh()` creates a fresh AppLovin native ad after the Flutter widget remount fix in commit `1f873e1`. Widget regression test proves Flutter State replacement only; it does not prove native ad loading or fill.

## Before test

- Use Android or iOS device, QA build, AppLovin QA ad unit and SDK key; never click production ads.
- Confirm AppLovin SDK initializes and `NativeAdWidget` reaches loaded state before refresh.
- Capture app version, platform/OS, device, AppLovin SDK/plugin versions, ad-unit ID label (do not record secret SDK key), connectivity state and logs.

## Cases

1. **Baseline load:** mount one AppLovin `NativeAdWidget`; verify one native ad loads and callback sets loaded state.
2. **Refresh:** invoke controller `refresh()` after cooldown permits; verify old view is disposed, new native view mounts, and a fresh load callback/creative arrives.
3. **Repeated refresh:** refresh again after cooldown; verify each accepted refresh causes one remount/load, no duplicate callbacks, stale callback does not alter replacement state.
4. **Cooldown:** refresh while cooldown blocks; verify no view replacement/load.
5. **Pause/resume:** pause disposes view; refresh while paused does not reload; resume mounts/loads once.
6. **Teardown:** navigate away/dispose during load and immediately re-enter; verify late callback does not affect new instance and no crash.
7. **Connectivity:** if feasible, remove network during refresh then restore it; record failure/recovery, without treating no-fill as lifecycle failure.

## Evidence and pass criteria

- Save timestamps/log markers for refresh request, old-view dispose, new-view creation, load success/failure, and widget teardown.
- Pass only if accepted refresh demonstrably creates a new native view and produces a new load lifecycle, while blocked refresh does nothing and teardown is safe.
- Distinguish provider no-fill/network failure from the original stale-view defect. Repeat at least three successful QA loads where inventory allows.
- This test does not validate AdMob, cross-platform parity, policy compliance, or memory leak absence; record untested cases separately.
