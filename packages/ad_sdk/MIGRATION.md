# Migration: 1.x → 2.x

The 2.0 release is **mostly source-compatible** with 1.x. Existing call
sites compile and behave the same; old methods that no longer fit the
2.x architecture are **deprecated, not removed** (will be removed in 3.0).

This guide covers the four practical migration tasks.

---

## 1. Update import (delete the duplicate barrel)

The 1.x package exposed two identical entry points; 2.x keeps only one.

```diff
- import 'package:applovin_admob_sdk/ad_sdk.dart';
+ import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
```

---

## 2. Logger configuration

```diff
- SafeLogger.setEnabled(true);
+ // Configured automatically via AdConfig.logLevel — no manual call needed.
```

If you want to keep the old "all-or-nothing" toggle, `setEnabled(...)` still
works (deprecated). For new code:

```dart
AdConfig(
  ...,
  logLevel: AdLogLevel.warning,
  logTagFilter: ['AdManager', 'AdSafety'],
  onLog: (lvl, tag, msg) => Sentry.captureMessage('[$tag] $msg'),
);
```

---

## 3. VIP API (the big one)

### 1.x

```dart
AdManager().addVIPMember(['gaid-1', 'gaid-2']);
final isVip = AdManager().isVIPMember();
```

### 2.x

```dart
// Programmatic — instant, permanent (50-year expiry):
AdManager().vip?.addVip(
  key: 'PURCHASED_PREMIUM',
  duration: const Duration(days: 365 * 50),
);

// Interactive — full Cupertino dialog flow:
final ok = await AdManager().vip?.redeemVip(
  context,
  key: userInputKey,
  duration: const Duration(days: 30),
  validator: AdManager().config?.vipKeyValidator,
  strings: AdManager().config?.vipDialogStrings,
);

// Same gate as before:
final isVip = AdManager().isVIPMember();
```

### Auto-migration

If your app shipped 1.x and the user has GAIDs in their 1.x VIP list, the
SDK auto-migrates them on **first launch under 2.x** to entries with
`expiresAt = year 2099` (effectively permanent — Q15A confirmed). No
action required from you.

### Key validator

`AdConfig.vipKeyValidator` is a `Future<bool> Function(String key)?`. Your
app provides the validation logic — usually a server call:

```dart
AdConfig(
  ...,
  vipKeyValidator: (key) async {
    final res = await dio.post('/api/vip/verify', data: {'key': key});
    return res.data['valid'] == true;
  },
);
```

If `null` (default), the redeem dialog accepts every key (demo mode).

---

## 4. Compliance flags

### 1.x

(none — caller had to set AppLovin flags directly through the
`applovin_max` package and AdMob through `MobileAds.instance`).

### 2.x

```dart
// After your UMP form / consent UI:
await AdManager().setConsent(AdConsent(
  hasUserConsent: userAcceptedGdpr,
  isAgeRestrictedUser: appTargetsKidsUnder13,
  doNotSell: userOptedOutCcpa,
));
```

The SDK forwards each flag to both providers correctly. Default =
`AdConsent.conservative` (no consent / no age restriction / no DNS opt-out).

---

## Optional: adopt new features

### `AdEvent` stream → analytics

```dart
AdManager().events.listen((event) {
  if (event is AdRevenueEvent) {
    FirebaseAnalytics.instance.logAdImpression(
      adPlatform: event.providerTag,
      value: event.value,
      currency: event.currencyCode,
    );
  }
});
```

### Per-placement tagging

```dart
showInterstitialAd(
  onDone: (_) {},
  placement: AdPlacement.shop,
);
```

### Debug overlay

Wrap your home screen during development:

```dart
Stack(children: [
  HomeScreen(),
  const DebugAdOverlay(),
])
```

### Revenue dashboard

```dart
const RevenuePanel(showDecimals: true)
```

---

## Breaking changes summary

None — all 1.x public methods still work. The deprecation warnings give
you a window until 3.0 to migrate at your own pace.

The internal architecture changed dramatically (adapter + state machine),
but only matters if you were reaching into private APIs (which you
shouldn't have been).
