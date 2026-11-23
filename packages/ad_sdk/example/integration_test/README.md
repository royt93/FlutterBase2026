# Running the integration tests on a real device

Run from `packages/ad_sdk/example`, with AdMob selected (without it the example falls back to AppLovin
placeholders and the run hangs):

```bash
flutter test integration_test/<file>.dart -d <device-id> --dart-define=AD_PROVIDER_ADMOB=true
```

## Clear the app's data before every run

Several tests assume a **fresh install**: in a debug build the first launch grants a 30-second
first-install VIP trial, and that trial keeps the splash App Open ad suppressed. If the previous run's app
data is still on the device there is **no trial**, App Open shows and covers the home list, and a test that
looks for a home-screen tile fails (seen in `round39_vip_crl_demo_button_test.dart`, see task T279).

`flutter test` does not reliably wipe the data between runs: its teardown runs
`adb uninstall com.example.ad_sdk_example` (the Gradle namespace), while the installed package is the
`applicationId` (`com.roy.admobwrapper`, or the id your build uses). So clear it yourself:

```bash
adb -s <device-id> shell pm clear com.roy.admobwrapper      # or: adb uninstall com.roy.admobwrapper
```

`pm clear` only affects that one package. If you changed `applicationId` for a throwaway build, use that id.

## Add `--dart-define=SKIP_SPLASH_AD=true` for tests that tap the home list

The debug first-install VIP trial only lasts 30 s, and the splash App Open ad (a Google test creative) shows
or not depending on fill and timing. When it shows it covers the home list, so `vip_redeem_flow_test.dart`
and `round39_vip_crl_demo_button_test.dart` failed intermittently (`Bad state: No element` at the scroll, or
"HomePage must list the ... tile"): roughly 1 run in 2 on both 3.7.10 and 3.7.11. With the flag they passed 6/6.
The App Open tests themselves must run WITHOUT it.

```bash
flutter test integration_test/vip_redeem_flow_test.dart -d <device-id> \
  --dart-define=AD_PROVIDER_ADMOB=true --dart-define=SKIP_SPLASH_AD=true
```

Device VIP tests also need the phone ONLINE: `redeemSignedKey` refuses offline by design, so a phone that lost
Wi-Fi fails them with `invalid`.

## Notes

- This applies to a real device or emulator you run by hand. CI installs a fresh emulator each time.
- A test that passes once is not shown to be stable; the T279 investigation measured about 1 failure in
  20 consecutive runs of `round39` on one device when the data was not cleared.
