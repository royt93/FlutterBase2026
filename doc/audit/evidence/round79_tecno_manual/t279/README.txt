T279: investigation of the flaky round39_vip_crl_demo_button_test (TECNO KJ7, Android 14, 2026-11-12). Temp package com.roy.admobwrapper.t279test (copy of the example in /tmp; uninstalled; repo untouched).
Logs here keep VIP/AdManager lines; most AdMob/consent noise filtered out. Counts below were taken from the unfiltered output.

run_1..run_6      6 consecutive runs: 5 PASS, 1 FAIL (run_2).
repro_olddata_1..3  3 runs after I deliberately left expired first-install VIP data on the device (launch, wait 45 s, force-stop): 3 PASS.

The one failing run (run_2) differs from every passing run in three ways, all visible in its log:
  - it started with "VipManager purgeExpired: removed 1" (an old VIP entry was still in storage);
  - the first-install trial (__FIRST_INSTALL__, 30 s in debug) was NOT granted;
  - therefore App Open was not suppressed by VIP, "showAppOpen ... shown" appeared and the HomePage tile was never found within the test's 40 x 500 ms wait.
Passing runs: no old VIP data, trial granted (30 s) -> VIP active -> App Open skipped ("loadAppOpen skipped - VIP member") -> the tile is found.

NOT established: how run_2 ended up with old VIP data. flutter test's tearDownAll tries `adb uninstall com.example.ad_sdk_example` (the Gradle namespace), not the installed applicationId, so it does not remove the app between runs; yet 5 of 6 runs started clean. My attempt to reproduce by leaving expired data failed (3/3 pass), so the trigger is something else (timing, or storage state I could not reproduce). Do not treat "leftover data" as the proven cause: it is the only observed correlation, from a single failing run.
Earlier failures (t274/): out_base_round39_2.txt and out_round39_rerun.txt also fail with App Open shown; their start-state lines were not captured in a comparable way.
Limit: 1 failure in ~16 total runs across clean HEAD and the T273 build; one device.

==================== UPDATE 2026-11-12 (later): 20-run series + controlled experiment ====================
series20/ : 20 consecutive runs of round39 on TECNO (current repo, temp package com.roy.admobwrapper.t279b): 19 PASS, 1 FAIL (run 2). package_events.txt = every
  uninstall command, restore event and package deletion seen in the continuous logcat. Counted from each run's own output (not from exit wrappers).
  Run 2 is the only run that started on leftover app data: "purgeExpired: removed 1", no first-install trial ("first-install VIP grace granted" absent) -> VIP did not suppress App Open ->
  App Open showed -> the tile was not found. Every other run had no purgeExpired line and a granted trial.
  What differs about run 2: the run BEFORE it (run 1) was the only one whose end-of-test uninstall FAILED (DELETE_FAILED_INTERNAL_ERROR), and no uninstall of the temp package happened between
  runs 1 and 2 (package_events.txt). In the other 18 transitions an uninstall of the temp package happened between runs (data wiped, so the trial was granted again).
  Why the end-of-run uninstall is unreliable: flutter test's tearDown runs `adb uninstall com.example.ad_sdk_example` (the Gradle namespace); the installed id is the applicationId, so that command
  targets a package that is not installed. Only the harness's own uninstall of the real id (visible in package_events.txt) wipes data.
controlled/ : controlled experiment, two copies with their own ids, same device:
  c1 PASS, then c2 immediately, NO cleanup between them -> c2 FAIL: starts with "purgeExpired: removed 1", no trial, App Open shown, tile not found. The c1 trial entry had expired at 23:05:36 and c2
     started at 23:05:41 on the surviving data.
  d1 PASS, then `pm clear` of that package, then d2 -> d2 PASS: starts clean, trial granted.
  Reproduced the failing state on demand once (c2) and prevented it once (d2). Small sample (2 + 2).

CONCLUSION (what is established): the failure of round39 is explained by test-environment state, not an SDK defect. The test assumes a fresh first-install trial (30 s in debug) that keeps App Open
  suppressed at splash. When the previous run's app data survives (same package re-run within the trial's lifetime / after it expired), no trial is granted, App Open shows and covers the home list.
  The SDK behaves as designed (no trial on a non-first launch -> App Open at splash).
NOT established / limits: why exactly one transition in the 20-run series failed to wipe data while the other 18 did (the temp harness's uninstall step apparently skipped/failed once); only one device;
  a 2 + 2 controlled sample; "unreliable uninstall" is the observed mechanism, not tested exhaustively. This is the TEST's weakness (depends on a clean install), so the right fix is in the test or the
  run procedure (clear data before each run, or make the test independent of the trial), and needs the owner's OK to change an integration test.
