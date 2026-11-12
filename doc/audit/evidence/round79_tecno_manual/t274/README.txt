T273/T274 device run, TECNO KJ7 (Android 14), 2026-11-12, example copied to /tmp under throwaway package ids (.t274test = with T273 changes, .t274base = clean HEAD), both uninstalled afterwards.
Command: flutter test integration_test/<file>.dart -d <TECNO> --dart-define=AD_PROVIDER_ADMOB=true (JDK 17 only for the run). Logs here are the flutter output with the SDK "roy93~" log lines removed.

round39_vip_crl_demo_button_test.dart (11 runs):
  out_round39.txt            T273 build, FAILED: assertion looked for the old snackbar text "Checked for a revocation list" (my bug: I had changed the text). Fixed in the test.
  out_round39_rerun.txt      T273 build, FAILED: "HomePage must list the VIP API playground tile" - an App Open ad covered the screen (showAppOpen shown) so the tile was never found.
  out_base_round39_1.txt     clean HEAD, PASSED
  out_base_round39_2.txt     clean HEAD, FAILED the same way (tile not found, App Open shown)  => flaky BEFORE T273
  out_base_3/4/5, out_new_3/4/5: all PASSED (T273 build passed 3/3 after the assertion fix).
  Tally after the assertion fix: T273 build 3 pass / 1 fail; clean HEAD 4 pass / 1 fail. The failure is the same in both: the test does not wait out / dismiss a full-screen App Open ad.
Other files (T273 build, one run each): vip_revocation_list_test PASS, vip_api_playground_test PASS (2 tests), r23_crl_selfsigned_cache_test PASS (2 tests), t220_owner_decisions_device_test PASS.
Limits: one device, small number of runs (a flaky test passing 3 of 3 does not prove it is stable); the T273 build was tested with VIP_CRL_URL unset only (no-op path); the example's real HTTPS fetch is covered by unit tests with a loopback server, not by a device run.
