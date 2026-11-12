T276: smoke of a RELEASE build of the example on TECNO KJ7 (Android 14), 2026-11-12.
Package: com.roy.admobwrapper.t276test (copy of the example in /tmp, uninstalled afterwards). Built with:
  flutter build apk --release --dart-define=AD_PROVIDER_ADMOB=true --dart-define=SKIP_ATT=true   (JDK 17 for the run only)
Signing: the signer is the Android DEBUG certificate (apk_signer.txt) - no local keystore pointer existed in the copy, so no real key was used. APK 61,108,908 bytes.
Ad IDs: the example's Google TEST ad unit IDs only. No production IDs.

What the release log shows (release_flutter_log.txt, release_native_ads_log.txt):
  1) The SDK logs at release: "AdMob provider is active in RELEASE with Google TEST ad unit IDs ... Serving test ads in production violates AdMob policy and earns $0".
     The source (ad_manager.dart: _applyTestIdFootgunGuard) sets a block flag in release so that canRequestAds stays false for the process.
  2) Across the WHOLE session (~35k logcat lines) there are 0 ad request/load/fill lines from the app process (grep: onAdLoaded|loadAd|AdRequest|No fill|Failed to load|/mads/gma|ad_request).
     The only "Ads" tag lines are the GMA SDK's own initialisation (3 lines).
  3) UI: Interstitial demo shows "Shown: 0 times / Last: skipped/blocked" with and without the first-install trial active; Banner screen shows no banner (screenshots kept: s_release_banner_novip.png).
  4) Release first-install trial: VIP screen showed "VIP ACTIVE, expires 13/11/2026 21:24" about 4 minutes after first launch, i.e. a ~24 h trial (debug is 30 s). The trial entry was then removed from the UI (s_release_vip_removed.png) to test the guard without VIP.
  5) No FATAL EXCEPTION, no ANR. App started and reached the home list (s_release_start.png).

What this does NOT show:
  - It does not prove that real ads display in release: no production ad unit was used, by design.
  - Kotlin metadata messages: the FIRST release build printed 24 "e:" lines (kotlin_metadata_error_count.txt: play-services-ads 25.5.0 metadata is 2.3.0, expected 2.1.0). I then rebuilt in a fresh copy:
    a DEBUG build printed 0 such lines and a second RELEASE build printed 0 (APK 61,108,896 bytes vs 61,108,908 in the first build). Both builds exited 0. So the messages appeared once, on the first
    (cold Gradle transform cache) release build, and I did not reproduce them; cause not established. The app built and ran either way; I did not install or test the second release APK.
  - R8/minify: no mapping/keep-rule review was done; "the app starts, reaches the home list and the guard path works" is all that was observed.
  - The release was only signed with the debug key; the app-signing/Play-App-Signing flow was not tested.
  - "No ad request lines" is an absence-of-evidence check (a grep), strengthened by the source and the "skipped/blocked" UI text, but I did not capture network traffic.
  - One device, one run.
