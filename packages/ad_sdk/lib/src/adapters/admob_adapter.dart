import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../config/ad_config.dart';
import '../core/ad_consent.dart';
import '../core/ad_provider_adapter.dart';
import '../core/ad_safety_config.dart';
import '../state/ad_event.dart';
import '../state/ad_placement.dart';
import '../state/ad_slot.dart';
import '../utils/safe_logger.dart';
import 'gma_bridge.dart';

/// AdMob (Google Mobile Ads) implementation of [AdProviderAdapter].
///
/// Owns the 4 ad-unit objects (`AppOpenAd`, `InterstitialAd`, `RewardedAd`,
/// `BannerAd`) and their state machines. All callbacks go through [AdSlot]
/// transitions instead of hand-managed bool flags. The fullscreen ads load
/// through an injectable [GmaBridge]; the banner stays on the native GMA API
/// (it is `AdWidget`-coupled and not behaviourally testable in isolation).
class AdMobAdapter implements AdProviderAdapter {
  /// [bridge] defaults to the real GMA plugin; tests inject a fake.
  AdMobAdapter({GmaBridge bridge = const RealGmaBridge()}) : _bridge = bridge;

  final GmaBridge _bridge;

  @override
  String get tag => '[AdMob]';

  static const String _logTag = 'AdMobAdapter';

  // ignore: unused_field
  AdConfig? _config;
  AdMobConfig? _admob;

  /// Whether the next ad request must be non-personalized (`npa=1`).
  ///
  /// Defaults to `true` (conservative — no personalized ads) so that any load
  /// firing before consent is applied is safe. [applyConsent] flips it to
  /// `!hasUserConsent` on every consent change.
  ///
  /// NOTE: when Google UMP manages consent (T01), the TCF consent string
  /// governs personalization natively; this per-request flag is the source of
  /// truth for the non-UMP path (custom dialog / [AdManager.setConsent]).
  bool _nonPersonalizedAds = true;

  /// CCPA "do not sell" signal (`doNotSell`), forwarded to AdMob per-request as
  /// restricted-data-processing (RDP) via `AdRequest.extras`. AdMob has no
  /// dedicated RDP field on `RequestConfiguration` — the `{'rdp': '1'}` extra
  /// is Google's documented per-request mechanism. See [AdConsent] doc for why
  /// this must stay independent from `tagForUnderAgeOfConsent` (TFUA).
  bool _restrictedDataProcessing = false;

  /// Test-only view of the current non-personalized flag.
  @visibleForTesting
  bool get debugNonPersonalizedAds => _nonPersonalizedAds;

  /// Test-only view of the current RDP flag.
  @visibleForTesting
  bool get debugRestrictedDataProcessing => _restrictedDataProcessing;

  @override
  AdEventSink? eventSink;

  // ponytail: AdMobAdapter has no adapter-internal auto-reload path (unlike
  // AppLovinAdapter's dismiss/fail callbacks), so this gate is never
  // consulted here — kept only to satisfy AdProviderAdapter.
  @override
  bool Function() canReload = () => true;

  void _emit(AdEvent e) => eventSink?.call(e);

  /// Wires the fullscreen ad's paid-event (revenue) listener through the bridge.
  void _wirePaidEvent(
      GmaFullscreenAd ad, AdSlotType type, AdPlacement placement) {
    ad.setPaidEventListener((valueMicros, currencyCode, precision) {
      _emit(AdRevenueEvent(
        providerTag: tag,
        type: type,
        placement: placement,
        valueMicros: valueMicros.toInt(),
        currencyCode: currencyCode,
        precision: precision,
        mediationWaterfall: ad.mediationWaterfall,
      ));
    });
  }

  /// Constructor-time paid-event callback for banner — used in
  /// [BannerAdListener] since [BannerAd] inherits from [AdWithView] which
  /// doesn't expose `onPaidEvent` as a setter.
  OnPaidEventCallback _paidEventForBanner(AdPlacement placement) => (Ad ad,
          double valueMicros, PrecisionType precision, String currencyCode) {
        _emit(AdRevenueEvent(
          providerTag: tag,
          type: AdSlotType.banner,
          placement: placement,
          valueMicros: valueMicros.toInt(),
          currencyCode: currencyCode,
          precision: precision.name,
          mediationWaterfall: ad.responseInfo?.adapterResponses
              ?.map((r) => r.adapterClassName)
              .toList(),
        ));
      };

  /// Same as [_paidEventForBanner] but tags events [AdSlotType.mrec].
  OnPaidEventCallback _paidEventForMrec(AdPlacement placement) => (Ad ad,
          double valueMicros, PrecisionType precision, String currencyCode) {
        _emit(AdRevenueEvent(
          providerTag: tag,
          type: AdSlotType.mrec,
          placement: placement,
          valueMicros: valueMicros.toInt(),
          currencyCode: currencyCode,
          precision: precision.name,
          mediationWaterfall: ad.responseInfo?.adapterResponses
              ?.map((r) => r.adapterClassName)
              .toList(),
        ));
      };

  /// Same as [_paidEventForBanner] but tags events [AdSlotType.native].
  OnPaidEventCallback _paidEventForNative(AdPlacement placement) => (Ad ad,
          double valueMicros, PrecisionType precision, String currencyCode) {
        _emit(AdRevenueEvent(
          providerTag: tag,
          type: AdSlotType.native,
          placement: placement,
          valueMicros: valueMicros.toInt(),
          currencyCode: currencyCode,
          precision: precision.name,
          mediationWaterfall: ad.responseInfo?.adapterResponses
              ?.map((r) => r.adapterClassName)
              .toList(),
        ));
      };

  @override
  bool get isInitialised => _admob != null;

  // ─── Slots ────────────────────────────────────────────────────────────────

  @override
  final AdSlot appOpenSlot = AdSlot(type: AdSlotType.appOpen);
  @override
  final AdSlot interstitialSlot = AdSlot(type: AdSlotType.interstitial);
  @override
  final AdSlot rewardedSlot = AdSlot(type: AdSlotType.rewarded);
  // T65 (phase 2) — one AdSlot/BannerListenables per BannerAdWidget instance,
  // same pattern as native (phase 1). See disposeBannerInstance/bannerSlot().
  final Map<Object, AdSlot> _bannerSlotsByKey = {};
  final Map<Object, BannerListenables> _bannerListenablesByKey = {};
  bool _bannerDisposed = false;
  AdSlot? _disposedBannerSlot;
  BannerListenables? _disposedBannerListenables;

  AdSlot _bannerSlotFor(Object key) {
    if (_bannerDisposed) {
      return _disposedBannerSlot ??=
          (AdSlot(type: AdSlotType.banner)..dispose());
    }
    return _bannerSlotsByKey.putIfAbsent(
        key, () => AdSlot(type: AdSlotType.banner));
  }

  BannerListenables _bannerListenablesFor(Object key) {
    if (_bannerDisposed) {
      return _disposedBannerListenables ??= (BannerListenables(
        isLoaded: ValueNotifier<bool>(false),
        hasError: ValueNotifier<bool>(false),
        adSize: ValueNotifier<Size?>(null),
        autoRefreshEnabled: ValueNotifier<bool>(true),
        visible: ValueNotifier<bool>(true),
      )..dispose());
    }
    return _bannerListenablesByKey.putIfAbsent(
        key,
        () => BannerListenables(
              isLoaded: ValueNotifier<bool>(false),
              hasError: ValueNotifier<bool>(false),
              adSize: ValueNotifier<Size?>(null),
              autoRefreshEnabled: ValueNotifier<bool>(true),
              visible: ValueNotifier<bool>(true),
            ));
  }

  @override
  AdSlot bannerSlot(Object key) => _bannerSlotFor(key);

  @override
  Iterable<AdSlot> get bannerSlots => _bannerSlotsByKey.values;

  @override
  BannerListenables banner(Object key) => _bannerListenablesFor(key);

  @override
  void disposeBannerInstance(Object key) {
    _bannerAdsByKey.remove(key)?.dispose();
    _bannerSlotsByKey.remove(key)?.dispose();
    _bannerListenablesByKey.remove(key)?.dispose();
    _bannerRoutePausedByKey.remove(key);
  }

  // T65 (phase 3) — one AdSlot/BannerListenables per MrecAdWidget instance,
  // same pattern as banner (phase 2).
  final Map<Object, AdSlot> _mrecSlotsByKey = {};
  final Map<Object, BannerListenables> _mrecListenablesByKey = {};
  bool _mrecDisposed = false;
  AdSlot? _disposedMrecSlot;
  BannerListenables? _disposedMrecListenables;

  AdSlot _mrecSlotFor(Object key) {
    if (_mrecDisposed) {
      return _disposedMrecSlot ??= (AdSlot(type: AdSlotType.mrec)..dispose());
    }
    return _mrecSlotsByKey.putIfAbsent(key, () => AdSlot(type: AdSlotType.mrec));
  }

  BannerListenables _mrecListenablesFor(Object key) {
    if (_mrecDisposed) {
      return _disposedMrecListenables ??= (BannerListenables(
        isLoaded: ValueNotifier<bool>(false),
        hasError: ValueNotifier<bool>(false),
        adSize: ValueNotifier<Size?>(null),
        autoRefreshEnabled: ValueNotifier<bool>(true),
        visible: ValueNotifier<bool>(true),
      )..dispose());
    }
    return _mrecListenablesByKey.putIfAbsent(
        key,
        () => BannerListenables(
              isLoaded: ValueNotifier<bool>(false),
              hasError: ValueNotifier<bool>(false),
              adSize: ValueNotifier<Size?>(null),
              autoRefreshEnabled: ValueNotifier<bool>(true),
              visible: ValueNotifier<bool>(true),
            ));
  }

  @override
  AdSlot mrecSlot(Object key) => _mrecSlotFor(key);

  @override
  Iterable<AdSlot> get mrecSlots => _mrecSlotsByKey.values;

  @override
  BannerListenables mrec(Object key) => _mrecListenablesFor(key);

  @override
  void disposeMrecInstance(Object key) {
    _mrecAdsByKey.remove(key)?.dispose();
    _mrecSlotsByKey.remove(key)?.dispose();
    _mrecListenablesByKey.remove(key)?.dispose();
  }

  // T65 (phase 1) — one AdSlot per NativeAdWidget instance (see nativeSlot()
  // below), instead of one shared across every mounted widget.
  final Map<Object, AdSlot> _nativeSlotsByKey = {};

  // ─── Native listenables ───────────────────────────────────────────────────
  // adSize/autoRefreshEnabled/visible are unused stubs — native ads have no
  // adaptive size or auto-refresh ticker (see AdProviderAdapter.native doc).
  // T65 (phase 1) — one bundle per NativeAdWidget instance (see native()
  // below), instead of one shared across every mounted widget.

  final Map<Object, BannerListenables> _nativeListenablesByKey = {};

  // T73 — remembers each key's requested template, so the connectivity/
  // resume retry path (which calls preloadNative(key) with no explicit
  // templateType) reloads with the SAME template the widget originally
  // asked for, instead of silently falling back to the medium default.
  final Map<Object, TemplateType> _nativeTemplateTypeByKey = {};

  // T65 (phase 1) — once this adapter instance is disposed (discarded; a
  // fresh one is constructed on the next initialize()), any further call
  // must not silently resurrect a live slot/listenables bundle for a key
  // that's never been seen — it should fail exactly like the singleton
  // fields already did (a disposed ValueNotifier throws on use).
  bool _nativeDisposed = false;
  AdSlot? _disposedNativeSlot;
  BannerListenables? _disposedNativeListenables;

  AdSlot _nativeSlotFor(Object key) {
    if (_nativeDisposed) {
      return _disposedNativeSlot ??=
          (AdSlot(type: AdSlotType.native)..dispose());
    }
    return _nativeSlotsByKey.putIfAbsent(
        key, () => AdSlot(type: AdSlotType.native));
  }

  BannerListenables _nativeListenablesFor(Object key) {
    if (_nativeDisposed) {
      return _disposedNativeListenables ??= (BannerListenables(
        isLoaded: ValueNotifier<bool>(false),
        hasError: ValueNotifier<bool>(false),
        adSize: ValueNotifier<Size?>(null),
        autoRefreshEnabled: ValueNotifier<bool>(true),
        visible: ValueNotifier<bool>(true),
      )..dispose());
    }
    return _nativeListenablesByKey.putIfAbsent(
        key,
        () => BannerListenables(
              isLoaded: ValueNotifier<bool>(false),
              hasError: ValueNotifier<bool>(false),
              adSize: ValueNotifier<Size?>(null),
              autoRefreshEnabled: ValueNotifier<bool>(true),
              visible: ValueNotifier<bool>(true),
            ));
  }

  @override
  AdSlot nativeSlot(Object key) => _nativeSlotFor(key);

  @override
  BannerListenables native(Object key) => _nativeListenablesFor(key);

  @override
  void disposeNativeInstance(Object key) {
    _nativeAdsByKey.remove(key)?.dispose();
    _nativeSlotsByKey.remove(key)?.dispose();
    _nativeListenablesByKey.remove(key)?.dispose();
    _nativeTemplateTypeByKey.remove(key);
  }

  // ─── Native ad objects ────────────────────────────────────────────────────

  GmaFullscreenAd? _appOpenAd;
  GmaFullscreenAd? _interstitialAd;
  GmaFullscreenAd? _rewardedAd;
  // T65 (phase 2) — one BannerAd per BannerAdWidget instance, same reasoning
  // as native's _nativeAdsByKey.
  final Map<Object, BannerAd> _bannerAdsByKey = {};
  // T65 (phase 3) — one BannerAd per MrecAdWidget instance, same reasoning as
  // banner's _bannerAdsByKey. MREC also uses the native BannerAd API, with
  // AdSize.mediumRectangle.
  final Map<Object, BannerAd> _mrecAdsByKey = {};
  // T65 (phase 1) — one NativeAd per NativeAdWidget instance, instead of one
  // shared across every mounted widget (was the root cause of the "This
  // AdWidget is already in the Widget tree" crash with 2+ simultaneous
  // native widgets).
  final Map<Object, NativeAd> _nativeAdsByKey = {};

  // ─── Pending callbacks (one per slot at most) ─────────────────────────────
  void Function(bool dismissed)? _appOpenDismiss;
  void Function(bool shown)? _interstitialDone;
  void Function(RewardResult result)? _rewardedDone;

  /// Safety watchdog for App Open show. GMA's `FullScreenContentCallback` is
  /// reliable, but on the rare occasion neither `onAdDismissed` nor
  /// `onAdFailedToShow` fires (some mediation adapters), the resume path has no
  /// other timer to recover it → the caller would hang forever. Mirrors the
  /// AppLovin adapter's hard-cap watchdog.
  Timer? _appOpenShowTimeout;
  static const Duration _appOpenShowHardCap = Duration(seconds: 90);

  // T65 (phase 2) — one flag per BannerAdWidget instance (each has its own
  // RouteAware subscription/route).
  final Map<Object, bool> _bannerRoutePausedByKey = {};

  @override
  bool bannerRoutePaused(Object key) => _bannerRoutePausedByKey[key] ?? false;

  @override
  void setBannerRoutePaused(Object key, bool paused) {
    _bannerRoutePausedByKey[key] = paused;
  }

  @override
  String? get appLovinBannerId => null; // AdMob only

  @override
  ValueListenable<Object?> appLovinBannerAdViewId(Object key) =>
      _appLovinAdViewIdStub;
  static final ValueNotifier<Object?> _appLovinAdViewIdStub =
      ValueNotifier<Object?>(null);

  // T65 (phase 3) — one flag per MrecAdWidget instance, mirroring banner.
  final Map<Object, bool> _mrecRoutePausedByKey = {};

  @override
  bool mrecRoutePaused(Object key) => _mrecRoutePausedByKey[key] ?? false;

  @override
  void setMrecRoutePaused(Object key, bool paused) {
    _mrecRoutePausedByKey[key] = paused;
  }

  @override
  String? get appLovinMrecId => null; // AdMob only

  @override
  ValueListenable<Object?> appLovinMrecAdViewId(Object key) =>
      _appLovinAdViewIdStub;

  @override
  String? get appLovinNativeId => null; // AdMob only

  // ──────────────────────────────────────────────────────────────────────────
  //  LIFECYCLE
  // ──────────────────────────────────────────────────────────────────────────

  @override
  Future<bool> initialize(
    AdConfig config, {
    String deviceGaid = '',
    bool isAgeRestrictedUser = false,
  }) async {
    // ponytail: no gate needed here — COPPA is honoured per-request via
    // tagForChildDirectedTreatment in ad_consent.dart, not at init time.
    final cfg = config.admob;
    if (cfg == null) {
      SafeLogger.e(_logTag, 'initialize: AdMobConfig is null — aborted');
      return false;
    }
    try {
      await _bridge.initialize();
      await _bridge.updateRequestConfiguration(cfg.testDeviceIds);
      _config = config;
      _admob = cfg;
      SafeLogger.d(_logTag, 'initialize $tag ✅');
      return true;
    } catch (e, st) {
      SafeLogger.e(_logTag, 'initialize $tag FAILED: $e\n$st');
      return false;
    }
  }

  @override
  Future<void> dispose() async {
    SafeLogger.d(_logTag, 'dispose() $tag — releasing native resources');
    _appOpenShowTimeout?.cancel();
    _appOpenShowTimeout = null;
    _disposeAd(_appOpenAd, 'appOpen');
    _appOpenAd = null;
    _disposeAd(_interstitialAd, 'interstitial');
    _interstitialAd = null;
    _disposeAd(_rewardedAd, 'rewarded');
    _rewardedAd = null;
    for (final ad in _bannerAdsByKey.values) {
      try {
        ad.dispose();
      } catch (e) {
        SafeLogger.w(_logTag, 'banner dispose threw: $e');
      }
    }
    _bannerAdsByKey.clear();
    for (final ad in _mrecAdsByKey.values) {
      try {
        ad.dispose();
      } catch (e) {
        SafeLogger.w(_logTag, 'mrec dispose threw: $e');
      }
    }
    _mrecAdsByKey.clear();
    for (final ad in _nativeAdsByKey.values) {
      try {
        ad.dispose();
      } catch (e) {
        SafeLogger.w(_logTag, 'native dispose threw: $e');
      }
    }
    _nativeAdsByKey.clear();

    // Fire any pending callbacks with `false` so callers don't hang.
    _appOpenDismiss?.call(false);
    _appOpenDismiss = null;
    _interstitialDone?.call(false);
    _interstitialDone = null;
    _rewardedDone?.call(RewardResult.skipped);
    _rewardedDone = null;

    appOpenSlot.reset();
    interstitialSlot.reset();
    rewardedSlot.reset();
    for (final slot in _bannerSlotsByKey.values) {
      slot.reset();
    }
    for (final slot in _mrecSlotsByKey.values) {
      slot.reset();
    }
    for (final slot in _nativeSlotsByKey.values) {
      slot.reset();
    }

    for (final l in _bannerListenablesByKey.values) {
      l.isLoaded.value = false;
      l.hasError.value = false;
      l.adSize.value = null;
      l.autoRefreshEnabled.value = true;
      l.visible.value = true;
    }
    _bannerRoutePausedByKey.clear();

    for (final l in _mrecListenablesByKey.values) {
      l.isLoaded.value = false;
      l.hasError.value = false;
      l.adSize.value = null;
      l.autoRefreshEnabled.value = true;
      l.visible.value = true;
    }
    _mrecRoutePausedByKey.clear();

    // This adapter instance is discarded after dispose() — a fresh one is
    // constructed on the next initialize() — so it's safe to permanently
    // dispose the ValueNotifiers here rather than just resetting their value.
    appOpenSlot.dispose();
    interstitialSlot.dispose();
    rewardedSlot.dispose();
    // T65 (phase 2) — dispose every BannerAdWidget instance's slot/ad/
    // listenables (already cleared _bannerAdsByKey above); disposeBannerInstance
    // mutates the maps, so snapshot the keys first.
    for (final key in _bannerSlotsByKey.keys.toList()) {
      disposeBannerInstance(key);
    }
    _bannerDisposed = true;
    // T65 (phase 3) — same pattern as banner above.
    for (final key in _mrecSlotsByKey.keys.toList()) {
      disposeMrecInstance(key);
    }
    _mrecDisposed = true;
    // T65 (phase 1) — dispose every NativeAdWidget instance's slot/ad/
    // listenables (already cleared _nativeAdsByKey above); disposeNativeInstance
    // mutates the maps, so snapshot the keys first.
    for (final key in _nativeSlotsByKey.keys.toList()) {
      disposeNativeInstance(key);
    }
    _nativeDisposed = true;

    _admob = null;
    _config = null;
    // Reset to conservative so a re-init before consent re-applies stays npa=1.
    _nonPersonalizedAds = true;
    _restrictedDataProcessing = false;
  }

  @override
  void applyConsent(AdConsent consent) {
    // AdMob personalization is per-request. No user consent → non-personalized
    // (`npa=1`) on every subsequent AdRequest. This is the authoritative signal
    // for the non-UMP consent path; UMP (T01) governs personalization natively
    // via the TCF string when enabled.
    _nonPersonalizedAds = !consent.hasUserConsent;
    // CCPA "do not sell" → forwarded per-request as AdMob restricted-data-
    // processing (RDP). Independent of hasUserConsent/isAgeRestrictedUser —
    // never derived from or into tagForUnderAgeOfConsent (see AdConsent doc).
    _restrictedDataProcessing = consent.doNotSell;
    SafeLogger.d(
      _logTag,
      () => 'applyConsent → nonPersonalizedAds=$_nonPersonalizedAds '
          'restrictedDataProcessing=$_restrictedDataProcessing '
          '(hasUserConsent=${consent.hasUserConsent}, doNotSell=${consent.doNotSell})',
    );
  }

  void _disposeAd(GmaFullscreenAd? ad, String label) {
    if (ad == null) return;
    try {
      // The wrapper nulls the fullScreenContentCallback BEFORE disposing the
      // native ad, avoiding late callbacks mutating a destroyed object.
      ad.dispose();
    } catch (e) {
      SafeLogger.w(_logTag, '$label dispose threw: $e');
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  APP OPEN
  // ──────────────────────────────────────────────────────────────────────────

  static const int _appOpenExpiryHours = 4;

  /// AdMob interstitial/rewarded content is valid for up to 1 hour after load
  /// (per Google's docs). Beyond that the cached ad is stale and `show()` will
  /// fail — so refuse to reuse it and load a fresh one instead.
  static const int _fullscreenExpiryHours = 1;

  /// Whether a cached ad loaded at [loadedAt] is still fresh enough to reuse.
  /// Returns false when never loaded (`null`). Exposed for tests.
  @visibleForTesting
  static bool isAdFresh(DateTime? loadedAt, int maxHours, {DateTime? now}) {
    if (loadedAt == null) return false;
    return (now ?? DateTime.now()).difference(loadedAt).inHours < maxHours;
  }

  @override
  Future<void> loadAppOpen({void Function(bool loaded)? onAdLoaded}) async {
    final cfg = _admob;
    if (cfg == null) {
      onAdLoaded?.call(false);
      return;
    }

    // Fresh ad already in slot? Reuse.
    if (_appOpenAd != null) {
      if (isAdFresh(appOpenSlot.lastLoadedAt, _appOpenExpiryHours)) {
        SafeLogger.d(_logTag, 'loadAppOpen $tag ⏭️ already fresh, reuse');
        onAdLoaded?.call(true);
        return;
      }
      SafeLogger.d(_logTag,
          'loadAppOpen $tag ♻️ expired (>${_appOpenExpiryHours}h), disposing old');
      _disposeAd(_appOpenAd, 'appOpen-expired');
      _appOpenAd = null;
      appOpenSlot.lastLoadedAt = null;
    }

    if (!appOpenSlot.beginLoad()) {
      SafeLogger.d(_logTag, 'loadAppOpen $tag ⏭️ already loading/showing');
      onAdLoaded?.call(false);
      return;
    }
    appOpenSlot.pendingCallback = onAdLoaded;
    SafeLogger.d(_logTag, 'loadAppOpen $tag 🔄');

    try {
      await _bridge.loadAppOpen(
        cfg.appOpenId,
        nonPersonalizedAds: _nonPersonalizedAds,
        restrictedDataProcessing: _restrictedDataProcessing,
        onLoaded: (ad) {
          SafeLogger.d(_logTag, 'loadAppOpen $tag ✅');
          _appOpenAd = ad;
          _wirePaidEvent(ad, AdSlotType.appOpen, AdPlacement.splash);
          appOpenSlot.markReady();
          _emit(AdLoadEvent(
            providerTag: tag,
            type: AdSlotType.appOpen,
            placement: AdPlacement.splash,
            success: true,
          ));
        },
        onFailed: (code, message) {
          SafeLogger.w(_logTag, 'loadAppOpen $tag ❌ code=$code msg=$message');
          _appOpenAd = null;
          appOpenSlot.markFailed();
          _emit(AdLoadEvent(
            providerTag: tag,
            type: AdSlotType.appOpen,
            placement: AdPlacement.splash,
            success: false,
            errorCode: code,
          ));
        },
      );
    } catch (e, st) {
      SafeLogger.e(_logTag, 'loadAppOpen $tag THREW: $e\n$st');
      _appOpenAd = null;
      appOpenSlot.markFailed();
    }
  }

  @override
  Future<void> showAppOpen(
      {required void Function(bool dismissed) onDismiss}) async {
    final ad = _appOpenAd;
    if (ad == null || !appOpenSlot.isReady) {
      SafeLogger.w(_logTag,
          'showAppOpen $tag ⚠️ not ready (state=${appOpenSlot.value})');
      onDismiss(false);
      return;
    }
    if (!appOpenSlot.beginShow()) {
      SafeLogger.w(_logTag, 'showAppOpen $tag ⚠️ already showing');
      onDismiss(false);
      return;
    }
    _appOpenDismiss = onDismiss;
    try {
      await ad.show(GmaShowCallbacks(
        onShowed: () => SafeLogger.d(_logTag, 'showAppOpen $tag ✅ shown'),
        onDismissed: () {
          _appOpenShowTimeout?.cancel();
          _appOpenShowTimeout = null;
          // Late arrival: the hard-cap watchdog already force-dismissed this
          // show cycle (_appOpenDismiss cleared) before GMA's native callback
          // landed. Acting again would clobber slot state the reload-in-flight
          // already moved on from and double-dispose `ad`.
          if (_appOpenDismiss == null) {
            SafeLogger.d(_logTag,
                'showAppOpen $tag 👋 dismissed (late — watchdog already handled this show)');
            _appOpenAd = null;
            _disposeAd(ad, 'appOpen-after-dismiss-late');
            return;
          }
          SafeLogger.d(_logTag, 'showAppOpen $tag 👋 dismissed');
          _appOpenAd = null;
          _disposeAd(ad, 'appOpen-after-dismiss');
          appOpenSlot.markDismissed();
          final cb = _appOpenDismiss;
          _appOpenDismiss = null;
          cb?.call(true);
        },
        onFailedToShow: (message) {
          _appOpenShowTimeout?.cancel();
          _appOpenShowTimeout = null;
          _appOpenAd = null;
          // Late arrival (see onDismissed above) — watchdog already resolved.
          if (_appOpenDismiss == null) {
            SafeLogger.w(_logTag,
                'showAppOpen $tag ❌ display failed (late — watchdog already handled this show): $message');
            _disposeAd(ad, 'appOpen-show-fail-late');
            return;
          }
          SafeLogger.w(_logTag, 'showAppOpen $tag ❌ display failed: $message');
          _disposeAd(ad, 'appOpen-show-fail');
          appOpenSlot.markShowFailed();
          final cb = _appOpenDismiss;
          _appOpenDismiss = null;
          cb?.call(false);
        },
        onClicked: () {
          SafeLogger.d(_logTag, 'showAppOpen $tag 🎯 click');
          AdSafetyConfig.recordAdClick();
          _emit(AdClickEvent(
            providerTag: tag,
            type: AdSlotType.appOpen,
            placement: AdPlacement.splash,
          ));
        },
      ));
      // Safety net: if neither dismiss nor fail callback fires (rare GMA /
      // mediation hang), force-dismiss after the hard cap so the caller — which
      // on the resume path has no other recovery timer — never hangs.
      _armAppOpenWatchdog(onDismiss);
    } catch (e, st) {
      SafeLogger.e(_logTag, 'showAppOpen $tag show THREW: $e\n$st');
      _appOpenShowTimeout?.cancel();
      _appOpenShowTimeout = null;
      _appOpenAd = null;
      appOpenSlot.markShowFailed();
      final cb = _appOpenDismiss;
      _appOpenDismiss = null;
      cb?.call(false);
    }
  }

  /// Arms the App Open show watchdog. Captures [captured] (the *local*
  /// onDismiss) and verifies identity before firing, so a watchdog left over
  /// from a previous show can never resolve a newer show's callback. [cap] is
  /// overridable for tests.
  void _armAppOpenWatchdog(void Function(bool) captured, {Duration? cap}) {
    _appOpenShowTimeout?.cancel();
    _appOpenShowTimeout = Timer(cap ?? _appOpenShowHardCap, () {
      _appOpenShowTimeout = null;
      // Only fire if THIS show's callback is still the pending one.
      if (_appOpenDismiss != captured) return; // already resolved / replaced
      SafeLogger.w(_logTag,
          'showAppOpen $tag ⏰ HARD CAP — no dismiss callback, force dismiss(false)');
      _appOpenAd = null;
      appOpenSlot.markShowFailed();
      _appOpenDismiss = null;
      captured(false);
    });
  }

  /// Test seam: simulate an App Open that is "showing" then arm the watchdog
  /// with a short [cap] so the hard-cap path can be exercised without the
  /// native GMA `AppOpenAd`.
  @visibleForTesting
  void debugSimulateAppOpenShowAndArmWatchdog(
      void Function(bool) onDismiss, Duration cap) {
    appOpenSlot.beginLoad();
    appOpenSlot.markReady();
    appOpenSlot.beginShow();
    _appOpenDismiss = onDismiss;
    _armAppOpenWatchdog(onDismiss, cap: cap);
  }

  @visibleForTesting
  bool get debugWatchdogArmed => _appOpenShowTimeout != null;

  // ──────────────────────────────────────────────────────────────────────────
  //  INTERSTITIAL
  // ──────────────────────────────────────────────────────────────────────────

  @override
  Future<void> loadInterstitial() async {
    final cfg = _admob;
    if (cfg == null) return;
    // Reuse only if still fresh (≤1h); a stale cached ad fails on show().
    if (_interstitialAd != null) {
      if (isAdFresh(interstitialSlot.lastLoadedAt, _fullscreenExpiryHours)) {
        return; // fresh — keep it
      }
      SafeLogger.d(_logTag,
          'loadInterstitial $tag ♻️ expired (>${_fullscreenExpiryHours}h), disposing old');
      _disposeAd(_interstitialAd, 'inter-expired');
      _interstitialAd = null;
      interstitialSlot.lastLoadedAt = null;
    }
    if (!interstitialSlot.beginLoad()) return;
    SafeLogger.d(_logTag, 'loadInterstitial $tag 🔄');
    try {
      await _bridge.loadInterstitial(
        cfg.interstitialId,
        nonPersonalizedAds: _nonPersonalizedAds,
        restrictedDataProcessing: _restrictedDataProcessing,
        onLoaded: (ad) {
          SafeLogger.d(_logTag, 'loadInterstitial $tag ✅');
          _interstitialAd = ad;
          _wirePaidEvent(ad, AdSlotType.interstitial, AdPlacement.unspecified);
          interstitialSlot.markReady();
          _emit(AdLoadEvent(
            providerTag: tag,
            type: AdSlotType.interstitial,
            placement: AdPlacement.unspecified,
            success: true,
          ));
        },
        onFailed: (code, message) {
          SafeLogger.w(_logTag, 'loadInterstitial $tag ❌ $code');
          _interstitialAd = null;
          interstitialSlot.markFailed();
          _emit(AdLoadEvent(
            providerTag: tag,
            type: AdSlotType.interstitial,
            placement: AdPlacement.unspecified,
            success: false,
            errorCode: code,
          ));
        },
      );
    } catch (e, st) {
      SafeLogger.e(_logTag, 'loadInterstitial $tag THREW: $e\n$st');
      _interstitialAd = null;
      interstitialSlot.markFailed();
    }
  }

  @override
  Future<void> showInterstitial(
      {required void Function(bool shown) onDone}) async {
    final ad = _interstitialAd;
    if (ad == null || !interstitialSlot.isReady) {
      SafeLogger.w(_logTag, 'showInterstitial $tag ⚠️ not ready');
      onDone(false);
      return;
    }
    if (!interstitialSlot.beginShow()) {
      SafeLogger.w(_logTag, 'showInterstitial $tag ⚠️ already showing');
      onDone(false);
      return;
    }
    _interstitialDone = onDone;
    try {
      await ad.show(GmaShowCallbacks(
        onShowed: () => SafeLogger.d(_logTag, 'showInterstitial $tag ✅ shown'),
        onDismissed: () {
          SafeLogger.d(_logTag, 'showInterstitial $tag 👋 dismissed');
          _interstitialAd = null;
          _disposeAd(ad, 'inter-after-dismiss');
          interstitialSlot.markDismissed();
          final cb = _interstitialDone;
          _interstitialDone = null;
          cb?.call(true);
        },
        onFailedToShow: (message) {
          SafeLogger.w(
              _logTag, 'showInterstitial $tag ❌ display failed: $message');
          _interstitialAd = null;
          _disposeAd(ad, 'inter-show-fail');
          interstitialSlot.markShowFailed();
          final cb = _interstitialDone;
          _interstitialDone = null;
          cb?.call(false);
        },
        onClicked: () {
          SafeLogger.d(_logTag, 'showInterstitial $tag 🎯 click');
          AdSafetyConfig.recordAdClick();
          _emit(AdClickEvent(
            providerTag: tag,
            type: AdSlotType.interstitial,
            placement: AdPlacement.unspecified,
          ));
        },
      ));
    } catch (e, st) {
      SafeLogger.e(_logTag, 'showInterstitial $tag THREW: $e\n$st');
      _interstitialAd = null;
      interstitialSlot.markShowFailed();
      final cb = _interstitialDone;
      _interstitialDone = null;
      cb?.call(false);
    }
  }

  /// Test seam: put the interstitial slot into `showing` with [onDone]
  /// captured, then immediately simulate GMA's `onDismissed` (or
  /// `onFailedToShow` when [dismissed] is `false`) — the same callback path
  /// `showInterstitial` drives in production. Unlike App Open, there is no
  /// watchdog/timer here: GMA's fullscreen interstitial callbacks are treated
  /// as reliable, so this hook only exercises the plain `beginShow()` →
  /// `markDismissed()`/`markShowFailed()` transition — the exact path a
  /// zombie-`showing` bug would corrupt.
  @visibleForTesting
  void debugSimulateInterstitialShowAndDismiss(
    void Function(bool) onDone, {
    bool dismissed = true,
  }) {
    interstitialSlot.beginLoad();
    interstitialSlot.markReady();
    interstitialSlot.beginShow();
    _interstitialDone = onDone;
    final cb = _interstitialDone;
    _interstitialDone = null;
    if (dismissed) {
      interstitialSlot.markDismissed();
      cb?.call(true);
    } else {
      interstitialSlot.markShowFailed();
      cb?.call(false);
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  REWARDED
  // ──────────────────────────────────────────────────────────────────────────

  @override
  Future<void> loadRewarded() async {
    final cfg = _admob;
    if (cfg == null) return;
    // Reuse only if still fresh (≤1h); a stale cached ad fails on show().
    if (_rewardedAd != null) {
      if (isAdFresh(rewardedSlot.lastLoadedAt, _fullscreenExpiryHours)) {
        return; // fresh — keep it
      }
      SafeLogger.d(_logTag,
          'loadRewarded $tag ♻️ expired (>${_fullscreenExpiryHours}h), disposing old');
      _disposeAd(_rewardedAd, 'rewarded-expired');
      _rewardedAd = null;
      rewardedSlot.lastLoadedAt = null;
    }
    if (!rewardedSlot.beginLoad()) return;
    SafeLogger.d(_logTag, 'loadRewarded $tag 🔄');
    try {
      await _bridge.loadRewarded(
        cfg.rewardedId,
        nonPersonalizedAds: _nonPersonalizedAds,
        restrictedDataProcessing: _restrictedDataProcessing,
        onLoaded: (ad) {
          SafeLogger.d(_logTag, 'loadRewarded $tag ✅');
          _rewardedAd = ad;
          _wirePaidEvent(ad, AdSlotType.rewarded, AdPlacement.unspecified);
          rewardedSlot.markReady();
          _emit(AdLoadEvent(
            providerTag: tag,
            type: AdSlotType.rewarded,
            placement: AdPlacement.unspecified,
            success: true,
          ));
        },
        onFailed: (code, message) {
          SafeLogger.w(_logTag, 'loadRewarded $tag ❌ $code');
          _rewardedAd = null;
          rewardedSlot.markFailed();
          _emit(AdLoadEvent(
            providerTag: tag,
            type: AdSlotType.rewarded,
            placement: AdPlacement.unspecified,
            success: false,
            errorCode: code,
          ));
        },
      );
    } catch (e, st) {
      SafeLogger.e(_logTag, 'loadRewarded $tag THREW: $e\n$st');
      _rewardedAd = null;
      rewardedSlot.markFailed();
    }
  }

  @override
  Future<void> showRewarded({
    required void Function(RewardResult result) onDone,
    String? ssvCustomData,
    String? ssvUserId,
  }) async {
    final ad = _rewardedAd;
    if (ad == null || !rewardedSlot.isReady) {
      SafeLogger.w(_logTag, 'showRewarded $tag ⚠️ not ready');
      onDone(RewardResult.skipped);
      return;
    }
    if (!rewardedSlot.beginShow()) {
      SafeLogger.w(_logTag, 'showRewarded $tag ⚠️ already showing');
      onDone(RewardResult.skipped);
      return;
    }
    _rewardedDone = onDone;
    final pendingSsv = ssvCustomData != null || ssvUserId != null;

    // Local guards against double-fire (Fix #42 preserved).
    var earned = false;
    var fired = false;
    void fire(RewardResult r) {
      if (fired) return;
      fired = true;
      final cb = _rewardedDone;
      _rewardedDone = null;
      cb?.call(r);
    }

    try {
      await ad.show(
          ssvCustomData: ssvCustomData,
          ssvUserId: ssvUserId,
          GmaShowCallbacks(
            onShowed: () => SafeLogger.d(_logTag, 'showRewarded $tag ✅ shown'),
            onDismissed: () {
              SafeLogger.d(
                  _logTag, 'showRewarded $tag 👋 dismissed (earned=$earned)');
              _rewardedAd = null;
              _disposeAd(ad, 'rewarded-after-dismiss');
              rewardedSlot.markDismissed();
              if (!earned) fire(RewardResult.skipped);
            },
            onFailedToShow: (message) {
              SafeLogger.w(
                  _logTag, 'showRewarded $tag ❌ display failed: $message');
              _rewardedAd = null;
              _disposeAd(ad, 'rewarded-show-fail');
              rewardedSlot.markShowFailed();
              fire(RewardResult.skipped);
            },
            onClicked: () {
              SafeLogger.d(_logTag, 'showRewarded $tag 🎯 click');
              AdSafetyConfig.recordAdClick();
              _emit(AdClickEvent(
                providerTag: tag,
                type: AdSlotType.rewarded,
                placement: AdPlacement.unspecified,
              ));
            },
            onUserEarnedReward: (amount, type) {
              SafeLogger.d(
                  _logTag, 'showRewarded $tag 🏆 type=$type amount=$amount');
              earned = true;
              fire(RewardResult(
                earned: true,
                label: type,
                amount: amount,
                pendingServerConfirmation: pendingSsv,
              ));
            },
          ));
    } catch (e, st) {
      SafeLogger.e(_logTag, 'showRewarded $tag show THREW: $e\n$st');
      _rewardedAd = null;
      rewardedSlot.markShowFailed();
      fire(RewardResult.skipped);
    }
  }

  /// Test seam: put the rewarded slot into `showing` with [onDone] captured,
  /// then immediately simulate GMA's `onDismissed` (or `onFailedToShow` when
  /// [dismissed] is `false`) — mirrors [debugSimulateInterstitialShowAndDismiss].
  /// No watchdog exists for rewarded either, so this only exercises the plain
  /// `beginShow()` → `markDismissed()`/`markShowFailed()` transition.
  @visibleForTesting
  void debugSimulateRewardedShowAndDismiss(
    void Function(RewardResult) onDone, {
    bool dismissed = true,
  }) {
    rewardedSlot.beginLoad();
    rewardedSlot.markReady();
    rewardedSlot.beginShow();
    _rewardedDone = onDone;
    final cb = _rewardedDone;
    _rewardedDone = null;
    if (dismissed) {
      rewardedSlot.markDismissed();
      cb?.call(RewardResult.skipped);
    } else {
      rewardedSlot.markShowFailed();
      cb?.call(RewardResult.skipped);
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  BANNER
  // ──────────────────────────────────────────────────────────────────────────

  @override
  Future<void> preloadBanner(Object key) async {
    // C4 — same gate the fullscreen load paths and the auto-reload callbacks
    // consult (`!VIP && !dailyCapReached && canRequestAds && isConnected`,
    // wired in AdManager). None of the banner/MREC/native entry points checked
    // it, in EITHER adapter, so a resume after a banner error — or any other
    // caller — could fire an ad request while consent was not granted, while
    // the user was VIP, or after the daily cap. Requesting an ad with
    // canRequestAds == false is a UMP policy violation, and it is invisible
    // from the UI because the widget layer hides the banner for VIP anyway.
    if (!canReload()) {
      SafeLogger.d(
          _logTag, 'preloadBanner $tag \u23ed\ufe0f skipped — gate closed');
      return;
    }
    // AdMob banner loads on widget mount when width is known — no preload here.
    SafeLogger.d(_logTag, 'preloadBanner $tag (no-op for AdMob)');
  }

  @override
  Future<void> loadBannerIfNeeded(Object key, double widthPx) async {
    // C4 — same gate the fullscreen load paths and the auto-reload callbacks
    // consult (`!VIP && !dailyCapReached && canRequestAds && isConnected`,
    // wired in AdManager). None of the banner/MREC/native entry points checked
    // it, in EITHER adapter, so a resume after a banner error — or any other
    // caller — could fire an ad request while consent was not granted, while
    // the user was VIP, or after the daily cap. Requesting an ad with
    // canRequestAds == false is a UMP policy violation, and it is invisible
    // from the UI because the widget layer hides the banner for VIP anyway.
    if (!canReload()) {
      SafeLogger.d(_logTag,
          'loadBannerIfNeeded $tag \u23ed\ufe0f skipped — gate closed');
      return;
    }
    final cfg = _admob;
    if (cfg == null) return;
    if (_bannerAdsByKey.containsKey(key)) {
      SafeLogger.d(_logTag, 'loadBanner $tag ⏭️ already cached');
      return;
    }
    final slot = _bannerSlotFor(key);
    final listenables = _bannerListenablesFor(key);
    // Transition the slot to `loading` BEFORE creating the BannerAd. GMA's
    // onAdLoaded/onAdFailedToLoad can fire synchronously on a cached fill — if
    // beginLoad() ran AFTER ..load() it would overwrite the ready/cooldown
    // state the callback set and strand the slot in `loading` forever.
    // Use beginLoad (not beginReload) so a flapping banner still respects the
    // backoff window — banner reload is cheap to skip, unlike a spent fullscreen.
    if (!slot.beginLoad()) {
      SafeLogger.d(
          _logTag, 'loadBanner $tag ⏭️ already loading/showing or in cooldown');
      return;
    }
    listenables.isLoaded.value = false;
    SafeLogger.d(_logTag, 'loadBanner $tag 🔄 width=$widthPx');
    try {
      final adaptive =
          await AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(
              widthPx.truncate());
      final size = adaptive ?? AdSize.banner;
      _bannerAdsByKey[key] = BannerAd(
        adUnitId: cfg.bannerId,
        size: size,
        // Banner doesn't go through GmaBridge, so RDP extras are built locally
        // here — mirrors GmaBridge's private `_rdpExtras`/`_extrasFor` used by
        // the fullscreen ad loaders (see gma_bridge.dart).
        request: AdRequest(
          nonPersonalizedAds: _nonPersonalizedAds,
          extras: _restrictedDataProcessing ? const {'rdp': '1'} : null,
        ),
        listener: BannerAdListener(
          onPaidEvent: _paidEventForBanner(AdPlacement.unspecified),
          onAdLoaded: (ad) {
            SafeLogger.d(_logTag, 'loadBanner $tag ✅');
            listenables.isLoaded.value = true;
            listenables.hasError.value = false;
            listenables.adSize.value =
                Size(size.width.toDouble(), size.height.toDouble());
            slot.markReady();
            // Counts towards CTR denominator (preserves original 1.x Fix J).
            AdSafetyConfig.recordBannerImpression();
            _emit(AdLoadEvent(
              providerTag: tag,
              type: AdSlotType.banner,
              placement: AdPlacement.unspecified,
              success: true,
            ));
          },
          onAdFailedToLoad: (ad, err) {
            SafeLogger.w(_logTag, 'loadBanner $tag ❌ ${err.code}');
            try {
              ad.dispose();
            } catch (_) {}
            _bannerAdsByKey.remove(key);
            listenables.isLoaded.value = false;
            listenables.hasError.value = true;
            slot.markFailed();
            _emit(AdLoadEvent(
              providerTag: tag,
              type: AdSlotType.banner,
              placement: AdPlacement.unspecified,
              success: false,
              errorCode: err.code,
            ));
          },
          onAdOpened: (ad) {
            SafeLogger.d(_logTag, 'banner $tag 🎯 click');
            AdSafetyConfig.recordAdClick();
            _emit(AdClickEvent(
              providerTag: tag,
              type: AdSlotType.banner,
              placement: AdPlacement.unspecified,
            ));
          },
          onAdClosed: (ad) => SafeLogger.d(_logTag, 'banner $tag closed'),
        ),
      )..load();
      // Slot already transitioned to `loading` above (before BannerAd creation).
    } catch (e, st) {
      SafeLogger.e(_logTag, 'loadBanner $tag adaptive size THREW: $e\n$st');
      listenables.hasError.value = true;
      slot.markFailed();
    }
  }

  @override
  Widget? buildAdmobBannerView(Object key) {
    final ad = _bannerAdsByKey[key];
    if (ad == null) return null;
    return SizedBox(
      width: ad.size.width.toDouble(),
      height: ad.size.height.toDouble(),
      child: AdWidget(ad: ad),
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  MREC
  // ──────────────────────────────────────────────────────────────────────────

  @override
  Future<void> preloadMrec(Object key) async {
    // C4 — same gate the fullscreen load paths and the auto-reload callbacks
    // consult (`!VIP && !dailyCapReached && canRequestAds && isConnected`,
    // wired in AdManager). None of the banner/MREC/native entry points checked
    // it, in EITHER adapter, so a resume after a banner error — or any other
    // caller — could fire an ad request while consent was not granted, while
    // the user was VIP, or after the daily cap. Requesting an ad with
    // canRequestAds == false is a UMP policy violation, and it is invisible
    // from the UI because the widget layer hides the banner for VIP anyway.
    if (!canReload()) {
      SafeLogger.d(
          _logTag, 'preloadMrec $tag \u23ed\ufe0f skipped — gate closed');
      return;
    }
    // AdMob MREC loads on widget mount when width is known — no preload here.
    SafeLogger.d(_logTag, 'preloadMrec $tag (no-op for AdMob)');
  }

  @override
  Future<void> loadMrecIfNeeded(Object key, double widthPx) async {
    // C4 — same gate the fullscreen load paths and the auto-reload callbacks
    // consult (`!VIP && !dailyCapReached && canRequestAds && isConnected`,
    // wired in AdManager). None of the banner/MREC/native entry points checked
    // it, in EITHER adapter, so a resume after a banner error — or any other
    // caller — could fire an ad request while consent was not granted, while
    // the user was VIP, or after the daily cap. Requesting an ad with
    // canRequestAds == false is a UMP policy violation, and it is invisible
    // from the UI because the widget layer hides the banner for VIP anyway.
    if (!canReload()) {
      SafeLogger.d(
          _logTag, 'loadMrecIfNeeded $tag \u23ed\ufe0f skipped — gate closed');
      return;
    }
    final cfg = _admob;
    if (cfg == null) return;
    if (_mrecAdsByKey.containsKey(key)) {
      SafeLogger.d(_logTag, 'loadMrec $tag ⏭️ already cached');
      return;
    }
    final slot = _mrecSlotFor(key);
    final listenables = _mrecListenablesFor(key);
    // Same beginLoad-before-create ordering as banner — see loadBannerIfNeeded.
    if (!slot.beginLoad()) {
      SafeLogger.d(
          _logTag, 'loadMrec $tag ⏭️ already loading/showing or in cooldown');
      return;
    }
    listenables.isLoaded.value = false;
    SafeLogger.d(_logTag, 'loadMrec $tag 🔄');
    try {
      // MREC is a FIXED 300x250 size — no adaptive-size lookup (unlike banner).
      const size = AdSize.mediumRectangle;
      _mrecAdsByKey[key] = BannerAd(
        adUnitId: cfg.mrecId,
        size: size,
        request: AdRequest(
          nonPersonalizedAds: _nonPersonalizedAds,
          extras: _restrictedDataProcessing ? const {'rdp': '1'} : null,
        ),
        listener: BannerAdListener(
          onPaidEvent: _paidEventForMrec(AdPlacement.unspecified),
          onAdLoaded: (ad) {
            SafeLogger.d(_logTag, 'loadMrec $tag ✅');
            listenables.isLoaded.value = true;
            listenables.hasError.value = false;
            listenables.adSize.value =
                Size(size.width.toDouble(), size.height.toDouble());
            slot.markReady();
            AdSafetyConfig.recordBannerImpression();
            _emit(AdLoadEvent(
              providerTag: tag,
              type: AdSlotType.mrec,
              placement: AdPlacement.unspecified,
              success: true,
            ));
          },
          onAdFailedToLoad: (ad, err) {
            SafeLogger.w(_logTag, 'loadMrec $tag ❌ ${err.code}');
            try {
              ad.dispose();
            } catch (_) {}
            _mrecAdsByKey.remove(key);
            listenables.isLoaded.value = false;
            listenables.hasError.value = true;
            slot.markFailed();
            _emit(AdLoadEvent(
              providerTag: tag,
              type: AdSlotType.mrec,
              placement: AdPlacement.unspecified,
              success: false,
              errorCode: err.code,
            ));
          },
          onAdOpened: (ad) {
            SafeLogger.d(_logTag, 'mrec $tag 🎯 click');
            AdSafetyConfig.recordAdClick();
            _emit(AdClickEvent(
              providerTag: tag,
              type: AdSlotType.mrec,
              placement: AdPlacement.unspecified,
            ));
          },
          onAdClosed: (ad) => SafeLogger.d(_logTag, 'mrec $tag closed'),
        ),
      )..load();
    } catch (e, st) {
      SafeLogger.e(_logTag, 'loadMrec $tag THREW: $e\n$st');
      listenables.hasError.value = true;
      slot.markFailed();
    }
  }

  @override
  Widget? buildAdmobMrecView(Object key) {
    final ad = _mrecAdsByKey[key];
    if (ad == null) return null;
    return SizedBox(
      width: ad.size.width.toDouble(),
      height: ad.size.height.toDouble(),
      child: AdWidget(ad: ad),
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  NATIVE
  // ──────────────────────────────────────────────────────────────────────────

  @override
  Future<void> preloadNative(Object key,
      {TemplateType templateType = TemplateType.medium}) async {
    _nativeTemplateTypeByKey[key] = templateType;
    // C4 — same gate the fullscreen load paths and the auto-reload callbacks
    // consult (`!VIP && !dailyCapReached && canRequestAds && isConnected`,
    // wired in AdManager). None of the banner/MREC/native entry points checked
    // it, in EITHER adapter, so a resume after a banner error — or any other
    // caller — could fire an ad request while consent was not granted, while
    // the user was VIP, or after the daily cap. Requesting an ad with
    // canRequestAds == false is a UMP policy violation, and it is invisible
    // from the UI because the widget layer hides the banner for VIP anyway.
    if (!canReload()) {
      SafeLogger.d(
          _logTag, 'preloadNative $tag \u23ed\ufe0f skipped — gate closed');
      return;
    }
    final cfg = _admob;
    if (cfg == null) return;
    if (_nativeAdsByKey.containsKey(key)) {
      SafeLogger.d(_logTag, 'preloadNative $tag ⏭️ already cached');
      return;
    }
    final slot = _nativeSlotFor(key);
    final listenables = _nativeListenablesFor(key);
    if (!slot.beginLoad()) {
      SafeLogger.d(_logTag,
          'preloadNative $tag ⏭️ already loading/showing or in cooldown');
      return;
    }
    listenables.isLoaded.value = false;
    SafeLogger.d(_logTag, 'preloadNative $tag 🔄');
    try {
      _nativeAdsByKey[key] = NativeAd(
        adUnitId: cfg.nativeId,
        request: AdRequest(
          nonPersonalizedAds: _nonPersonalizedAds,
          extras: _restrictedDataProcessing ? const {'rdp': '1'} : null,
        ),
        nativeTemplateStyle:
            NativeTemplateStyle(templateType: templateType),
        listener: NativeAdListener(
          onPaidEvent: _paidEventForNative(AdPlacement.unspecified),
          onAdLoaded: (ad) {
            SafeLogger.d(_logTag, 'preloadNative $tag ✅');
            listenables.isLoaded.value = true;
            listenables.hasError.value = false;
            slot.markReady();
            AdSafetyConfig.recordBannerImpression();
            _emit(AdLoadEvent(
              providerTag: tag,
              type: AdSlotType.native,
              placement: AdPlacement.unspecified,
              success: true,
            ));
          },
          onAdFailedToLoad: (ad, err) {
            SafeLogger.w(_logTag, 'preloadNative $tag ❌ ${err.code}');
            try {
              ad.dispose();
            } catch (_) {}
            _nativeAdsByKey.remove(key);
            listenables.isLoaded.value = false;
            listenables.hasError.value = true;
            slot.markFailed();
            _emit(AdLoadEvent(
              providerTag: tag,
              type: AdSlotType.native,
              placement: AdPlacement.unspecified,
              success: false,
              errorCode: err.code,
            ));
          },
          onAdClicked: (ad) {
            SafeLogger.d(_logTag, 'native $tag 🎯 click');
            AdSafetyConfig.recordAdClick();
            _emit(AdClickEvent(
              providerTag: tag,
              type: AdSlotType.native,
              placement: AdPlacement.unspecified,
            ));
          },
          onAdClosed: (ad) => SafeLogger.d(_logTag, 'native $tag closed'),
        ),
      )..load();
    } catch (e, st) {
      SafeLogger.e(_logTag, 'preloadNative $tag THREW: $e\n$st');
      listenables.hasError.value = true;
      slot.markFailed();
    }
  }

  @override
  Widget? buildAdmobNativeView(Object key) {
    final ad = _nativeAdsByKey[key];
    if (ad == null) return null;
    return AdWidget(ad: ad);
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  LIFECYCLE HOOKS
  // ──────────────────────────────────────────────────────────────────────────

  @override
  void onAppPaused() {
    if (_bannerAdsByKey.isNotEmpty) {
      for (final l in _bannerListenablesByKey.values) {
        l.visible.value = false;
      }
    }
    if (_mrecAdsByKey.isNotEmpty) {
      for (final l in _mrecListenablesByKey.values) {
        l.visible.value = false;
      }
    }
  }

  @override
  void onAppResumed() {
    // C4, second layer. The five load entry points below are each gated too,
    // so this is defense-in-depth rather than the fix — it bails before the
    // platform-view/width plumbing runs and makes the skip visible in one log
    // line instead of several. Same rationale the SDK already applies in
    // `_retryRefillAds`.
    if (!canReload()) {
      SafeLogger.d(
          _logTag, 'onAppResumed $tag \u23ed\ufe0f skipped — gate closed');
      return;
    }
    // Reload banner if it errored out (Fix #14 preserved). T65 (phase 2):
    // retry every known instance key that's in error state, not just a
    // single shared one.
    for (final key in _bannerListenablesByKey.keys.toList()) {
      final listenables = _bannerListenablesByKey[key]!;
      if (listenables.hasError.value && !_bannerAdsByKey.containsKey(key)) {
        listenables.hasError.value = false;
        // Width is unknown here — caller (AdManager) supplies it via
        // platformDispatcher when it forwards the resume.
        // Prefer the app's implicit (primary) view — `views.first` can be the
        // wrong window on foldables / iPad split-view / multi-window.
        final dispatcher = WidgetsBinding.instance.platformDispatcher;
        final view = dispatcher.implicitView ??
            (dispatcher.views.isNotEmpty ? dispatcher.views.first : null);
        if (view != null) {
          final width = view.physicalSize.width / view.devicePixelRatio;
          loadBannerIfNeeded(key, width);
        } else {
          SafeLogger.w(
              _logTag, 'onAppResumed $tag no platform view — skip reload');
        }
      } else if (_bannerAdsByKey.containsKey(key)) {
        listenables.visible.value = true;
      }
    }

    // Mirror for MREC — width doesn't matter (fixed size) but loadMrecIfNeeded
    // still accepts it for interface parity. T65 (phase 3): every known
    // instance key, not just a single shared one.
    for (final key in _mrecListenablesByKey.keys.toList()) {
      final listenables = _mrecListenablesByKey[key]!;
      if (listenables.hasError.value && !_mrecAdsByKey.containsKey(key)) {
        listenables.hasError.value = false;
        loadMrecIfNeeded(key, 0);
      } else if (_mrecAdsByKey.containsKey(key)) {
        listenables.visible.value = true;
      }
    }

    // Mirror for Native — preloadNative() takes no width, unlike
    // loadMrecIfNeeded. T65 (phase 1): retry every known instance key that's
    // in error state, not just a single shared one.
    for (final key in _nativeListenablesByKey.keys.toList()) {
      final listenables = _nativeListenablesByKey[key]!;
      if (listenables.hasError.value && !_nativeAdsByKey.containsKey(key)) {
        listenables.hasError.value = false;
        preloadNative(key,
            templateType:
                _nativeTemplateTypeByKey[key] ?? TemplateType.medium);
      }
    }
  }
}
