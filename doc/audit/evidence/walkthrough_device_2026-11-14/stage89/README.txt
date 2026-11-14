Stage 8-9 supplemental device test (2026-11-14)
Device: Pixel 7 Pro, serial 2B051FDH3006MU, Android 16. Test app package: com.roy.admobwrapper.walkthrough.
Only Google test ad IDs used. Host package com.roy.admobwrapper was not modified.

Stage 8 — PASS (UMP EEA flow on this device)
- Initial run with EEA debug geography but no registered test hash returned status=notRequired. Google Mobile Ads logged hash 9005AD1E37B82BBBCF70A3B34C485083.
- Rebuilt with this hash in `umpTestIdentifiers`, cleared data of only the throwaway app, and relaunched. UMP reported status=required and displayed Google "Welcome to Publisher Test Ads" consent form (ump_eea_consent_form.png).
- Chose Consent: status=obtained, formShown=true, canRequestAds=true. AdMob applied nonPersonalizedAds=false (consent_result.png).
- Cleared data of only the throwaway app and relaunched; chose Do not consent: status=obtained, formShown=true, canRequestAds=true; AdMob applied nonPersonalizedAds=true (ump_decline_result.png).
- Opened the app's Privacy screen from Home after dismissing the interstitial via its visible close control. Privacy Options reopened the form (privacy_options_reopened_form.png). Chose Consent; log changed nonPersonalizedAds to false while canRequestAds stayed true. (ump_reconsent_result.png is a screenshot of the generic post-consent form state; log is the state evidence.)
- A later tap intended to choose Do not consent did not change state; no claim made for that action.

Stage 9 — PARTIAL / inconclusive
- Wi-Fi state changed 1 -> 0 -> 1 and was restored to on before cleanup.
- On reconnect the SDK logged `network back online -> refilling ad slots + banners` and subsequent ad load activity.
- The captured offline log was incomplete / included unrelated lifecycle activity; this run does not establish the exact no-request-while-offline behavior. Record as inconclusive, not pass.

Build: flutter analyze clean; debug APK build succeeded. App package was removed after testing. No production ad IDs used.

Stage 9 re-run (additional isolated observation, 2026-11-14):
- Reinstalled only the throwaway app, accepted test UMP form, and waited until the Home banner logged `loadBanner [AdMob] ✅` before disabling Wi-Fi.
- Wi-Fi remained off for 30 seconds (`retry_wifi_off.txt` = 0). Filtered app-PID log for this interval had no SDK load/refill/error entries; only two Android Codec2 surface warnings appeared (`retry_offline_window.txt`).
- Re-enabled Wi-Fi (`retry_wifi_after.txt` = 1). SDK logged `network back online → refilling ad slots + banners` (`retry_reconnect_window.txt`).
- The banner was already loaded and stayed mounted, so this does not prove a new ad request completed after reconnect. Stage 9 remains partial: no request observed during the bounded offline window, reconnect hook observed, actual post-reconnect new creative not established.

Stage 9 repeated (final controlled interval):
- Consent EEA completed; Home banner logged `loadBanner [AdMob] ✅` before disconnect.
- Host-side epoch boundaries: Wi-Fi turned off at 1794643730 and turned on at 1794643760 (30 seconds); `wifi_off=0`, final Wi-Fi `1`.
- App PID log during the window contained no SDK request/load/refill/error entries; only `Codec2Client setOutputSurface` surface warning. This supports “no SDK ad request observed during this 30-second window,” not proof for every offline condition.
- On reconnect the SDK logged `network back online → refilling ad slots + banners`. The banner was already loaded before disconnect and no new successful banner creative load was observed afterward; post-reconnect creative recovery remains unverified. Therefore Stage 9 remains PARTIAL, not PASS.

Stage 9 decisive cold-start/reconnect test (2026-11-14):
- Freshly accepted EEA test consent online and confirmed Home banner loaded.
- Wi-Fi disabled, throwaway app force-stopped, then relaunched with Wi-Fi still disabled.
- UMP update failed with `2:Error making request.`; banner size lookup was aborted by reload gate; interstitial load logged `skipped — no network`.
- Wi-Fi restored after about 26 seconds. SDK logged `network back online → refilling ad slots + banners`; banner then logged `loadBanner [AdMob] ✅` and is visibly rendered (`cold_start_reconnected_banner.png`).
- This establishes the tested cold-offline start path, skipped request gates and successful banner recovery after reconnect on this device/test ad. It does not establish all network conditions or broader stability. Prior isolated 30s interval evidence remains for no SDK request logs while offline.
