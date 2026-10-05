---
name: run-example
description: Build and run packages/ad_sdk/example on a connected Android device with AdMob test ads (no real keys), and read SDK logs. Use to smoke-test a change or a published version of applovin_admob_sdk.
---

# Run the ad_sdk example on a real Android device

What this proves: the app starts, UMP resolves, the AdMob adapter initialises and
loads, nothing crashes. What it does NOT prove: anything about `AppLovinAdapter`
(AppLovin needs real keys), or late-callback races (cannot be triggered by hand;
those are covered by `test/applovin_adapter_test.dart` and `example/integration_test/`).

## Steps

1. `adb devices` and pick the device id.
2. The machine's default JDK may be too new for Gradle 8.12 (Java 25 fails with a bare
   version number as the error). Use JDK 17 only for this run, then restore:
   ```bash
   flutter config --jdk-dir="$(/usr/libexec/java_home -v 17)"
   # ... build ...
   flutter config --jdk-dir=""
   ```
3. Build with AdMob test ids (no credentials needed):
   ```bash
   cd packages/ad_sdk/example
   flutter build apk --debug --dart-define=AD_PROVIDER_ADMOB=true --dart-define=SKIP_ATT=true
   ```
4. Install and launch, then read only SDK lines:
   ```bash
   adb -s <id> install -r build/app/outputs/flutter-apk/app-debug.apk
   adb -s <id> logcat -c
   adb -s <id> shell monkey -p <applicationId> -c android.intent.category.LAUNCHER 1
   sleep 25
   adb -s <id> logcat -d -s flutter | grep -E "UmpConsent|AdMobAdapter|AdManager"
   adb -s <id> logcat -d | grep -E "FATAL EXCEPTION"
   ```
5. Screenshot with `adb -s <id> exec-out screencap -p > shot.png` and look at it.

## Do not clobber a real app

The example's `applicationId` is `com.roy.admobwrapper`, the same id as the host app.
`install -r` will replace it. To test a published version without that risk, copy
`example/` to `/tmp`, change the `applovin_admob_sdk` dependency from `path: ../` to a
hosted version, and change `applicationId` in `android/app/build.gradle.kts` to a
throwaway id. Confirm `pubspec.lock` shows `source: hosted` for the SDK.

## AppLovin (real ads)

Pass keys only at run time, never edit committed placeholders and never print them.
Names read by `example/lib/main.dart`: `APPLOVIN_SDK_KEY`, `APPLOVIN_{BANNER,INTERSTITIAL,APPOPEN,REWARDED,MREC,NATIVE}_ID_{ANDROID,IOS}`.
