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
