# applovin_admob_sdk example

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
await AdManager().requestUmpConsent();
AdManager().initialize(config: myConfig, onComplete: (success, gaid) {});

// Any screen that shows ads extends AdScreen/AdScreenState instead of
// StatefulWidget/State, then just:
buildBanner();
```

See the "Banner ad" and "Consent / GDPR" demo pages for the full working
version of this, and the package [`README.md`](../README.md) for `myConfig`
and the rest of the integration contract.

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
| Compliance report | Export event log + safety + consent snapshot (T23) |
| Diagnostics & self-check | Built-in integration self-check report |

Each page is self-contained — read the one for the feature you're integrating, not the whole file. Automated coverage for each page lives in `integration_test/` (one file per page, run on a real device/emulator/simulator — see the repo root `README.md`'s CI section).

For API details and setup steps, see the package [`README.md`](../README.md).
