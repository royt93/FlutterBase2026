T274 re-run with the documented procedure: `pm clear <temp package>` before EVERY run (example/integration_test/README.md).
TECNO KJ7 (Android 14), 2026-11-13, copy of the repo in /tmp under com.roy.admobwrapper.t274b (uninstalled afterwards; repo untouched).
Command per run: flutter test integration_test/<file>.dart -d <TECNO> --dart-define=AD_PROVIDER_ADMOB=true (JDK 17 for the run only). Two runs per file, 10 runs total, run back to back.

RESULTS (from each run's own output): 10 of 10 PASS.
  vip_revocation_list_test            #1 PASS  #2 PASS   (1 test each)
  vip_api_playground_test             #1 PASS  #2 PASS   (2 tests each)
  round39_vip_crl_demo_button_test    #1 PASS  #2 PASS   (1 test each)   -> with pm clear: no old data, trial granted, App Open not shown in either run
  r23_crl_selfsigned_cache_test       #1 PASS  #2 PASS   (2 tests each)
  t220_owner_decisions_device_test    #1 PASS  #2 PASS   (1 test each)
  Start-state markers (counted per run): none of the 10 started on leftover VIP data ("purgeExpired" count 0); 8 of 10 show the first-install trial being granted; the 2 t220 runs show no
  trial line because that test sets up its own VIP state (its log starts with "VipManager load() entries=0" and later "entries=2"), which is expected for that test.

WHAT THIS SHOWS / DOES NOT SHOW:
  - Shows: with a cleared package before each run, all five files passed twice, including round39 (the file that failed without clearing in the T279 investigation).
  - Does not show: stability. Two runs per file is small; round39 failed ~1 in 20 WITHOUT pm clear, so two clean passes neither confirm nor refute that rate. This run also does not test the "forgot to clear" case.
  - One device, one session. Not a CI run.
