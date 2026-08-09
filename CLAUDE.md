# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project context

- Flutter app whose Dart package name is **`saigonphantomlabs`** (so imports look like `package:saigonphantomlabs/mckimquyen/...`). The display name shown in `MaterialApp` is "RoyApp".
- The shipped feature is a **WiFi stress tester** (`lib/mckimquyen/widget/wifi_stressor/`) that hammers public CDN endpoints with parallel Dio downloads and charts throughput.
- Targets Android + iOS. Project version in `pubspec.yaml` doubles as the Play/App Store build (currently `2026.07.19+20260719`; the version string is date-based `YYYY.MM.DD+YYYYMMDD` — bump both halves together on release).
- Default UI locale is `vi_VN`, fallback is `en_US`. Translations live in `lib/translations/` and are persisted via `LanguageService` (SharedPreferences).

## Common commands

**Where the tests live:** three suites, all flat (no `unit/widget/integration` subfolders anywhere):

| Suite | Path | How to run |
|---|---|---|
| Ad SDK (primary gate) | `packages/ad_sdk/test/` — 67 files, ~675 tests | `cd packages/ad_sdk && flutter test` |
| Ad SDK on-device | `packages/ad_sdk/example/integration_test/` — 22 files (21 test suites + shared `scroll_helpers.dart`) | `cd packages/ad_sdk/example && flutter test integration_test/` (needs emulator/simulator; CI runs it on both) |
| Host app | `test/` at repo root — 16 files | `flutter test` from repo root |

Host `test/` is not just VIP any more: `wave1..wave5_*` cover the stressor's controllers/services/models/export, plus `vip_screen_widget_test.dart` and `wifi_stressor_screen_grace_nudge_test.dart`. `test_driver/integration_test.dart` exists but there is **no** host `integration_test/` directory. The `Makefile`'s `test*`/`coverage` targets still point at the non-existent `test/unit|widget|integration` layout — run `flutter test` directly instead.

```bash
# Install + generate mocks
flutter pub get
flutter packages pub run build_runner build --delete-conflicting-outputs

# Static analysis & formatting
flutter analyze
dart format .

# Run a single test file / a single test by name
flutter test test/wave2_export_test.dart
flutter test test/wave2_export_test.dart --plain-name "substring of the test name"

# Build
flutter build apk --debug          # Android dev build
flutter build apk --analyze-size   # size report

# Release (Makefile wraps these — the Makefile's release targets are real & current)
make release-aab                   # obfuscated AAB (+ split-debug-info to build/symbols — keep per release)
make release-size                  # AAB + size analysis report
# release-aab first runs check-admob-test-id: warns (does not block) if
# AdProvider.admob is active while native config still ships Google's test App ID.

# Clean rebuild
flutter clean && flutter pub get
```

**CI** (`.github/workflows/test.yml`) pins **Flutter 3.35.1 stable** and has **four** jobs:

- `sdk` — `flutter analyze` + `flutter test` in `packages/ad_sdk`. Primary gate.
- `sdk-integration` — the example app's `integration_test/` on an Android emulator. Needs KVM, disk cleanup and a 3GB swapfile on the runner (OOM-killer flake, see the inline comments before touching it). Forces `AD_PROVIDER_ADMOB` because no real AppLovin SDK key is committed, so the AppLovin path can never init in CI.
- `sdk-integration-ios` — same tests on an iOS Simulator (Xcode 26.1.1 + CocoaPods). Unlike the Android job this one runs **one `flutter test` invocation per file**: with all 18 passed to a single invocation, one flaky app launch on the CI simulator hung until the 12-minute per-test timeout, took the next file down with `Failed to start Dart Development Service`, and hid the other 16. Splitting is nearly free (`flutter test` already relaunches the app between files) and names the file that broke.
- `host` — `flutter analyze` + `flutter test` at the repo root.

It does **not** use `dart_code_metrics` or the old `test/unit|widget|integration` layout.

**Where the written history lives:** `doc/init.md` (project conventions — see the last section here), `doc/feature.md` + `doc/task/` (specs & completed task records), `doc/audit/` (numbered audit rounds — the ad SDK has been through 12; read the latest before re-litigating an SDK design decision), `doc/README_TESTING.md`, `doc/SPLASH_SETUP.md`, `doc/UMP_SETUP.md`.

## Architecture

### Bootstrap flow

`main()` in `lib/main.dart` does the following **in this order** (don't reorder — the SDK depends on it):

1. `WidgetsFlutterBinding.ensureInitialized()`.
2. `AdManager().setNavigatorKey(navigatorKey)` — must happen **before** `runApp` so the ad SDK can show loading dialogs from lifecycle callbacks.
3. `WakelockPlus.enable()` + `UIUtils.initEdgeToEdge()` + `FlutterDisplayMode.setHighRefreshRate()` on Android.
4. `Get.put(ControllerMain())` via `initializePlugin()`.
5. `LanguageService.getSavedLanguage()` to restore locale.
6. `runApp(GetMaterialApp(...))` with `navigatorKey`, `navigatorObservers: [adRouteObserver, AdScreenRouteLogger()]`, and `translations: AppTranslations()`.

`MyApp` immediately renders `SplashScreen`, which is where the ad SDK actually initializes (see "Ad SDK" below). Splash → `MainScreen` → `WiFiStressorApp` / `StressorHomePage`. From `WiFiStressorScreen` the user can push `VipScreen` (`lib/mckimquyen/widget/vip/`) to redeem a key and toggle the SDK's VIP state — see "VIP entitlement" below.

### Code layout under `lib/mckimquyen/`

This `mckimquyen/` namespace folder is where all app code lives. Subfolders are conceptual buckets, not enforced layers:

- `core/` — `BaseController extends GetxController`, `BaseStatefulState extends State` (with built-in alert dialog helpers and lifecycle logging via `SafeLogger`).
- `common/const/` — color/dimen/string/hero constants.
- `widget/` — screens grouped by feature (`splash/`, `main/`, `wifi_stressor/`).
- `widget/wifi_stressor/` is itself layered: `controllers/`, `models/` (Hive adapters generated by hand, not build_runner — see `network_info_adapter.dart`, `test_result_adapter.dart`), `services/`, `widgets/`, `presentation/`. The analysis surfaces built on top of the stressor live in `presentation/`: `network_dashboard_screen.dart` (connection details, public IP, packet-loss), `heatmap_screen.dart` (time-axis heatmap — each test row = a 24-cell downsampled speed strip, coloured red→amber→green vs the global peak), `comparison_screen.dart` (test-result diff with latency/jitter/DNS/upload metrics + export), plus `history_screen.dart` and `test_detail_screen.dart`. New analysis screens follow this same `presentation/` + `controllers/` + `models/` split.
- `util/`, `ext/`, `formatter/`, `lib/` — utilities and extensions. (Yes, there is a `lib/mckimquyen/lib/` directory; it holds shared scaffolding widgets — don't confuse it with the Dart package's `lib/` root.)

### State, routing, persistence

- **State**: GetX everywhere. Controllers extend `BaseController` (a thin `GetxController`). Screens extend `BaseStatefulState`. Per `doc/init.md`: do **not** use `setState`, `late`, or force-null (`!`); use GetX reactive vars instead. Use a project `AppSnackbar` (not `Get.snack`).
- **Routing**: `GetMaterialApp` with `Transition.cupertino` and a 700ms transition duration. Use `Get.to/off/back`. Two `NavigatorObserver`s come from the ad SDK and are required for banner pause/resume.
- **Persistence**: Hive (test history, key `test_history`, capped at 100 items via `TestHistoryStorage` singleton in `services/test_history_storage.dart`) + SharedPreferences (language, simple flags via `shared_preferences_util.dart`).
- **Network**: Dio is used by the stressor for parallel downloads. `connectivity_plus` and `network_info_plus` provide signal/SSID info via `NetworkInfoService`.

### Ad SDK (this is the part most likely to bite you)

The `applovin_admob_sdk` package is **dual-sourced**:

- A local copy lives in `packages/ad_sdk/` (it is its own Flutter package with its own example app, README, tests).
- The app currently consumes the **hosted `applovin_admob_sdk: ^1.2.4` from pub.dev** (active in `pubspec.yaml`; the local `path: packages/ad_sdk` override is commented out right below it). The local copy is kept in sync at `1.2.4` for dev/test. To ship SDK changes that haven't been published yet, uncomment the path override (and comment out the hosted line), then re-publish the bumped SDK version and flip the two lines back before a release.
- **Publishing the SDK to pub.dev has two traps `--dry-run` does not catch** (it reported "0 warnings" right before both failures): the upload API rejects any `screenshots:` description over **200** characters, and pana/pub.dev scoring separately wants the package `description` **and** every screenshot description under **160** characters or it silently drops 10 points each from "valid pubspec.yaml" and "example and screenshots". Also expect `flutter pub get` to keep reporting `doesn't match any versions` for a minute or two after a successful upload — the pub.dev API already serves the new version while the CDN edge still caches the old listing. Just retry; `pub cache clean` is unrelated.
- `gma_mediation_applovin` must stay at the app level — it's a native mediation plugin and cannot be declared inside the sub-package. It is **pinned to `2.5.2` in `dependency_overrides`**, alongside `applovin_max: 4.6.0`. Two separate walls, easy to confuse:
  - **Dart level:** `gma_mediation_applovin >=2.6.0` needs `meta ^1.17.0` while `flutter_test` from the CI-pinned Flutter 3.35.1 forces `meta 1.16.0`. And `google_mobile_ads` **8 and 9** need Dart `>=3.10.0` + Flutter `>=3.38.1`, which 3.35.1 (Dart 3.9.x) cannot satisfy — so the last 10 pub.dev points are gated on a Flutter upgrade, which would also raise the SDK's own `environment` floor and so be breaking for consumers.
  - **CocoaPods level:** `applovin_max 4.6.4` requires `AppLovinSDK (= 13.6.3)`, but `gma_mediation_applovin 2.5.2` → `GoogleMobileAdsMediationAppLovin (~> 13.5.0.0)` → `AppLovinSDK (= 13.5.0)`. Both pin exact versions, so `pod install` cannot resolve them together — that is why `applovin_max` stays overridden to `4.6.0` even though the SDK declares `^4.6.4`.
  - Verify any change here with `flutter pub get` **and** `cd ios && pod install` **and** a real `flutter build apk` / `flutter build ios --simulator`: `pub get` succeeding proves nothing about the pod graph.
- **`android/gradle.properties` hardcodes `org.gradle.java.home` to a specific machine's JDK path** (`/Users/loitran/.../openjdk-20.0.1`). Any other machine fails every Android build with "Java home supplied is invalid" until that line is repointed or removed. It is checked in, so fixing it is a real change, not a local tweak.

The integration contract (see `packages/ad_sdk/README.md` for the full version):

1. Set `AdManager().setNavigatorKey(navigatorKey)` before `runApp`.
2. Add `adRouteObserver` and `AdScreenRouteLogger()` to `navigatorObservers`.
3. **Initialize the SDK inside `SplashScreen`, not in `main()`** — the SDK's `SimpleEventBus` only delivers init-completion events to listeners that registered before init started, and Splash is the first screen that can do that safely.
4. `SplashScreen` already implements the required pattern: hard-cap timer (8s), `AdManager().markSplashActive/Inactive()`, `incrementSplashCount()`, and `AdLoadingDialog.showAdBuffer()` before `showAppOpenAd(bypassSafety: true)`. If you touch this file, preserve the cancellation order: cancel the hard-cap timer **before** `showAppOpenAd`, and always call `markSplashInactive()` exactly once on navigation away.
5. Any screen that displays ads should extend `AdScreen` + `AdScreenState` (instead of `StatefulWidget`/`State`) so it gets `buildBanner()`, `showInterstitialAd()`, and `showRewardedAd()`. RouteAware banner lifecycle is automatic when `adRouteObserver` is registered.
6. The SDK has a built-in safety layer (daily/hourly/session caps, 30s throttle, CTR fraud, progressive cooldown). Don't try to bypass it except on the splash App Open ad (`bypassSafety: true`).
7. App Open never stacks on top of a modal — `showAppOpenAdOnResume` checks `AdScreenRouteLogger.isDialogOnTop` and skips while a dialog is showing. The SDK's `_retryRefillAds` also returns early while a VIP entry is active so it doesn't reload suppressed slots.

### VIP entitlement

The SDK exposes a `VipManager` reachable as `AdManager().vip` (nullable until SDK init completes). When a VIP entry is active, the SDK suppresses all ad surfaces — `AdScreen.buildBanner()`, interstitials, rewarded — automatically. Reactive UI subscribes to `AdManager().vip!.activeListenable` (see `wifi_stressor_screen.dart:162`).

VIP grants **stack globally** — `addVip`/`redeemVip` with `stack: true` add onto the latest expiry across all active entries (clamped at `AdConfig.maxVipStackDuration`, ~90 days). A VIP can also voluntarily watch a real rewarded ad to extend their window: the watch-ad flow passes `bypassVipGuard: true` to `showRewardedAd` so the (normally VIP-suppressed) rewarded surface still plays and grants more time.

- `lib/mckimquyen/widget/vip/vip_screen.dart` is a thin `StatelessWidget` wrapper (T18) around the SDK's shared `VipRedeemScreen` — the host only injects localized strings, the signing public key, and the privacy-policy launcher; the redeem UI itself lives in the SDK so host + SDK example render an identical screen.
- `lib/mckimquyen/widget/vip/vip_keys.dart` holds `kVipPublicKeyBase64` (an Ed25519 public key) plus demo signed keys. Keys are **Ed25519-signed and verified offline** — only the public key ships in the app, so decompiling the binary does not let anyone forge new valid keys. Mint new keys with the matching private key via `packages/ad_sdk/tool/vip_mint.dart` (never commit the private key). Redemption goes through `VipManager.redeemSignedKey(...)`, not a lookup table.
- The Privacy Policy URL `https://loitp.notion.site/Term-Privacy-Policy-Disclaimer-...` is wired into this screen and is the canonical place to update legal links.

### Native config gotchas

- `android/app/src/main/AndroidManifest.xml` must contain `com.google.android.gms.ads.APPLICATION_ID` meta-data and the `com.google.android.gms.permission.AD_ID` + `INTERNET` + `ACCESS_NETWORK_STATE` permissions. AppLovin also needs `applovin.sdk.key` meta-data.
- iOS requires `GADApplicationIdentifier`, `NSUserTrackingUsageDescription`, `AppLovinSdkKey`, and `SKAdNetworkItems` in `ios/Runner/Info.plist`. Podfile targets iOS 13.0.
- Android `minSdk` 24, `compileSdk`/`targetSdk` 36.
- Launcher icons are generated by `flutter_launcher_icons` (config in `pubspec.yaml`); splash by `flutter_native_splash` (`flutter_native_splash.yaml`).

### Store-assets screenshot editor (separate Node/Next.js sub-project)

`store-assets/` is **not** part of the Flutter build — it's a standalone **Next.js + ShadCN** app (scaffolded by the `app-store-screenshots` skill) for generating App Store / Play Store marketing screenshots. It has its own toolchain: `cd store-assets && bun install && bun dev` (serves on `http://localhost:3000`; `bun`/`bun.lock` is the checked-in package manager, npm/pnpm also work).

- Project state persists to **`store-assets/app-store-screenshots.json`** (auto-saved ~600ms via `/api/project`, mirrored to `localStorage`). This file **is** git-tracked — commit it to move work between machines.
- Uploaded source screenshots land in `store-assets/public/screenshots/uploaded/<hash>.png` via `/api/upload`.
- Ignore `store-assets/` when doing anything Flutter-related; don't run `flutter`/`dart` inside it.

## Project conventions (from `doc/init.md`)

- Prefer GetX reactive state over `setState`/`late`/`!`. Use `AppSnackbar`, not `Get.snack`.
- Khi cần thêm input formatter mới, mirror pattern trong `lib/mckimquyen/formatter/` (ví dụ `date_text_formatter.dart`). App hiện tại không có currency input nào.
- New screens should match existing animation cadence so transitions feel uniform.
- The `dependency_overrides: vector_math: ^2.2.0` line exists for a reason — don't remove it without checking whether a transitive dep regressed.
