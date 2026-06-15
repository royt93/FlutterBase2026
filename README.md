# _FlutterBase2025

Flutter app (Dart package **`saigonphantomlabs`**, display name "RoyApp") that ships
a **WiFi stress tester** and serves ads through an in-repo, dual-provider ad SDK
(**AppLovin MAX + Google AdMob**, Android + iOS).

> **Integrating the ad SDK into your own app?** Read
> **[`packages/ad_sdk/README.md`](packages/ad_sdk/README.md)** — that is the
> full, current integration contract. The old "copy the `AdMobManager` class"
> workflow that used to live here is **obsolete**; integration is now done by
> depending on the `applovin_admob_sdk` package and using its public API.

## Repository layout

| Path | What it is |
|---|---|
| `lib/` | The host app (`saigonphantomlabs`). Bootstrap in `lib/main.dart`, ad setup in `lib/mckimquyen/widget/splash/splash_screen.dart`. |
| `packages/ad_sdk/` | The **`applovin_admob_sdk`** package — the ad SDK, with its own README, example app and 225+ tests. |
| `doc/` | Project docs (see below). |
| `.github/workflows/test.yml` | CI: runs the SDK's `flutter analyze` + `flutter test`, plus host `flutter analyze`. |

## The ad SDK in one minute

- **Providers**: AppLovin MAX (active runtime, `AdProvider.appLovin`) and AdMob
  (swap-ready, `AdProvider.adMob`). Pick once in `AdConfig.provider`.
- **Init lives in `SplashScreen`, not `main()`** — `main()` only registers the
  navigator key + route observers before `runApp`. See `lib/main.dart`.
- **Consent / privacy**: iOS App Tracking Transparency via
  `AdManager().requestAtt()` (called in splash **before** UMP), Google UMP for
  EEA, plus COPPA/CCPA flags.
- **Per-platform ad unit IDs**: Android and iOS use **different** AppLovin units;
  `AdKey.appLovin` selects by `Platform.isIOS` (see
  `lib/mckimquyen/common/const/ad_keys.dart`).
- **VIP entitlement**: redeem keys / "watch a rewarded ad for VIP" suppress all
  ad surfaces while active. Rewards are granted **only** when a rewarded ad is
  actually completed (`earned == true`). VIP time **stacks globally** — every
  grant adds onto the latest expiry (clamped at ~90 days), and a VIP can keep
  watching real rewarded ads to extend their window (`bypassVipGuard`).
- **Built-in safety**: session/hourly/daily caps, throttle, CTR-fraud detection,
  progressive cooldown.

## Quick start

```bash
flutter pub get
flutter analyze
flutter run            # host app

# Ad SDK package (where the automated tests live):
cd packages/ad_sdk
flutter analyze
flutter test           # 225+ unit / widget / integration tests
```

## Native config (required for ads)

- **Android** (`android/app/src/main/AndroidManifest.xml`): `INTERNET`,
  `ACCESS_NETWORK_STATE`, `AD_ID` permissions + `com.google.android.gms.ads.APPLICATION_ID`
  meta-data. The AppLovin SDK key is passed at **runtime** via
  `AppLovinConfig.sdkKey` — `applovin_max` 4.x does **not** read it from a manifest
  `applovin.sdk.key` meta-data.
- **iOS** (`ios/Runner/Info.plist`): `GADApplicationIdentifier`, `AppLovinSdkKey`,
  `NSUserTrackingUsageDescription`, `SKAdNetworkItems`.

See the SDK README and `doc/AD.MD` for the exact values and rationale.

## Docs

| File | Purpose |
|---|---|
| [`packages/ad_sdk/README.md`](packages/ad_sdk/README.md) | **Ad SDK integration contract** (start here to integrate). |
| [`doc/AD_PROMPT_FLUTTER.MD`](doc/AD_PROMPT_FLUTTER.MD) | Partner hand-off prompt / step-by-step integration checklist. |
| [`doc/AD.MD`](doc/AD.MD) | As-is state of the ad integration in this repo (keys, native config, known risks). |
| [`doc/feature.md`](doc/feature.md) | Feature status (implemented / fixed / blockers). |
| `CLAUDE.md` | Repo conventions for AI-assisted development. |

## Known release blocker

🔴 The Google **UMP consent form is not yet configured** on the AdMob dashboard
for app ID `ca-app-pub-3612191981543807~9731053733`. The SDK degrades gracefully,
but EU/GDPR users will not see a consent form until a Funding Choices / UMP
message is published. Required before an EEA/UK release.
