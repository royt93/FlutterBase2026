T279 fix check: round39 with the "wait for fullscreenBusy" change vs the committed version. TECNO KJ7 (Android 14), 2026-11-13.
Two copies of the repo under their own package ids (com.roy.admobwrapper.t279fold = test as committed at HEAD, .t279fnew = test with the fullscreenBusy wait), both uninstalled afterwards.
Design: 6 pairs per version. Each pair: uninstall the temp package, run "a" (fresh install), then run "b" IMMEDIATELY with nothing cleared. Old and new alternate. 24 runs. Outputs: run_<old|new>_<N><a|b>.txt.

RESULTS (counted from each run's own output):
  a runs (fresh install): old 6/6 pass, new 6/6 pass; every one granted the first-install trial.
  b runs (re-run on surviving data):
    old: 5 pass, 1 FAIL (pair 1)        new: 6 pass, 0 fail
  Only pair 1 of EACH version actually started "b" on surviving data without a trial (purgeExpired: removed 1, no first-install trial):
    old_1b : FAILED - App Open was shown (splash loaded it, buffer dialog, "showAppOpen shown"), tile not found.
    new_1b : PASSED - same start state (no trial), but App Open was NOT shown in this run: the splash budget (8 s) expired first ("forcing markSplashInactive", REPLACE route), so App Open was
             loaded after the splash was already left and never shown. See ordering_old_1b.txt / ordering_new_1b.txt.
  In pairs 2-6 an adb uninstall of the temp package happened between "a" and "b" (package_events.txt), so "b" was a fresh install with a trial again: old and new both passed. They do NOT test the fix.

WHAT THIS DOES AND DOES NOT SHOW:
  - It does NOT show that the fix works. In the only run where the new test faced the failing start state, the failure condition (App Open covering the home list) did not occur, so the new wait was never exercised
    (fullscreenBusy was false; the wait loop never had to wait). new_1b passing is consistent with the fix but is also explained by the splash timing alone.
  - It DOES show that the failing start state is not always a failure: with no trial, App Open sometimes shows (old_1b, earlier runs) and sometimes does not (new_1b).
  - Not shown: how often the old test fails on surviving data (n=1 in this series; ~1 in 20 in the earlier series), or any case where the new test has to wait.
  - Why uninstalls happened in pairs 2-6 but not pair 1 is not established (the harness's own uninstall step ran for the fresh-install setup of the next pair; between a and b it appeared from pair 2 on).
Conclusion: the sample cannot separate "fix works" from "got lucky". To actually test the fix, the start state must be forced (e.g. run b on surviving data many times, or hold App Open on screen), which needs a different experiment.
