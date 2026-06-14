import 'package:google_mobile_ads/google_mobile_ads.dart';

/// Lifecycle callbacks for a fullscreen show, expressed as plain Dart callbacks
/// so neither [AdMobAdapter] nor its tests depend on GMA's generic
/// `FullScreenContentCallback<T>` type.
class GmaShowCallbacks {
  const GmaShowCallbacks({
    this.onShowed,
    this.onDismissed,
    this.onFailedToShow,
    this.onClicked,
    this.onImpression,
    this.onUserEarnedReward,
  });

  final void Function()? onShowed;
  final void Function()? onDismissed;
  final void Function(String message)? onFailedToShow;
  final void Function()? onClicked;
  final void Function()? onImpression;

  /// Rewarded only — fires when the user earns the reward.
  final void Function(num amount, String type)? onUserEarnedReward;
}

/// A loaded GMA fullscreen ad (App Open / Interstitial / Rewarded), abstracted
/// behind plain methods so it can be faked in tests.
abstract class GmaFullscreenAd {
  /// Wires the lifecycle callbacks and shows the ad.
  Future<void> show(GmaShowCallbacks callbacks);

  /// Wires the paid-event (revenue) listener.
  void setPaidEventListener(
      void Function(num valueMicros, String currencyCode, String precision) cb);

  void dispose();
}

/// Seam over the static GMA loaders + `MobileAds.instance`. [AdMobAdapter] loads
/// every fullscreen ad through this interface; production uses [RealGmaBridge],
/// tests inject a fake that hands back a fake [GmaFullscreenAd].
abstract class GmaBridge {
  Future<void> initialize();
  Future<void> updateRequestConfiguration(List<String> testDeviceIds);

  Future<void> loadAppOpen(
    String adUnitId, {
    required void Function(GmaFullscreenAd ad) onLoaded,
    required void Function(int code, String message) onFailed,
  });
  Future<void> loadInterstitial(
    String adUnitId, {
    required void Function(GmaFullscreenAd ad) onLoaded,
    required void Function(int code, String message) onFailed,
  });
  Future<void> loadRewarded(
    String adUnitId, {
    required void Function(GmaFullscreenAd ad) onLoaded,
    required void Function(int code, String message) onFailed,
  });
}

/// Production bridge — forwards to the real `google_mobile_ads` plugin.
class RealGmaBridge implements GmaBridge {
  const RealGmaBridge();

  @override
  Future<void> initialize() async {
    await MobileAds.instance.initialize();
  }

  @override
  Future<void> updateRequestConfiguration(List<String> testDeviceIds) {
    return MobileAds.instance.updateRequestConfiguration(
      RequestConfiguration(testDeviceIds: testDeviceIds),
    );
  }

  @override
  Future<void> loadAppOpen(
    String adUnitId, {
    required void Function(GmaFullscreenAd ad) onLoaded,
    required void Function(int code, String message) onFailed,
  }) {
    return AppOpenAd.load(
      adUnitId: adUnitId,
      request: const AdRequest(),
      adLoadCallback: AppOpenAdLoadCallback(
        onAdLoaded: (ad) => onLoaded(_AppOpenWrap(ad)),
        onAdFailedToLoad: (err) => onFailed(err.code, err.message),
      ),
    );
  }

  @override
  Future<void> loadInterstitial(
    String adUnitId, {
    required void Function(GmaFullscreenAd ad) onLoaded,
    required void Function(int code, String message) onFailed,
  }) {
    return InterstitialAd.load(
      adUnitId: adUnitId,
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (ad) => onLoaded(_InterstitialWrap(ad)),
        onAdFailedToLoad: (err) => onFailed(err.code, err.message),
      ),
    );
  }

  @override
  Future<void> loadRewarded(
    String adUnitId, {
    required void Function(GmaFullscreenAd ad) onLoaded,
    required void Function(int code, String message) onFailed,
  }) {
    return RewardedAd.load(
      adUnitId: adUnitId,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (ad) => onLoaded(_RewardedWrap(ad)),
        onAdFailedToLoad: (err) => onFailed(err.code, err.message),
      ),
    );
  }
}

FullScreenContentCallback<T> _content<T extends Ad>(GmaShowCallbacks cb) {
  return FullScreenContentCallback<T>(
    onAdShowedFullScreenContent: (_) => cb.onShowed?.call(),
    onAdDismissedFullScreenContent: (_) => cb.onDismissed?.call(),
    onAdFailedToShowFullScreenContent: (_, err) =>
        cb.onFailedToShow?.call(err.message),
    onAdClicked: (_) => cb.onClicked?.call(),
    onAdImpression: (_) => cb.onImpression?.call(),
  );
}

class _AppOpenWrap implements GmaFullscreenAd {
  _AppOpenWrap(this._ad);
  final AppOpenAd _ad;

  @override
  Future<void> show(GmaShowCallbacks callbacks) {
    _ad.fullScreenContentCallback = _content<AppOpenAd>(callbacks);
    return _ad.show();
  }

  @override
  void setPaidEventListener(
      void Function(num, String, String) cb) {
    _ad.onPaidEvent = (ad, micros, precision, currency) =>
        cb(micros, currency, precision.name);
  }

  @override
  void dispose() {
    _ad.fullScreenContentCallback = null;
    _ad.dispose();
  }
}

class _InterstitialWrap implements GmaFullscreenAd {
  _InterstitialWrap(this._ad);
  final InterstitialAd _ad;

  @override
  Future<void> show(GmaShowCallbacks callbacks) {
    _ad.fullScreenContentCallback = _content<InterstitialAd>(callbacks);
    return _ad.show();
  }

  @override
  void setPaidEventListener(void Function(num, String, String) cb) {
    _ad.onPaidEvent = (ad, micros, precision, currency) =>
        cb(micros, currency, precision.name);
  }

  @override
  void dispose() {
    _ad.fullScreenContentCallback = null;
    _ad.dispose();
  }
}

class _RewardedWrap implements GmaFullscreenAd {
  _RewardedWrap(this._ad);
  final RewardedAd _ad;

  @override
  Future<void> show(GmaShowCallbacks callbacks) {
    _ad.fullScreenContentCallback = _content<RewardedAd>(callbacks);
    return _ad.show(
      onUserEarnedReward: (ad, reward) =>
          callbacks.onUserEarnedReward?.call(reward.amount, reward.type),
    );
  }

  @override
  void setPaidEventListener(void Function(num, String, String) cb) {
    _ad.onPaidEvent = (ad, micros, precision, currency) =>
        cb(micros, currency, precision.name);
  }

  @override
  void dispose() {
    _ad.fullScreenContentCallback = null;
    _ad.dispose();
  }
}
