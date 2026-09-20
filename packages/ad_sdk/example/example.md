# applovin_admob_sdk example

<!--
pub.dev's Example tab picks the first file it finds in this priority order:
example/example.md > example/lib/main.dart > ... > example/README.md.
This file exists ONLY so pub.dev shows a readable walkthrough here instead of
main.dart's raw source (which is ~5000 lines, one page per feature, and full
of internal shorthand that means nothing outside this repo). If you're
reading this in the repo itself, `example/README.md` has the same content —
edit both together.
-->

One page per SDK feature, launched from the home list. Run with:

```bash
cd example
flutter run
```

## Quickstart

```dart
// Before runApp():
AdManager().setNavigatorKey(navigatorKey);

runApp(MaterialApp(
  navigatorKey: navigatorKey,
  navigatorObservers: [adRouteObserver, AdScreenRouteLogger()],
  home: const SplashScreen(),
));

// Inside SplashScreen, before the first ad request:
await AdManager().requestAtt();          // iOS only, no-op on Android
await AdManager().requestUmpConsent();
AdManager().initialize(config: myConfig, onComplete: (success, gaid) {});

// Any screen that shows ads extends AdScreen/AdScreenState instead of
// StatefulWidget/State, then just:
buildBanner();
```

See the "Banner ad" and "Consent / GDPR" demo pages for the full working
version of this, and the package [`README.md`](https://pub.dev/packages/applovin_admob_sdk)
for `myConfig` and the rest of the integration contract.

| Page | Demonstrates |
|---|---|
| Banner ad | Anchored adaptive banner, route-aware pause/resume lifecycle |
| MREC ad | Fixed 300x250 rectangle route lifecycle |
| Native ad | AdMob template ad vs AppLovin custom native layout |
| Interstitial ad | `showInterstitialAd`, safety gate, show counter |
| Rewarded ad | `showRewardedAd`, earned-reward callback, VIP auto-grant toggle |
| Rewarded Interstitial ad | `showRewardedInterstitialAd`, built-in disclosure screen (AdMob-only surface) |
| App-open ad | Background → foreground resume trigger |
| VIP / redeem | The shared `VipRedeemScreen` — identical widget used by the host app |
| VIP API playground | Raw `redeemVip` / signed-key redeem / watch-ad buttons for manual testing |
| Consent / GDPR | Consent flags and how they propagate to both ad providers |
| Safety status | Live safety caps, throttle, dry-run mode, `AdSafetyParams` presets |
| Log viewer | Ring buffer of internal SDK logs |
| Revenue dashboard | Running total from the `onPaidEvent` stream |
| Slot state panel | Live `AdSlot` state per surface, manual destroy/reinit |
| AdEvent stream | Every load/show/click/reward/revenue event, live |
| Compliance report | Export of the event log + safety + consent snapshot, for handing to a partner or reviewer |
| Diagnostics & self-check | Built-in integration self-check report |

Each page is self-contained — clone this repo and open the one for the
feature you're integrating (`example/lib/main.dart`), not the whole file.
For API details and setup steps, see the
[package README](https://pub.dev/packages/applovin_admob_sdk).
