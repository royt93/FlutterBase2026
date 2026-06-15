# Ad SDK Audit - current app state

Updated: 2026-06-15

## Current integration

| Item | Current value |
|---|---|
| Runtime SDK | `applovin_admob_sdk: ^1.0.23` (hosted on pub.dev) |
| Runtime provider | `AdProvider.appLovin` |
| Native mediation plugin | `gma_mediation_applovin` at app level |
| AppLovin MAX SDK override | `applovin_max: 4.6.0` |
| iOS deployment target | 13.0 |
| Bundle/package id | `com.saigonphantomlabs.base` |
| iOS signing team seen during Roy phone deploy | `8CU2Y3DBS5` |

`1.0.19` added iOS App Tracking Transparency (`requestAtt()`) and the iOS App
Open watchdog fix over `1.0.18`. The latest published release is **`1.0.23`**;
the previous published release was `1.0.20`. Versions `1.0.21` and `1.0.22` have
CHANGELOG entries but were never published to pub.dev (dev-only), so pub.dev
jumps straight from `1.0.20` to `1.0.23`. The app consumes the hosted `^1.0.23`
from pub.dev — the local `path` override has been commented out.

## Root cause found on iOS

The Flutter/Dart ad bootstrap was present, but `ios/Runner/Info.plist` did not contain the native ad keys required by the iOS SDKs:

- `GADApplicationIdentifier`
- `AppLovinSdkKey`
- `NSUserTrackingUsageDescription`
- `SKAdNetworkItems`

Android worked because `android/app/src/main/AndroidManifest.xml` already had `com.google.android.gms.ads.APPLICATION_ID`, app permissions, and backup config. iOS was missing the equivalent native configuration, so AppLovin/AdMob could initialize incorrectly or fail to serve/load ads.

Fix applied:

- Added `GADApplicationIdentifier = ca-app-pub-3612191981543807~9731053733`.
- Added `AppLovinSdkKey` matching `lib/mckimquyen/common/const/ad_keys.dart`.
- Added ATT usage description text.
- Added the Google AdMob iOS SKAdNetwork identifiers from the official AdMob iOS privacy guide, last updated 2026-06-12. Google notes that mediation partners can require extra identifiers, so recheck AppLovin/AdMob docs before production release.

## Bootstrap contract

`lib/main.dart`:

- Calls `WidgetsFlutterBinding.ensureInitialized()`.
- Calls `AdManager().setNavigatorKey(navigatorKey)` before `runApp`.
- Registers both `adRouteObserver` and `AdScreenRouteLogger()` in `GetMaterialApp.navigatorObservers`.
- Initializes project services, locale, wakelock, and high refresh mode.

`lib/mckimquyen/widget/splash/splash_screen.dart`:

- Calls `markSplashActive()` and `incrementSplashCount()`.
- Uses `countInitSplashScreen > 1` hot-restart guard.
- Uses an 8-second hard cap to prevent splash from hanging forever.
- Subscribes to `SimpleEventBus` before `AdManager().initialize`.
- Calls `AdManager().requestAtt()` (iOS ATT, no-op on Android) before `requestUmpConsent`.
- Calls `requestUmpConsent(testMode: false)` before first ad request.
- Initializes with `provider: AdProvider.appLovin`, `appLovin: AdKey.appLovin`, and `admob: AdKey.adMob`.
- Loads App Open ad after SDK init, shows `AdLoadingDialog.showAdBuffer`, then calls `showAppOpenAd(bypassSafety: true)`.
- Removes the event listener and cancels timers on navigation/dispose.

## Active ad surfaces

| Surface | File | Trigger | SDK API |
|---|---|---|---|
| App Open cold start | `widget/splash/splash_screen.dart` | SDK init event on first splash | `loadAppOpenAd` + `showAppOpenAd(bypassSafety: true)` |
| App Open resume | SDK internal | app foreground lifecycle | SDK observer (`showAppOpenAdOnResume`) |
| Banner | `widget/wifi_stressor/wifi_stressor_screen.dart` | screen build | `buildBanner()` |
| Banner | `widget/wifi_stressor/presentation/history_screen.dart` | screen build | `buildBanner()` |
| Interstitial | `widget/wifi_stressor/wifi_stressor_screen.dart` | navigation/start/stop flows | `showInterstitialAd()` |
| Rewarded | `widget/wifi_stressor/presentation/history_screen.dart` | clear/export action | `showRewardedAd()` |
| Rewarded VIP | `widget/vip/vip_screen.dart` | watch-ad VIP CTA (visible even while VIP) | `showRewardedAd(bypassVipGuard: true)` → `addVip(key: 'REWARDED_VIP', stack: true)` |

### VIP time stacking (2026-06-15)

VIP time now **accumulates** instead of resetting. Both the key-redeem flow
(`redeemVip(..., stack: true)`) and the watch-ad flow (`addVip(key: 'REWARDED_VIP',
duration: 3d, stack: true)`) add onto the current window. The watch-ad CTA stays
visible while VIP so a member can extend by watching a real rewarded ad
(`bypassVipGuard: true` — the SDK loads the slot on demand; no auto-grant). This
required SDK changes that landed in the published `1.0.23` release, now consumed
via the hosted `^1.0.23` (the in-repo `path` override is no longer used).
Total stacked window is **capped at 90 days** via `AdConfig.maxVipStackDuration`
(set in `splash_screen.dart`). `showRewardedAd` is re-entrancy-safe and shows a
loading dialog during the on-demand load (`onDemandLoadTimeout` 15 s).
See `doc/AD_PROMPT_FLUTTER.MD` §4.7 + Step 10.3 and the SDK README "VIP system".

## Ad keys

Source: `lib/mckimquyen/common/const/ad_keys.dart`.

| Type | Value |
|---|---|
| AppLovin SDK key | `REDACTED_APPLOVIN_SDK_KEY_ROUND68` |
| AppLovin Android banner | `REDACTED_APPLOVIN_BANNER_ID` |
| AppLovin Android interstitial | `REDACTED_APPLOVIN_INTERSTITIAL_ID` |
| AppLovin Android app open | `REDACTED_APPLOVIN_APPOPEN_ID` |
| AppLovin Android rewarded | `REDACTED_APPLOVIN_REWARDED_ID` |
| AppLovin iOS banner | `REDACTED_APPLOVIN_IOS_BANNER_ID` |
| AppLovin iOS interstitial | `REDACTED_APPLOVIN_IOS_INTERSTITIAL_ID` |
| AppLovin iOS app open | `REDACTED_APPLOVIN_IOS_APPOPEN_ID` |
| AppLovin iOS rewarded | `REDACTED_APPLOVIN_IOS_REWARDED_ID` |
| AdMob app id | `ca-app-pub-3612191981543807~9731053733` |
| AdMob ad units | Google public test units, unused while provider is AppLovin |

## Verification checklist

Run after native config changes:

1. `plutil -lint ios/Runner/Info.plist`
2. `flutter analyze`
3. `flutter build ios --debug --no-codesign`
4. On Roy's Phone, uninstall old builds signed by another team if iOS reports `MismatchedApplicationIdentifierEntitlement`.
5. `flutter run -d 00008140-001819AC2286801C --debug`
6. Watch logs for `AdManager init complete`, AppLovin init success, and App Open load/show result.

If the app stays on splash after this fix, capture device logs filtered by `Splash`, `AdManager`, `AppLovin`, `GAD`, and `GoogleMobileAds`; do not infer from UI alone.

## Roy's Phone deploy notes - 2026-06-14

First deploy attempt failed before launch because the phone already had
`com.saigonphantomlabs.base` signed by team `F7MXY39NH7`, while the current
Xcode project signs with team `8CU2Y3DBS5`. The old app was uninstalled.

After adding iOS native ad config, `flutter build ios --debug --no-codesign`
passes. A subsequent `flutter run -d 00008140-001819AC2286801C --debug`
still hung for 202 seconds in `devicectl device install app`, before Flutter
logs or app runtime logs started. `xcrun devicectl list devices` still showed
Roy's Phone as `connected`.

Conclusion for this run: the remaining hang is in CoreDevice install/launch,
not in Dart splash/ad SDK runtime. Next device-side steps are to unlock the
phone, keep it trusted, manually delete any partially installed `Base` app,
then retry install. If it still hangs, restart `CoreDevice`/Xcode or reboot the
phone before collecting app runtime logs.

Second deploy with app-level trace succeeded. The app installed, launched, and
navigated through splash into `WiFiStressorApp`. Runtime timing from logs:

- Xcode build: 22.4s.
- Install/launch: 27.4s.
- `AdManager.initialize` completed at about 9.1s after Flutter process start.
- Splash navigated to main immediately because debug first-install VIP grace
  was active, so App Open was intentionally skipped.

After the 30s debug VIP grace expired, AppLovin attempted to preload all slots
and iOS returned `ErrorCode.invalidAdUnitId` for the previous app-open,
interstitial, rewarded, and banner IDs. This confirmed the native iOS config is
present and the SDK is reaching AppLovin. The app now keeps separate AppLovin
configs per platform: Android continues using the previously working Android
unit IDs, while iOS uses the AppLovin MAX units for `com.saigonphantomlabs.base`:
app-open `REDACTED_APPLOVIN_IOS_APPOPEN_ID`, banner `REDACTED_APPLOVIN_IOS_BANNER_ID`, interstitial
`REDACTED_APPLOVIN_IOS_INTERSTITIAL_ID`, rewarded `REDACTED_APPLOVIN_IOS_REWARDED_ID`.

## SDK 1.0.23 behaviour

- **App Open no longer stacks on top of a modal.** `AdScreenRouteLogger` now
  counts open `PopupRoute`s and exposes `isDialogOnTop`; `showAppOpenAdOnResume`
  checks `isDialogOnTop` plus `AdLoadingDialog.isShowing` before showing, so the
  resume App Open ad will not appear over a dialog/loading buffer.
- **`_retryRefillAds` returns early when the user is VIP** — no slot preloading
  is attempted while a VIP entry is active.

## Known risks

- AppLovin mediation may require additional SKAdNetwork identifiers beyond Google's published buyer list. Recheck official AppLovin MAX iOS docs before App Store release.
- iOS ATT is wired: `SplashScreen` calls `AdManager().requestAtt()` (SDK 1.0.19+) before `requestUmpConsent`, and `NSUserTrackingUsageDescription` is present in `Info.plist`. Verified on device (returned `authorized` with IDFA). ATT is decoupled from the GDPR consent flag by design — the native AppLovin/AdMob SDKs read ATT directly for IDFA.
- `main.dart` wraps `SplashScreen` in a nested `MaterialApp` inside `GetMaterialApp`. This has not blocked Android ads, but it can complicate navigator context behavior. Keep an eye on SDK dialogs if iOS still behaves differently.
