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
  ///
  /// [ssvCustomData]/[ssvUserId] are Server-Side Verification (SSV)
  /// identifiers — rewarded-only. [_RewardedWrap] forwards them to the real
  /// `RewardedAd.setServerSideOptions(ServerSideVerificationOptions(...))`
  /// before showing; App Open/Interstitial wraps ignore both params (GMA has
  /// no SSV concept for those formats). Null/omitted preserves today's
  /// behavior exactly.
  Future<void> show(
    GmaShowCallbacks callbacks, {
    String? ssvCustomData,
    String? ssvUserId,
  });

  /// Wires the paid-event (revenue) listener.
  void setPaidEventListener(
      void Function(num valueMicros, String currencyCode, String precision) cb);

  /// Adapter class names from `ResponseInfo.adapterResponses`, winner last.
  /// Null until the ad's response info is available.
  List<String>? get mediationWaterfall;

  void dispose();
}

List<String>? _waterfallOf(Ad ad) =>
    ad.responseInfo?.adapterResponses?.map((r) => r.adapterClassName).toList();

/// Seam over the static GMA loaders + `MobileAds.instance`. [AdMobAdapter] loads
/// every fullscreen ad through this interface; production uses [RealGmaBridge],
/// tests inject a fake that hands back a fake [GmaFullscreenAd].
abstract class GmaBridge {
  Future<void> initialize();

  Future<void> updateRequestConfiguration(List<String> testDeviceIds);

  Future<void> loadAppOpen(
    String adUnitId, {
    required bool nonPersonalizedAds,
    bool restrictedDataProcessing = false,
    required void Function(GmaFullscreenAd ad) onLoaded,
    required void Function(int code, String message) onFailed,
  });

  Future<void> loadInterstitial(
    String adUnitId, {
    required bool nonPersonalizedAds,
    bool restrictedDataProcessing = false,
    required void Function(GmaFullscreenAd ad) onLoaded,
    required void Function(int code, String message) onFailed,
  });

  Future<void> loadRewarded(
    String adUnitId, {
    required bool nonPersonalizedAds,
    bool restrictedDataProcessing = false,
    required void Function(GmaFullscreenAd ad) onLoaded,
    required void Function(int code, String message) onFailed,
  });
}

/// CCPA restricted-data-processing signal, forwarded to AdMob per-request via
/// `AdRequest.extras`. AdMob's `RequestConfiguration` has no dedicated RDP
/// field — this `extras` key is Google's documented mechanism for opting a
/// request into limited ads / restricted data processing under CCPA.
const Map<String, String> _rdpExtras = {'rdp': '1'};

Map<String, String>? _extrasFor(bool restrictedDataProcessing) =>
    restrictedDataProcessing ? _rdpExtras : null;

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
    required bool nonPersonalizedAds,
    bool restrictedDataProcessing = false,
    required void Function(GmaFullscreenAd ad) onLoaded,
    required void Function(int code, String message) onFailed,
  }) {
    return AppOpenAd.load(
      adUnitId: adUnitId,
      request: AdRequest(
        nonPersonalizedAds: nonPersonalizedAds,
        extras: _extrasFor(restrictedDataProcessing),
      ),
      adLoadCallback: AppOpenAdLoadCallback(
        onAdLoaded: (ad) => onLoaded(_AppOpenWrap(ad)),
        onAdFailedToLoad: (err) => onFailed(err.code, err.message),
      ),
    );
  }

  @override
  Future<void> loadInterstitial(
    String adUnitId, {
    required bool nonPersonalizedAds,
    bool restrictedDataProcessing = false,
    required void Function(GmaFullscreenAd ad) onLoaded,
    required void Function(int code, String message) onFailed,
  }) {
    return InterstitialAd.load(
      adUnitId: adUnitId,
      request: AdRequest(
        nonPersonalizedAds: nonPersonalizedAds,
        extras: _extrasFor(restrictedDataProcessing),
      ),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (ad) => onLoaded(_InterstitialWrap(ad)),
        onAdFailedToLoad: (err) => onFailed(err.code, err.message),
      ),
    );
  }

  @override
  Future<void> loadRewarded(
    String adUnitId, {
    required bool nonPersonalizedAds,
    bool restrictedDataProcessing = false,
    required void Function(GmaFullscreenAd ad) onLoaded,
    required void Function(int code, String message) onFailed,
  }) {
    return RewardedAd.load(
      adUnitId: adUnitId,
      request: AdRequest(
        nonPersonalizedAds: nonPersonalizedAds,
        extras: _extrasFor(restrictedDataProcessing),
      ),
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
  Future<void> show(
    GmaShowCallbacks callbacks, {
    String? ssvCustomData,
    String? ssvUserId,
  }) {
    // ponytail: App Open has no SSV concept in GMA — params intentionally
    // unused here, kept only so the shared interface stays uniform.
    _ad.fullScreenContentCallback = _content<AppOpenAd>(callbacks);
    return _ad.show();
  }

  @override
  void setPaidEventListener(void Function(num, String, String) cb) {
    _ad.onPaidEvent = (ad, micros, precision, currency) =>
        cb(micros, currency, precision.name);
  }

  @override
  List<String>? get mediationWaterfall => _waterfallOf(_ad);

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
  Future<void> show(
    GmaShowCallbacks callbacks, {
    String? ssvCustomData,
    String? ssvUserId,
  }) {
    // ponytail: Interstitial has no SSV concept in GMA — same as App Open.
    _ad.fullScreenContentCallback = _content<InterstitialAd>(callbacks);
    return _ad.show();
  }

  @override
  void setPaidEventListener(void Function(num, String, String) cb) {
    _ad.onPaidEvent = (ad, micros, precision, currency) =>
        cb(micros, currency, precision.name);
  }

  @override
  List<String>? get mediationWaterfall => _waterfallOf(_ad);

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
  Future<void> show(
    GmaShowCallbacks callbacks, {
    String? ssvCustomData,
    String? ssvUserId,
  }) async {
    if (ssvCustomData != null || ssvUserId != null) {
      await _ad.setServerSideOptions(
        ServerSideVerificationOptions(
          userId: ssvUserId,
          customData: ssvCustomData,
        ),
      );
    }
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
  List<String>? get mediationWaterfall => _waterfallOf(_ad);

  @override
  void dispose() {
    _ad.fullScreenContentCallback = null;
    _ad.dispose();
  }
}
