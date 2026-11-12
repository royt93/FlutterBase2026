T278: Privacy Options completed within the SDK's 180 s limit. TECNO KJ7 (Android 14), 2026-11-12. Temp package com.roy.admobwrapper.t278test (copy of the example in /tmp, built with
UMP_EEA_DEBUG=true and the TECNO hashed test-device id; its own app data cleared before each attempt; uninstalled afterwards; repo untouched).

WHO OPERATED: the form buttons were tapped by ADB at fixed screen coordinates (the user asked me to do it myself). They are NOT human taps. uiautomator cannot see inside the native UMP form,
so taps were by coordinates derived from screenshots. The timing below therefore reflects adb speed, not a person's.

ATTEMPT 1 (attempt1_abandoned_form/): I asked the user to tap; nobody did. The form stayed open: "consent form dismiss timed out after 180s" (21:49:12) then, at 22:01:12, the SDK's 15-minute
 safety release "a UMP form never reported being dismissed - releasing the ad block". Not usable as evidence of the normal flow; useful as one more observation of the timeout/backstop path.

ATTEMPT 2 (run2_*): clean data, same build.
  22:06:58.725  first UMP form shown ("consent status: required")
  22:07:19.285  adb tap "Do not consent" -> "done canRequestAds=true status=obtained formShown=true"; ConsentSettings consent=false; applyConsent nonPersonalizedAds=true (hasUserConsent=false)
  22:08:26.7    adb tap "Privacy Options" (Privacy settings screen); the same form re-appeared (s_run2_privacy_options_form.png)
  22:08:45.801  adb tap "Consent" -> "privacy options done canRequestAds=true status=obtained"; applyConsent nonPersonalizedAds=false (hasUserConsent=true); ConsentSettings consent=true
  Privacy Options form duration (log clock): ~19 s from the tap to the "done" event (the form appears a few seconds after the tap), well inside the 180 s limit; no timeout line in this attempt.
  No FATAL EXCEPTION, no ANR. Device-vs-Mac clock delta -1 s.

CONCLUSION: the "change your mind via Privacy Options" flow completes normally when the form is answered promptly: declined -> non-personalised ads; after Privacy Options -> Consent, personalised ads
 (nonPersonalizedAds false), and the SDK reports the new state without the 180 s timeout. This closes the earlier gap where the one TECNO run exceeded 180 s and the late choice was re-applied.
NOT shown: a human tapping at human speed, the other form choices (Manage options), a real EEA user, other devices, and the late-answer path in this build. One device, one successful run.
