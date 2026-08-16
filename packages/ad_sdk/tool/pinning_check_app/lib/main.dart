// T85 — not a real app, never run. Its only job is existing so
// `flutter pub get` + `pod install` in ios/ can prove the pinning combo
// documented in pubspec.yaml still resolves. Referencing the package here
// (rather than just declaring it in pubspec.yaml) keeps `flutter analyze`
// honest that the dependency is actually used.
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

// ignore: unused_element
AdConfig _unused() => const AdConfig(
      provider: AdProvider.admob,
      admob: AdMobConfig(
        bannerId: 'x',
        interstitialId: 'x',
        appOpenId: 'x',
        rewardedId: 'x',
      ),
    );
