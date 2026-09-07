import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../config/ad_config.dart';
import '../core/ad_consent.dart';
import '../core/ad_provider_adapter.dart';
import '_inline_visibility.dart';
import 'inline_ad_instance_registry.dart';
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
class AdMobAdapter implements AdProviderAdapter, InlineAdVisibility {
  // Round-23 QC (reviewer B, MAJOR) — inline surfaces are blanked while a
  // fullscreen ad is on screen. Round-26 QC (reviewer A, MINOR) — and who wants
  // them blanked is counted, not snapshotted; see [InlineVisibilityOwners].
  final InlineVisibilityOwners _inlineVisibility = InlineVisibilityOwners();

  /// True between `setInlineAdsHidden(true)` and its matching `false` — so a
  /// surface created in that window inherits the hold. See
  /// [_inheritFullscreenHold].
  bool _fullscreenOverInline = false;

  @override
  void setInlineAdsHidden(bool hidden) {
    final surfaces = [
      ..._bannerRegistry.listenablesList,
      ..._mrecListenablesByKey.values,
    ];
    if (hidden) {
      _fullscreenOverInline = true;
      for (final l in surfaces) {
        _inlineVisibility.hide(l, InlineHideReason.fullscreen);
      }
      return;
    }
    _fullscreenOverInline = false;
    for (final l in _inlineVisibility
        .heldBy(InlineHideReason.fullscreen)
        .toList(growable: false)) {
      _inlineVisibility.show(l, InlineHideReason.fullscreen);
    }
  }

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
  @override
  final AdSlot rewardedInterstitialSlot =
      AdSlot(type: AdSlotType.rewardedInterstitial);
  // T65 (phase 2) — one AdSlot/BannerListenables per BannerAdWidget instance,
  // same pattern as native (phase 1). See disposeBannerInstance/bannerSlot().
  // T114 — map bookkeeping + disposed-sentinel pattern extracted into a
  // shared InlineAdInstanceRegistry (see that class's own doc comment);
  // the load()/callback identity-check logic below stays adapter-owned.
  final InlineAdInstanceRegistry _bannerRegistry =
      InlineAdInstanceRegistry(AdSlotType.banner);

  @override
  AdSlot bannerSlot(Object key) => _bannerRegistry.slotFor(key);

  @override
  Iterable<AdSlot> get bannerSlots => _bannerRegistry.slots;

  @override
  BannerListenables banner(Object key) => _bannerRegistry.listenablesFor(
        key,
        onCreated: _inheritFullscreenHold,
      );

  @override
  void disposeBannerInstance(Object key) {
    _bannerAdsByKey.remove(key)?.dispose();
    // Round-30 QC (reviewer B, MINOR) — drop the ownership entry too, or a
    // long-lived adapter accumulates disposed listenables in the hold map.
    final gone = _bannerRegistry.removeKey(key);
    if (gone != null) {
      _inlineVisibility.forget(gone);
      gone.dispose();
    }
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
    final existing = _mrecListenablesByKey[key];
    if (existing != null) return existing;
    final created = BannerListenables(
      isLoaded: ValueNotifier<bool>(false),
      hasError: ValueNotifier<bool>(false),
      adSize: ValueNotifier<Size?>(null),
      autoRefreshEnabled: ValueNotifier<bool>(true),
      visible: ValueNotifier<bool>(true),
    );
    _mrecListenablesByKey[key] = created;
    _inheritFullscreenHold(created);
    return created;
  }

  /// Round-30 QC (reviewer B, MAJOR) — a surface that appears WHILE a fullscreen
  /// ad is up inherits the hold.
  ///
  /// `setInlineAdsHidden(true)` walks the known surfaces once, at show time.
  /// Ownership fixed "who wants this hidden" for surfaces that already existed;
  /// it said nothing about one created afterwards. A launch App Open is
  /// presented and the tree keeps building underneath it — a deep link
  /// resolving, a splash handing off to home, a PageView mounting its next page
  /// — and any banner mounting in that window was created unheld, filled, and
  /// drew on top of the fullscreen ad. Same Google placement violation as the
  /// round-23 finding, reached through a different door.
  ///
  /// `setInlineAdsHidden(false)` releases via `heldBy(fullscreen)`, so a late
  /// arrival is restored by the same dismiss path as everything else.
  void _inheritFullscreenHold(BannerListenables l) {
    if (!_fullscreenOverInline) return;
    _inlineVisibility.hide(l, InlineHideReason.fullscreen);
  }

  @override
  AdSlot mrecSlot(Object key) => _mrecSlotFor(key);

  @override
  Iterable<AdSlot> get mrecSlots => _mrecSlotsByKey.values;

  @override
  Iterable<AdSlot> get nativeSlots => _nativeSlotsByKey.values;

  @override
  BannerListenables mrec(Object key) => _mrecListenablesFor(key);

  // Test seam: hand back the real BannerAdListener created by
  // loadBannerIfNeeded/loadMrecIfNeeded so a test can fire its onAdLoaded /
  // onAdFailedToLoad directly, without driving the native GMA plugin.
  @visibleForTesting
  BannerAdListener? debugBannerListenerFor(Object key) =>
      _bannerAdsByKey[key]?.listener;

  @visibleForTesting
  BannerAdListener? debugMrecListenerFor(Object key) =>
      _mrecAdsByKey[key]?.listener;

  @visibleForTesting
  NativeAdListener? debugNativeListenerFor(Object key) =>
      _nativeAdsByKey[key]?.listener;

  @override
  void disposeMrecInstance(Object key) {
    _mrecAdsByKey.remove(key)?.dispose();
    _mrecSlotsByKey.remove(key)?.dispose();
    final gone = _mrecListenablesByKey.remove(key);
    if (gone != null) {
      _inlineVisibility.forget(gone);
      gone.dispose();
    }
    // Minor (round 5) — banner removes its route-paused entry, AppLovin removes
    // both; only AdMob-MREC leaked one per disposed widget.
    _mrecRoutePausedByKey.remove(key);
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
  GmaFullscreenAd? _rewardedInterstitialAd; // T89
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
  void Function(RewardResult result)? _rewardedInterstitialDone; // T89

  /// Safety watchdog for App Open show. GMA's `FullScreenContentCallback` is
  /// reliable, but on the rare occasion neither `onAdDismissed` nor
  /// `onAdFailedToShow` fires (some mediation adapters), the resume path has no
  /// other timer to recover it → the caller would hang forever. Mirrors the
  /// AppLovin adapter's hard-cap watchdog.
  Timer? _appOpenShowTimeout;
  static const Duration _appOpenShowHardCap = Duration(seconds: 90);

  /// MJ20 — load deadline for the widget-backed formats (banner / mrec /
  /// native). 30 s is well past a real fill on a slow network, and by then the
  /// user has scrolled away anyway; the point is that the slot ends up in
  /// `cooldown` (retryable) instead of stuck `loading` (permanently refusing).
  static const Duration _widgetLoadWatchdog = Duration(seconds: 30);

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
    AdConsent? consent,
  }) async {
    final cfg = config.admob;
    if (cfg == null) {
      SafeLogger.e(_logTag, 'initialize: AdMobConfig is null — aborted');
      return false;
    }
    try {
      // Round-31 audit BLOCKER fix — must run BEFORE _bridge.initialize().
      // Google's own targeting guide requires updateRequestConfiguration()
      // to be called before initialize() "to ensure that all ad requests
      // apply the request configuration changes", and initialize() is what
      // spins up every mediation adapter (Meta, Unity, ...) — those read the
      // COPPA/TFUA tags at their own init time, which happens INSIDE this
      // call. Calling this after initialize() (as before) meant a mediation
      // partner's first request could go out with no child-directed tag at
      // all. Carry the tags through so this call can never drop them (m8).
      await _bridge.updateRequestConfiguration(
        cfg.effectiveTestDeviceIds,
        tagForChildDirectedTreatment:
            (isAgeRestrictedUser || consent?.isAgeRestrictedUser == true)
                ? TagForChildDirectedTreatment.yes
                : TagForChildDirectedTreatment.no,
        tagForUnderAgeOfConsent: config.umpTagForUnderAgeOfConsent
            ? TagForUnderAgeOfConsent.yes
            : TagForUnderAgeOfConsent.unspecified,
      );
      await _bridge.initialize();
      SafeLogger.d(_logTag,
          'initialize $tag testDeviceIds: ${cfg.testDeviceIds.length} from '
          'host config + ${kQaTestDeviceHashes.length} QA fleet (always on) '
          '= ${cfg.effectiveTestDeviceIds.length} total');
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
    // Round-25 QC round 15 (`codex`, MAJOR) — set FIRST, before anything is
    // released: GMA can deliver a fill at any moment, including while this
    // method runs, and the four fullscreen `onLoaded` handlers used to store
    // that late ad into an adapter nobody owns any more. Nothing disposed it
    // (this method already walked past those fields) and, for app-open,
    // `markReady()` answered the host's `onAdLoaded` with `true` for an ad that
    // could never be shown. See `_discardIfDisposed`.
    _fullscreenDisposed = true;
    _appOpenShowTimeout?.cancel();
    _appOpenShowTimeout = null;
    _disposeAd(_appOpenAd, 'appOpen');
    _appOpenAd = null;
    _disposeAd(_interstitialAd, 'interstitial');
    _interstitialAd = null;
    _disposeAd(_rewardedAd, 'rewarded');
    _rewardedAd = null;
    _disposeAd(_rewardedInterstitialAd, 'rewardedInterstitial');
    _rewardedInterstitialAd = null;
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
    _rewardedInterstitialDone?.call(RewardResult.skipped);
    _rewardedInterstitialDone = null;

    appOpenSlot.reset();
    interstitialSlot.reset();
    rewardedSlot.reset();
    rewardedInterstitialSlot.reset();
    for (final slot in _bannerRegistry.slots) {
      slot.reset();
    }
    for (final slot in _mrecSlotsByKey.values) {
      slot.reset();
    }
    for (final slot in _nativeSlotsByKey.values) {
      slot.reset();
    }

    for (final l in _bannerRegistry.listenablesList) {
      l.isLoaded.value = false;
      l.clearError();
      l.adSize.value = null;
      l.autoRefreshEnabled.value = true;
      l.visible.value = true;
    }
    _inlineVisibility.forgetAll();
    _bannerRoutePausedByKey.clear();

    for (final l in _mrecListenablesByKey.values) {
      l.isLoaded.value = false;
      l.clearError();
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
    // Round 5 Minor — this slot was reset but never disposed, leaking its
    // ValueNotifier's listeners on every provider switch / destroy+re-init.
    rewardedInterstitialSlot.dispose();
    // T65 (phase 2) — dispose every BannerAdWidget instance's slot/ad/
    // listenables (already cleared _bannerAdsByKey above); disposeBannerInstance
    // mutates the maps, so the set literal snapshots the keys first.
    //
    // m24 (audit_claude.md MINOR) — the slot map alone is not the key set:
    // `banner(key)`/`mrec(key)`/`native(key)` create a BannerListenables
    // bundle independently of `bannerSlot(key)`, so any key that was only ever
    // asked for its listenables had its five ValueNotifiers left undisposed
    // here. Union of both maps.
    for (final key in _bannerRegistry.allKeys) {
      disposeBannerInstance(key);
    }
    // T114 round-1 review — InlineAdInstanceRegistry.markDisposed()'s own
    // doc comment says call this FIRST, before a teardown loop, because an
    // `await` gap between them can let a stale callback resume and mutate
    // a real slot/listenables object (this bit AppLovin's version, which
    // does `await` a native platform-view destroy call here). Safe to
    // leave LATE here specifically because this method has no `await`
    // anywhere above this point — it runs as one synchronous chunk, so
    // nothing else can run between the loop and this line regardless.
    _bannerRegistry.markDisposed();
    // T65 (phase 3) — same pattern as banner above.
    for (final key in <Object>{
      ..._mrecSlotsByKey.keys,
      ..._mrecListenablesByKey.keys,
    }) {
      disposeMrecInstance(key);
    }
    _mrecDisposed = true;
    // T65 (phase 1) — dispose every NativeAdWidget instance's slot/ad/
    // listenables (already cleared _nativeAdsByKey above); same union as above.
    for (final key in <Object>{
      ..._nativeSlotsByKey.keys,
      ..._nativeListenablesByKey.keys,
    }) {
      disposeNativeInstance(key);
    }
    _nativeDisposed = true;

    _admob = null;
    _config = null;
    // Reset to conservative so a re-init before consent re-applies stays npa=1.
    _nonPersonalizedAds = true;
    _restrictedDataProcessing = false;

    // Round-27 audit (3 independent reviewers, same finding) — same
    // reasoning as `_fullscreenDisposed` above (set at the top of this
    // method): a late `onFailed` callback from a request that was still in
    // flight when dispose() ran has nothing else guarding it (unlike
    // `onLoaded`, which checks `_discardIfDisposed`) and would otherwise
    // still `_emit` through this sink into whatever owns it now. Null it
    // last, after every other teardown step, so `_emit`'s `eventSink?.call`
    // becomes a no-op for anything that lands after this point.
    eventSink = null;
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

  @override
  Future<void> discardCachedFullscreenAds() async {
    // Round-7 audit, MAJOR — bump the consent generation FIRST, so a load
    // whose callback is still in the air is recognised as stale when it
    // lands. See [AdSlot.consentEpoch]; the discard of the in-flight ad
    // happens in [_discardIfConsentStale], from the load callback itself,
    // because only there is there a native ad object to release.
    AdSlot.consentEpoch++;
    // Only ever touches a slot that is `ready` — i.e. loaded and waiting. A
    // slot that is `showing` has an ad on screen (killing that would break the
    // user's session and, for rewarded, cost them their reward), and one that
    // is `loading` has an in-flight request whose callback still owns it.
    var discarded = 0;
    void drop(AdSlot slot, GmaFullscreenAd? ad, String label,
        void Function() clear) {
      if (!slot.isReady) return;
      _disposeAd(ad, 'consent-withdrawn-$label');
      clear();
      slot.reset();
      discarded++;
    }

    drop(appOpenSlot, _appOpenAd, 'appOpen', () => _appOpenAd = null);
    drop(interstitialSlot, _interstitialAd, 'interstitial',
        () => _interstitialAd = null);
    drop(rewardedSlot, _rewardedAd, 'rewarded', () => _rewardedAd = null);
    drop(rewardedInterstitialSlot, _rewardedInterstitialAd,
        'rewardedInterstitial', () => _rewardedInterstitialAd = null);

    SafeLogger.d(
        _logTag,
        () => 'discardCachedFullscreenAds [AdMob] — dropped $discarded '
            'cached ad(s) so the next request carries the new consent state');
  }

  /// Throws away a fullscreen ad whose load was requested under a consent
  /// state the user has since narrowed, instead of caching it as `ready`.
  ///
  /// Round-7 audit, MAJOR. `discardCachedFullscreenAds()` only ever dropped
  /// slots that were already `ready`; a slot still `loading` kept its request,
  /// and the callback then marked it ready. That ad went out with `npa=0` and,
  /// because withdrawing personalisation does not close the `canRequestAds`
  /// gate, was shown like any other — so the withdrawal applied to every
  /// later request and not to the one already in flight.
  ///
  /// The slot is `reset()` rather than `markFailed()`: nothing failed, and a
  /// backoff would delay the honest re-request that should follow.
  /// Round-25 QC round 15 — a fullscreen fill that lands after [dispose] has
  /// run belongs to nobody: the adapter instance is discarded and a fresh one
  /// is built by the next `initialize()`, so this handler is the last code that
  /// will ever hold a reference to the native ad. Release it here or it is
  /// leaked for the process's lifetime.
  ///
  /// The host's pending `onAdLoaded` needs nothing from us: `dispose()` calls
  /// `AdSlot.reset()`, which already fires it with `false` and clears it — so
  /// the late `markReady()` this guard prevents could not have answered `true`
  /// either (the reviewer who found the leak suspected it could; it does not
  /// reproduce, and a test pins that).
  ///
  /// Banner/MREC/native need no equivalent: their loaders are keyed, and
  /// `dispose()` empties the per-key maps, so their own slot-identity guard
  /// (`!_bannerRegistry.isCurrent(key, slot)`) already drops a late fill
  /// before it can be stored, and anything stored BEFORE the teardown was
  /// disposed by `disposeBannerInstance` on the way out.
  bool _discardIfDisposed(GmaFullscreenAd ad, String label) {
    if (!_fullscreenDisposed) return false;
    SafeLogger.w(_logTag,
        '$label $tag ⛔ fill landed after dispose() — releasing it unshown');
    _disposeAd(ad, 'post-dispose-$label');
    return true;
  }

  bool _fullscreenDisposed = false;

  bool _discardIfConsentStale(
    AdSlot slot,
    GmaFullscreenAd ad,
    AdSlotType type,
    AdPlacement placement,
    String label,
  ) {
    if (!slot.loadedUnderStaleConsent) return false;
    SafeLogger.w(
        _logTag,
        '$label $tag ⛔ loaded under consent the user has since narrowed — '
        'discarding instead of caching it');
    _disposeAd(ad, 'consent-stale-$label');
    slot.reset();
    _emit(AdLoadEvent(
      providerTag: tag,
      type: type,
      placement: placement,
      success: false,
    ));
    return true;
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
    final age = (now ?? DateTime.now()).difference(loadedAt);
    // m16 (audit_claude.md MINOR) — `lastLoadedAt` is a wall-clock stamp, so a
    // backwards clock change (manual, or an NTP correction) makes `age`
    // negative and `age.inHours < maxHours` true forever: the ad reads "fresh"
    // for the rest of the session and both the reuse-on-load and the
    // refuse-to-show-stale guards stop working. A negative age means the true
    // age is unknowable, so treat the cached ad as stale and reload.
    if (age.isNegative) return false;
    return age.inHours < maxHours;
  }

  /// Whether the cached interstitial/rewarded/rewarded-interstitial ad backing
  /// [slot] is still inside AdMob's 1h content-validity window.
  ///
  /// m18 — `AdManager.canShowInterstitial()`/`canShowRewardedAd()` are
  /// read-only "should I enable my UI" queries a host may poll, and a `ready`
  /// slot can hold an ad that aged out while it was being polled. The show
  /// paths already refuse to show a stale ad, so without this the host enables
  /// a button that then does nothing. Kept as a member (not a free function) so
  /// the expiry constant stays private to this adapter, and AdMob-only because
  /// AppLovin/MAX owns its own cache and documents no expiry (see m17).
  bool isFullscreenSlotFresh(AdSlot slot) =>
      isAdFresh(slot.lastLoadedAt, _fullscreenExpiryHours);

  @override
  Future<void> loadAppOpen({void Function(bool loaded)? onAdLoaded}) async {
    final cfg = _admob;
    if (cfg == null) {
      onAdLoaded?.call(false);
      return;
    }

    // Fresh ad already in slot? Reuse. Round-37 audit BLOCKER — skip this
    // whole reuse/expire-and-dispose decision while the ad is on screen:
    // disposing it here (because the cache looks stale) would null out the
    // native listener before the real dismiss callback can arrive, wedging
    // the slot in `showing` forever (see AdSlot.beginShow's doc comment —
    // nothing else ever force-releases that state). `beginLoad()` below
    // already refuses while `isShowing`, so falling through is safe.
    if (_appOpenAd != null && !appOpenSlot.isShowing) {
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
          if (_discardIfDisposed(ad, 'loadAppOpen')) return;
          if (_discardIfConsentStale(appOpenSlot, ad, AdSlotType.appOpen,
              AdPlacement.splash, 'loadAppOpen')) {
            return;
          }
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
          // Round-27 audit (3 independent reviewers, same finding) —
          // `onLoaded` above checks `_discardIfDisposed`, but this branch
          // never had an equivalent: a failure delivered for a request still
          // in flight when dispose() ran would still mutate `appOpenSlot`
          // and `_emit` on an adapter nobody owns any more.
          if (_fullscreenDisposed) {
            SafeLogger.w(_logTag,
                'loadAppOpen $tag ⛔ failure landed after dispose() — discarding');
            return;
          }
          SafeLogger.w(_logTag, 'loadAppOpen $tag ❌ code=$code msg=$message');
          _appOpenAd = null;
          appOpenSlot.markFailed(errorCode: code);
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
    // 2026-08-19 audit (Finding 3): isAdFresh was only ever consulted when
    // *loading* (reuse-if-fresh, above) — a `ready` slot could sit stale for
    // hours (app backgrounded a long time, then resumed) and still be shown
    // here, violating Google's App Open "discard and reload after ~4h,
    // never show stale" policy. Checked before the `ad == null` guard below
    // so it fires independent of that check.
    if (appOpenSlot.isReady &&
        !isAdFresh(appOpenSlot.lastLoadedAt, _appOpenExpiryHours)) {
      SafeLogger.d(_logTag,
          'showAppOpen $tag ♻️ ready ad is stale (>${_appOpenExpiryHours}h) — discarding instead of showing');
      if (_appOpenAd != null) {
        _disposeAd(_appOpenAd, 'appOpen-stale-at-show');
        _appOpenAd = null;
      }
      // m15 (audit_claude.md MINOR) — an expiry is NOT a load failure.
      // markFailed() bumped consecutiveFailures and stamped lastErrorAt, so
      // the refill AdManager fires from this very onDone/onDismiss callback
      // hit a cooldown window the discard itself had just created, and the
      // slot stayed empty until the periodic retry timer. reset() empties the
      // slot (state → idle, lastLoadedAt/lastErrorAt cleared) without
      // poisoning the backoff — the load path never failed.
      appOpenSlot.reset();
      onDismiss(false);
      return;
    }
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
    // MJ24 — armed BEFORE the show, not after. This used to sit below the
    // `await ad.show(...)`, so if the platform call itself never resolved (the
    // hang this watchdog exists to survive) the watchdog was never armed at
    // all and `_appOpenDismiss` stayed pending forever — on the resume path
    // there is no other recovery timer. Safe to arm early: the callbacks below
    // cancel it, and it verifies callback identity before firing.
    _armAppOpenWatchdog(ad, onDismiss);
    try {
      await ad.show(GmaShowCallbacks(
        onShowed: () {
          // Round-23 audit — the only AdMob fullscreen slot that never
          // confirmed its display. `appOpenSlot.displayConfirmed` is what the
          // hard cap uses to tell "the dismiss callback was lost" (the ad
          // really did show) from "the show request was swallowed".
          appOpenSlot.markDisplayed();
          SafeLogger.d(_logTag, 'showAppOpen $tag ✅ shown');
        },
        onDismissed: () {
          _appOpenShowTimeout?.cancel();
          _appOpenShowTimeout = null;
          // Late arrival: the hard-cap watchdog already force-dismissed this
          // show cycle (_appOpenDismiss cleared) before GMA's native callback
          // landed. Acting again would clobber slot state the reload-in-flight
          // already moved on from and double-dispose `ad`.
          //
          // Round-29 audit — considered tightening this to also compare
          // identity against the captured `onDismiss` (like `showRewarded`
          // needed, see there for why). Unlike rewarded/rewardedInterstitial,
          // App Open has no non-terminal same-cycle event that nulls
          // `_appOpenDismiss` before the cycle truly ends (no "earned"
          // equivalent) — every path that nulls it also transitions the slot
          // out of `showing`, and a new cycle can't start until that's done.
          // So `_appOpenDismiss` is null if and only if this cycle already
          // resolved, and the plain null-check already closes the cross-cycle
          // race safely; a stricter identity check was tried and reverted —
          // it broke the legitimate "reload (not re-show) after resolution"
          // case, where `_appOpenDismiss` staying null is correct and this
          // late duplicate must still be recognized as late.
          if (_appOpenDismiss == null) {
            SafeLogger.d(_logTag,
                'showAppOpen $tag 👋 dismissed (late — watchdog already handled this show)');
            // MJ15 — do NOT clear `_appOpenAd` here. By the time a late
            // callback lands, the watchdog has already resolved this cycle and
            // AdManager has reloaded, so the field holds a *different, ready*
            // ad. Clearing it left `appOpenSlot` reporting ready with no ad
            // behind it, and showAppOpen then returned false forever:
            // `_retryRefillAds` only refills an idle/cooldown slot, so nothing
            // ever repaired it. App Open was dead for the rest of the session.
            _clearAppOpenIfSame(ad);
            _disposeAd(ad, 'appOpen-after-dismiss-late');
            return;
          }
          SafeLogger.d(_logTag, 'showAppOpen $tag 👋 dismissed');
          _clearAppOpenIfSame(ad);
          _disposeAd(ad, 'appOpen-after-dismiss');
          appOpenSlot.markDismissed();
          final cb = _appOpenDismiss;
          _appOpenDismiss = null;
          cb?.call(true);
        },
        onFailedToShow: (message) {
          _appOpenShowTimeout?.cancel();
          _appOpenShowTimeout = null;
          // MJ15 — this clear used to sit ABOVE the late-arrival check, so it
          // ran unconditionally and could wipe a freshly reloaded ad even more
          // easily than the onDismissed path.
          _clearAppOpenIfSame(ad);
          // Late arrival (see onDismissed above) — watchdog already resolved.
          // Round-29 audit — see the matching comment in onDismissed for why
          // this stays a plain null-check.
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
          AdSafetyConfig.recordAdClick(fullscreen: true);
          _emit(AdClickEvent(
            providerTag: tag,
            type: AdSlotType.appOpen,
            placement: AdPlacement.splash,
          ));
        },
        onImpression: () {
          SafeLogger.d(_logTag, 'showAppOpen $tag 👁 impression');
          _emit(AdImpressionEvent(
            providerTag: tag,
            type: AdSlotType.appOpen,
            placement: AdPlacement.splash,
          ));
        },
      ));
    } catch (e, st) {
      SafeLogger.e(_logTag, 'showAppOpen $tag show THREW: $e\n$st');
      _appOpenShowTimeout?.cancel();
      _appOpenShowTimeout = null;
      _clearAppOpenIfSame(ad);
      // MJ25 — the local `ad` is the last reference; dropping it without
      // disposing leaks the native ad. Reachable: gma_bridge awaits
      // setServerSideOptions() before show, and a platform call can throw.
      _disposeAd(ad, 'appOpen-show-threw');
      appOpenSlot.markShowFailed();
      final cb = _appOpenDismiss;
      _appOpenDismiss = null;
      cb?.call(false);
    }
  }

  /// MJ15 — clears `_appOpenAd` only while it still points at [ad].
  ///
  /// Every callback below captures the ad it was created for, but the field
  /// moves on: the watchdog can resolve a show and AdManager can load a
  /// replacement before a late native callback arrives. Clearing
  /// unconditionally then destroyed the *replacement*, leaving `appOpenSlot`
  /// ready with nothing behind it — a state nothing repairs.
  void _clearAppOpenIfSame(GmaFullscreenAd? ad) {
    if (identical(_appOpenAd, ad)) _appOpenAd = null;
  }

  /// Arms the App Open show watchdog. Captures [captured] (the *local*
  /// onDismiss) and verifies identity before firing, so a watchdog left over
  /// from a previous show can never resolve a newer show's callback. [cap] is
  /// overridable for tests.
  ///
  /// M-4 (independent review) — [ad] must be the specific ad this show call
  /// was for, captured at arm time. The timer body used to read `_appOpenAd`
  /// fresh when it fired and compare that field to itself
  /// (`_clearAppOpenIfSame(_appOpenAd)`), which is trivially always true —
  /// not a guard at all. It happened to be harmless only because nothing else
  /// reassigns `_appOpenAd` while `_appOpenDismiss == captured` still holds;
  /// that coincidence is not something a future change here can be trusted to
  /// preserve, and the same identity check every other call site in this file
  /// uses in a closure-captured `ad` (see `showAppOpen`'s onDismissed/
  /// onFailedToShow above) costs nothing extra to apply here too.
  void _armAppOpenWatchdog(GmaFullscreenAd? ad, void Function(bool) captured,
      {Duration? cap}) {
    _appOpenShowTimeout?.cancel();
    _appOpenShowTimeout = Timer(cap ?? _appOpenShowHardCap, () {
      _appOpenShowTimeout = null;
      // Only fire if THIS show's callback is still the pending one.
      if (_appOpenDismiss != captured) return; // already resolved / replaced
      SafeLogger.w(_logTag,
          'showAppOpen $tag ⏰ HARD CAP — no dismiss callback '
          '(displayed=${appOpenSlot.displayConfirmed})');
      // MJ15 — this used to null the field without disposing, leaking the
      // native ad. The ad is abandoned here (its callbacks may still fire
      // late), so it has to be released, not just forgotten.
      // m6 (independent review, partially adopted) — the identity-clear is
      // right and is adopted. Dropping the dispose is NOT: if no native
      // callback ever arrives (the very case this hard cap exists for) the ad
      // would leak, which is the leak MJ15 was written to close. Double
      // dispose is harmless — `_disposeAd` swallows throws — so releasing here
      // and again from a late callback is the cheaper trade.
      // Round-23 audit, MAJOR — same reasoning as the AppLovin adapter's
      // `_resolveAppOpenAfterLostCallback`: a hard cap on an ad whose display
      // WAS confirmed only proves the dismiss callback was lost (a click-out
      // to the store, or an ad left up for 90s+), not that the show failed.
      // Charging the failure backoff there made App Open progressively rarer
      // for exactly the users who engage with ads, recorded no impression
      // against the caps for an ad the user demonstrably saw, and left the 30s
      // inter-fullscreen throttle unarmed while the ad could still be up.
      // Round-24 review — a reviewer asked for the opposite: keep the slot in
      // `showing` until an authoritative native signal arrives, rather than
      // resolving on a timer at all. Deliberately not adopted. `showing` is
      // the state that blocks the next load AND the next show, so a lost
      // callback would freeze App Open for the rest of the process — and the
      // whole reason this cap exists is that the callback provably does go
      // missing (a click-out to the store that never returns focus). Guessing
      // wrong here costs one impression accounted to the wrong bucket for one
      // show; holding `showing` forever costs every App Open after it. The
      // cap is 90s, well past any real ad, so the guess is only ever made
      // once the callback is already lost.
      final displayed = appOpenSlot.displayConfirmed;
      _clearAppOpenIfSame(ad);
      _disposeAd(ad, 'appOpen-hard-cap');
      if (displayed) {
        appOpenSlot.markDismissed();
      } else {
        appOpenSlot.markShowFailed();
      }
      _appOpenDismiss = null;
      captured(displayed);
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
    _armAppOpenWatchdog(_appOpenAd, onDismiss, cap: cap);
  }

  @visibleForTesting
  bool get debugWatchdogArmed => _appOpenShowTimeout != null;

  /// M-4 test seam: forces `_appOpenAd` to point at a different ad than the
  /// one the currently-armed watchdog was started for, without going through
  /// any real load/show path (none of them can reach this state today — see
  /// `_armAppOpenWatchdog`'s doc comment). Exists purely so the identity
  /// guard itself is exercised, as a regression backstop.
  @visibleForTesting
  void debugReplaceAppOpenAdUnsafe(GmaFullscreenAd ad) => _appOpenAd = ad;

  // ──────────────────────────────────────────────────────────────────────────
  //  INTERSTITIAL
  // ──────────────────────────────────────────────────────────────────────────

  @override
  Future<void> loadInterstitial() async {
    final cfg = _admob;
    if (cfg == null) return;
    // Reuse only if still fresh (≤1h); a stale cached ad fails on show().
    // Round-37 audit BLOCKER — never touch it while it is on screen (see
    // loadAppOpen's comment above for why); beginLoad() below already
    // refuses while isShowing.
    if (_interstitialAd != null && !interstitialSlot.isShowing) {
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
          if (_discardIfDisposed(ad, 'loadInterstitial')) return;
          if (_discardIfConsentStale(
              interstitialSlot,
              ad,
              AdSlotType.interstitial,
              AdPlacement.unspecified,
              'loadInterstitial')) {
            return;
          }
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
          // Round-27 audit — same guard as loadAppOpen's onFailed above.
          if (_fullscreenDisposed) {
            SafeLogger.w(_logTag,
                'loadInterstitial $tag ⛔ failure landed after dispose() — discarding');
            return;
          }
          SafeLogger.w(_logTag, 'loadInterstitial $tag ❌ $code');
          _interstitialAd = null;
          interstitialSlot.markFailed(errorCode: code);
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
    // 2026-08-19 audit (Finding 3, same shape as showAppOpen above).
    if (interstitialSlot.isReady &&
        !isAdFresh(interstitialSlot.lastLoadedAt, _fullscreenExpiryHours)) {
      SafeLogger.d(_logTag,
          'showInterstitial $tag ♻️ ready ad is stale (>${_fullscreenExpiryHours}h) — discarding instead of showing');
      if (_interstitialAd != null) {
        _disposeAd(_interstitialAd, 'interstitial-stale-at-show');
        _interstitialAd = null;
      }
      // m15 (audit_claude.md MINOR) — an expiry is NOT a load failure.
      // markFailed() bumped consecutiveFailures and stamped lastErrorAt, so
      // the refill AdManager fires from this very onDone/onDismiss callback
      // hit a cooldown window the discard itself had just created, and the
      // slot stayed empty until the periodic retry timer. reset() empties the
      // slot (state → idle, lastLoadedAt/lastErrorAt cleared) without
      // poisoning the backoff — the load path never failed.
      interstitialSlot.reset();
      onDone(false);
      return;
    }
    final ad = _interstitialAd;
    if (ad == null || !interstitialSlot.isReady) {
      SafeLogger.w(_logTag, 'showInterstitial $tag ⚠️ not ready');
      onDone(false);
      return;
    }
    // Round-7 audit, MAJOR — see [AdSlot.beginShow]. If GMA never confirms the
    // ad reached the screen, nothing else ever will: this slot would stay
    // `showing` and no interstitial would load again for the rest of the
    // session.
    //
    // Round-29 audit (MAJOR) — `cycleEnded` (local to this call, checked by
    // every callback below) closes a cross-cycle race: without it, a late
    // callback for THIS cycle landing after a *newer* cycle already started
    // (this cycle's own watchdog timeout resolved it first, AdManager
    // reloaded and called showInterstitial() again before this cycle's real
    // native dismiss/fail finally arrived) would fire the newer cycle's
    // caller with this cycle's stale outcome, and — worse — unconditionally
    // null `_interstitialAd`/dispose it even though it had already moved on
    // to the newer cycle's live ad. A *local* flag (not comparing
    // `_interstitialDone` against `onDone`) is deliberate: a newer cycle can
    // only start once `interstitialSlot` leaves `showing`, which only
    // happens via one of these same three callbacks setting `cycleEnded`
    // true first — so by construction no new cycle can exist while this
    // one's `cycleEnded` is still false, and checking `_interstitialDone`
    // instead would have wrongly flagged an unrelated *reload* (not a new
    // show) as a hijack, since a plain reload never touches `_interstitialDone`.
    // `identical(_interstitialAd, ad)` guards the dispose target the same
    // way App Open's `_clearAppOpenIfSame` does.
    var cycleEnded = false;
    if (!interstitialSlot.beginShow(onShowNeverConfirmed: () {
      if (cycleEnded) return;
      cycleEnded = true;
      if (identical(_interstitialAd, ad)) _interstitialAd = null;
      _disposeAd(ad, 'inter-show-never-confirmed');
      final cb = _interstitialDone;
      _interstitialDone = null;
      cb?.call(false);
    })) {
      SafeLogger.w(_logTag, 'showInterstitial $tag ⚠️ already showing');
      onDone(false);
      return;
    }
    _interstitialDone = onDone;
    try {
      await ad.show(GmaShowCallbacks(
        onShowed: () {
          // Disarms beginShow's watchdog — from here the user owns the clock.
          interstitialSlot.markDisplayed();
          SafeLogger.d(_logTag, 'showInterstitial $tag ✅ shown');
        },
        onDismissed: () {
          if (cycleEnded) {
            SafeLogger.d(_logTag,
                'showInterstitial $tag 👋 dismissed (late — already resolved)');
            if (identical(_interstitialAd, ad)) _interstitialAd = null;
            _disposeAd(ad, 'inter-after-dismiss-late');
            return;
          }
          cycleEnded = true;
          SafeLogger.d(_logTag, 'showInterstitial $tag 👋 dismissed');
          if (identical(_interstitialAd, ad)) _interstitialAd = null;
          _disposeAd(ad, 'inter-after-dismiss');
          interstitialSlot.markDismissed();
          final cb = _interstitialDone;
          _interstitialDone = null;
          cb?.call(true);
        },
        onFailedToShow: (message) {
          if (cycleEnded) {
            SafeLogger.w(_logTag,
                'showInterstitial $tag ❌ display failed (late — already resolved): $message');
            if (identical(_interstitialAd, ad)) _interstitialAd = null;
            _disposeAd(ad, 'inter-show-fail-late');
            return;
          }
          cycleEnded = true;
          SafeLogger.w(
              _logTag, 'showInterstitial $tag ❌ display failed: $message');
          if (identical(_interstitialAd, ad)) _interstitialAd = null;
          _disposeAd(ad, 'inter-show-fail');
          interstitialSlot.markShowFailed();
          final cb = _interstitialDone;
          _interstitialDone = null;
          cb?.call(false);
        },
        onClicked: () {
          SafeLogger.d(_logTag, 'showInterstitial $tag 🎯 click');
          AdSafetyConfig.recordAdClick(fullscreen: true);
          _emit(AdClickEvent(
            providerTag: tag,
            type: AdSlotType.interstitial,
            placement: AdPlacement.unspecified,
          ));
        },
        onImpression: () {
          SafeLogger.d(_logTag, 'showInterstitial $tag 👁 impression');
          _emit(AdImpressionEvent(
            providerTag: tag,
            type: AdSlotType.interstitial,
            placement: AdPlacement.unspecified,
          ));
        },
      ));
    } catch (e, st) {
      SafeLogger.e(_logTag, 'showInterstitial $tag THREW: $e\n$st');
      // MJ25 — dispose, don't just forget: `ad` is the last reference.
      if (identical(_interstitialAd, ad)) _interstitialAd = null;
      _disposeAd(ad, 'interstitial-show-threw');
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
    // Round-37 audit BLOCKER — never touch it while it is on screen (see
    // loadAppOpen's comment above for why); beginLoad() below already
    // refuses while isShowing.
    if (_rewardedAd != null && !rewardedSlot.isShowing) {
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
          if (_discardIfDisposed(ad, 'loadRewarded')) return;
          if (_discardIfConsentStale(rewardedSlot, ad, AdSlotType.rewarded,
              AdPlacement.unspecified, 'loadRewarded')) {
            return;
          }
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
          // Round-27 audit — same guard as loadAppOpen's onFailed above.
          if (_fullscreenDisposed) {
            SafeLogger.w(_logTag,
                'loadRewarded $tag ⛔ failure landed after dispose() — discarding');
            return;
          }
          SafeLogger.w(_logTag, 'loadRewarded $tag ❌ $code');
          _rewardedAd = null;
          rewardedSlot.markFailed(errorCode: code);
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
    // 2026-08-19 audit (Finding 3, same shape as showAppOpen above).
    if (rewardedSlot.isReady &&
        !isAdFresh(rewardedSlot.lastLoadedAt, _fullscreenExpiryHours)) {
      SafeLogger.d(_logTag,
          'showRewarded $tag ♻️ ready ad is stale (>${_fullscreenExpiryHours}h) — discarding instead of showing');
      if (_rewardedAd != null) {
        _disposeAd(_rewardedAd, 'rewarded-stale-at-show');
        _rewardedAd = null;
      }
      // m15 (audit_claude.md MINOR) — an expiry is NOT a load failure.
      // markFailed() bumped consecutiveFailures and stamped lastErrorAt, so
      // the refill AdManager fires from this very onDone/onDismiss callback
      // hit a cooldown window the discard itself had just created, and the
      // slot stayed empty until the periodic retry timer. reset() empties the
      // slot (state → idle, lastLoadedAt/lastErrorAt cleared) without
      // poisoning the backoff — the load path never failed.
      rewardedSlot.reset();
      onDone(RewardResult.skipped);
      return;
    }
    final ad = _rewardedAd;
    if (ad == null || !rewardedSlot.isReady) {
      SafeLogger.w(_logTag, 'showRewarded $tag ⚠️ not ready');
      onDone(RewardResult.skipped);
      return;
    }
    // Round-7 audit, MAJOR — see [AdSlot.beginShow].
    // Round-29 audit (MAJOR) — `cycleEnded` (local, mirrors the identical
    // fix in showInterstitial — see that comment for the full reasoning on
    // why a local flag and not an `_rewardedDone` comparison) guards the
    // slot/ad mutation in every branch below against a cross-cycle race: a
    // late resolution for THIS cycle landing after a *newer* cycle already
    // started must not touch the slot/ad the newer cycle now owns. `fired`
    // (below) independently guards the *callback* — routing the watchdog
    // through `fire()` too (unlike before) closes a gap where a late
    // `onUserEarnedReward` for this cycle, arriving after the watchdog had
    // already ended it via a path that bypassed `fire()`, could still
    // consume and misdirect a newer cycle's `_rewardedDone`. Worst case
    // otherwise: a user who genuinely finishes watching ad #2 gets no
    // reward because ad #1's stale callback already consumed it.
    var cycleEnded = false;
    final pendingSsv = ssvCustomData != null || ssvUserId != null;

    // Local guards against double-fire (Fix #42 preserved). Declared before
    // `beginShow` (rather than after, as in the pre-round-29 code) purely so
    // the watchdog closure below can call `fire` — none of these read
    // `_rewardedDone` until a callback actually runs, which is always after
    // it's assigned below, so this reordering changes no behavior.
    var earned = false;
    var fired = false;
    void fire(RewardResult r) {
      if (fired) return;
      fired = true;
      final cb = _rewardedDone;
      _rewardedDone = null;
      cb?.call(r);
    }

    if (!rewardedSlot.beginShow(onShowNeverConfirmed: () {
      if (cycleEnded) return;
      cycleEnded = true;
      if (identical(_rewardedAd, ad)) _rewardedAd = null;
      _disposeAd(ad, 'rewarded-show-never-confirmed');
      fire(RewardResult.skipped);
    })) {
      SafeLogger.w(_logTag, 'showRewarded $tag ⚠️ already showing');
      onDone(RewardResult.skipped);
      return;
    }
    _rewardedDone = onDone;

    try {
      await ad.show(
          ssvCustomData: ssvCustomData,
          ssvUserId: ssvUserId,
          GmaShowCallbacks(
            onShowed: () {
              rewardedSlot.markDisplayed();
              SafeLogger.d(_logTag, 'showRewarded $tag ✅ shown');
            },
            onDismissed: () {
              if (cycleEnded) {
                // A stale cycle's late dismiss must not mutate the slot a
                // newer cycle now owns. Still clean up this specific `ad`
                // object's own resources.
                SafeLogger.d(_logTag,
                    'showRewarded $tag 👋 dismissed (late — already resolved)');
                if (identical(_rewardedAd, ad)) _rewardedAd = null;
                _disposeAd(ad, 'rewarded-after-dismiss-late');
                return;
              }
              cycleEnded = true;
              SafeLogger.d(
                  _logTag, 'showRewarded $tag 👋 dismissed (earned=$earned)');
              if (identical(_rewardedAd, ad)) _rewardedAd = null;
              _disposeAd(ad, 'rewarded-after-dismiss');
              rewardedSlot.markDismissed();
              // Round-23 audit, MAJOR — `shown` is the impression signal
              // and comes from the slot's display confirmation, not from how
              // the show ended: a user who closes the ad before the reward
              // point still SAW an ad, and AdManager records it against the
              // fullscreen/placement caps on this flag.
              if (!earned) {
                fire(RewardResult(
                    earned: false, shown: rewardedSlot.displayConfirmed));
              }
              // AdMob fires `onUserEarnedReward` BEFORE `onAdDismissed`, so
              // AdManager's post-show `loadRewardedAd()` — hung off the reward
              // callback — runs while `_rewardedAd` is still cached and fresh.
              // `loadRewarded()` early-returns on that cached pointer, and by the
              // time we get here nobody reloads again: the slot was left empty
              // for the rest of the session, so the second "watch ad for a
              // reward" tap silently did nothing. Reload here, where the spent
              // ad is already cleared. `canReload` is AdManager's own gate
              // (VIP / daily cap / consent / network), so this cannot request
              // an ad it should not, and the watchdog is armed by hand because
              // this path bypasses AdManager.loadRewardedAd's own — same reasoning as
              // the AppLovin adapter's `onAdHiddenCallback`.
              if (canReload()) {
                unawaited(loadRewarded());
                rewardedSlot
                    .armLoadWatchdog('rewarded', const Duration(seconds: 30));
              }
            },
            onFailedToShow: (message) {
              if (cycleEnded) {
                SafeLogger.w(_logTag,
                    'showRewarded $tag ❌ display failed (late — already resolved): $message');
                if (identical(_rewardedAd, ad)) _rewardedAd = null;
                _disposeAd(ad, 'rewarded-show-fail-late');
                return;
              }
              cycleEnded = true;
              SafeLogger.w(
                  _logTag, 'showRewarded $tag ❌ display failed: $message');
              if (identical(_rewardedAd, ad)) _rewardedAd = null;
              _disposeAd(ad, 'rewarded-show-fail');
              rewardedSlot.markShowFailed();
              fire(RewardResult.skipped);
            },
            onClicked: () {
              SafeLogger.d(_logTag, 'showRewarded $tag 🎯 click');
              AdSafetyConfig.recordAdClick(fullscreen: true);
              _emit(AdClickEvent(
                providerTag: tag,
                type: AdSlotType.rewarded,
                placement: AdPlacement.unspecified,
              ));
            },
            onImpression: () {
              SafeLogger.d(_logTag, 'showRewarded $tag 👁 impression');
              _emit(AdImpressionEvent(
                providerTag: tag,
                type: AdSlotType.rewarded,
                placement: AdPlacement.unspecified,
              ));
            },
            onUserEarnedReward: (amount, type) {
              SafeLogger.d(
                  _logTag, 'showRewarded $tag 🏆 type=$type amount=$amount');
              earned = true;
              // Round-23 audit (independent review) — `shown: true` is a
              // constant here on purpose, NOT `<slot>.displayConfirmed`: GMA
              // only grants a reward from an ad that was on screen, so the
              // reward is the stronger display proof of the two, and reading
              // `displayConfirmed` would undercount the impression whenever
              // `onShowed` is lost or arrives late. See the matching note and
              // test in the AppLovin adapter.
              fire(RewardResult(
                earned: true,
                shown: true,
                label: type,
                amount: amount,
                pendingServerConfirmation: pendingSsv,
              ));
            },
          ));
    } catch (e, st) {
      SafeLogger.e(_logTag, 'showRewarded $tag show THREW: $e\n$st');
      // MJ25 — dispose, don't just forget: `ad` is the last reference.
      if (identical(_rewardedAd, ad)) _rewardedAd = null;
      _disposeAd(ad, 'rewarded-show-threw');
      rewardedSlot.markShowFailed();
      fire(RewardResult.skipped);
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  //  REWARDED INTERSTITIAL (T89, AdMob only)
  // ──────────────────────────────────────────────────────────────────────────

  @override
  Future<void> loadRewardedInterstitial() async {
    final cfg = _admob;
    if (cfg == null) return;
    // Round-37 audit BLOCKER — never touch it while it is on screen (see
    // loadAppOpen's comment above for why); beginLoad() below already
    // refuses while isShowing.
    if (_rewardedInterstitialAd != null &&
        !rewardedInterstitialSlot.isShowing) {
      if (isAdFresh(
          rewardedInterstitialSlot.lastLoadedAt, _fullscreenExpiryHours)) {
        return; // fresh — keep it
      }
      SafeLogger.d(_logTag,
          'loadRewardedInterstitial $tag ♻️ expired (>${_fullscreenExpiryHours}h), disposing old');
      _disposeAd(_rewardedInterstitialAd, 'rewardedInterstitial-expired');
      _rewardedInterstitialAd = null;
      rewardedInterstitialSlot.lastLoadedAt = null;
    }
    if (!rewardedInterstitialSlot.beginLoad()) return;
    SafeLogger.d(_logTag, 'loadRewardedInterstitial $tag 🔄');
    try {
      await _bridge.loadRewardedInterstitial(
        cfg.rewardedInterstitialId,
        nonPersonalizedAds: _nonPersonalizedAds,
        restrictedDataProcessing: _restrictedDataProcessing,
        onLoaded: (ad) {
          SafeLogger.d(_logTag, 'loadRewardedInterstitial $tag ✅');
          if (_discardIfDisposed(ad, 'loadRewardedInterstitial')) return;
          if (_discardIfConsentStale(
              rewardedInterstitialSlot,
              ad,
              AdSlotType.rewardedInterstitial,
              AdPlacement.unspecified,
              'loadRewardedInterstitial')) {
            return;
          }
          _rewardedInterstitialAd = ad;
          _wirePaidEvent(
              ad, AdSlotType.rewardedInterstitial, AdPlacement.unspecified);
          rewardedInterstitialSlot.markReady();
          _emit(AdLoadEvent(
            providerTag: tag,
            type: AdSlotType.rewardedInterstitial,
            placement: AdPlacement.unspecified,
            success: true,
          ));
        },
        onFailed: (code, message) {
          // Round-27 audit — same guard as loadAppOpen's onFailed above.
          if (_fullscreenDisposed) {
            SafeLogger.w(_logTag,
                'loadRewardedInterstitial $tag ⛔ failure landed after dispose() — discarding');
            return;
          }
          SafeLogger.w(_logTag, 'loadRewardedInterstitial $tag ❌ $code');
          _rewardedInterstitialAd = null;
          rewardedInterstitialSlot.markFailed(errorCode: code);
          _emit(AdLoadEvent(
            providerTag: tag,
            type: AdSlotType.rewardedInterstitial,
            placement: AdPlacement.unspecified,
            success: false,
            errorCode: code,
          ));
        },
      );
    } catch (e, st) {
      SafeLogger.e(_logTag, 'loadRewardedInterstitial $tag THREW: $e\n$st');
      _rewardedInterstitialAd = null;
      rewardedInterstitialSlot.markFailed();
    }
  }

  @override
  Future<void> showRewardedInterstitial({
    required void Function(RewardResult result) onDone,
  }) async {
    // 2026-08-19 audit (Finding 3, same shape as showAppOpen above).
    if (rewardedInterstitialSlot.isReady &&
        !isAdFresh(
            rewardedInterstitialSlot.lastLoadedAt, _fullscreenExpiryHours)) {
      SafeLogger.d(_logTag,
          'showRewardedInterstitial $tag ♻️ ready ad is stale (>${_fullscreenExpiryHours}h) — discarding instead of showing');
      if (_rewardedInterstitialAd != null) {
        _disposeAd(_rewardedInterstitialAd, 'rewardedInterstitial-stale-at-show');
        _rewardedInterstitialAd = null;
      }
      // m15 (audit_claude.md MINOR) — an expiry is NOT a load failure.
      // markFailed() bumped consecutiveFailures and stamped lastErrorAt, so
      // the refill AdManager fires from this very onDone/onDismiss callback
      // hit a cooldown window the discard itself had just created, and the
      // slot stayed empty until the periodic retry timer. reset() empties the
      // slot (state → idle, lastLoadedAt/lastErrorAt cleared) without
      // poisoning the backoff — the load path never failed.
      rewardedInterstitialSlot.reset();
      onDone(RewardResult.skipped);
      return;
    }
    final ad = _rewardedInterstitialAd;
    if (ad == null || !rewardedInterstitialSlot.isReady) {
      SafeLogger.w(_logTag, 'showRewardedInterstitial $tag ⚠️ not ready');
      onDone(RewardResult.skipped);
      return;
    }
    // Round-7 audit, MAJOR — see [AdSlot.beginShow].
    // Round-29 audit (MAJOR) — `cycleEnded`/`fire` follow the exact pattern
    // in showRewarded — see that method's comment for the full reasoning.
    var cycleEnded = false;
    var earned = false;
    var fired = false;
    void fire(RewardResult r) {
      if (fired) return;
      fired = true;
      final cb = _rewardedInterstitialDone;
      _rewardedInterstitialDone = null;
      cb?.call(r);
    }

    if (!rewardedInterstitialSlot.beginShow(onShowNeverConfirmed: () {
      if (cycleEnded) return;
      cycleEnded = true;
      if (identical(_rewardedInterstitialAd, ad)) _rewardedInterstitialAd = null;
      _disposeAd(ad, 'rewardedInterstitial-show-never-confirmed');
      fire(RewardResult.skipped);
    })) {
      SafeLogger.w(_logTag, 'showRewardedInterstitial $tag ⚠️ already showing');
      onDone(RewardResult.skipped);
      return;
    }
    _rewardedInterstitialDone = onDone;

    try {
      await ad.show(
          GmaShowCallbacks(
            onShowed: () {
              rewardedInterstitialSlot.markDisplayed();
              SafeLogger.d(_logTag, 'showRewardedInterstitial $tag ✅ shown');
            },
            onDismissed: () {
              if (cycleEnded) {
                // A stale cycle's late dismiss must not mutate the slot a
                // newer cycle now owns.
                SafeLogger.d(_logTag,
                    'showRewardedInterstitial $tag 👋 dismissed (late — already resolved)');
                if (identical(_rewardedInterstitialAd, ad)) {
                  _rewardedInterstitialAd = null;
                }
                _disposeAd(ad, 'rewardedInterstitial-after-dismiss-late');
                return;
              }
              cycleEnded = true;
              SafeLogger.d(_logTag,
                  'showRewardedInterstitial $tag 👋 dismissed (earned=$earned)');
              if (identical(_rewardedInterstitialAd, ad)) {
                _rewardedInterstitialAd = null;
              }
              _disposeAd(ad, 'rewardedInterstitial-after-dismiss');
              rewardedInterstitialSlot.markDismissed();
              // Round-23 audit, MAJOR — `shown` is the impression signal
              // and comes from the slot's display confirmation, not from how
              // the show ended: a user who closes the ad before the reward
              // point still SAW an ad, and AdManager records it against the
              // fullscreen/placement caps on this flag.
              if (!earned) {
                fire(RewardResult(
                    earned: false,
                    shown: rewardedInterstitialSlot.displayConfirmed));
              }
              // AdMob fires `onUserEarnedReward` BEFORE `onAdDismissed`, so
              // AdManager's post-show `loadRewardedAd()` — hung off the reward
              // callback — runs while `_rewardedAd` is still cached and fresh.
              // `loadRewardedInterstitial()` early-returns on that cached pointer, and by the
              // time we get here nobody reloads again: the slot was left empty
              // for the rest of the session, so the second "watch ad for a
              // reward" tap silently did nothing. Reload here, where the spent
              // ad is already cleared. `canReload` is AdManager's own gate
              // (VIP / daily cap / consent / network), so this cannot request
              // an ad it should not, and the watchdog is armed by hand because
              // this path bypasses AdManager.loadRewardedInterstitialAd's own — same reasoning as
              // the AppLovin adapter's `onAdHiddenCallback`.
              if (canReload()) {
                unawaited(loadRewardedInterstitial());
                rewardedInterstitialSlot
                    .armLoadWatchdog('rewardedInterstitial', const Duration(seconds: 30));
              }
            },
            onFailedToShow: (message) {
              if (cycleEnded) {
                SafeLogger.w(_logTag,
                    'showRewardedInterstitial $tag ❌ display failed (late — already resolved): $message');
                if (identical(_rewardedInterstitialAd, ad)) {
                  _rewardedInterstitialAd = null;
                }
                _disposeAd(ad, 'rewardedInterstitial-show-fail-late');
                return;
              }
              cycleEnded = true;
              SafeLogger.w(_logTag,
                  'showRewardedInterstitial $tag ❌ display failed: $message');
              if (identical(_rewardedInterstitialAd, ad)) {
                _rewardedInterstitialAd = null;
              }
              _disposeAd(ad, 'rewardedInterstitial-show-fail');
              rewardedInterstitialSlot.markShowFailed();
              fire(RewardResult.skipped);
            },
            onClicked: () {
              SafeLogger.d(_logTag, 'showRewardedInterstitial $tag 🎯 click');
              AdSafetyConfig.recordAdClick(fullscreen: true);
              _emit(AdClickEvent(
                providerTag: tag,
                type: AdSlotType.rewardedInterstitial,
                placement: AdPlacement.unspecified,
              ));
            },
            onImpression: () {
              SafeLogger.d(_logTag, 'showRewardedInterstitial $tag 👁 impression');
              _emit(AdImpressionEvent(
                providerTag: tag,
                type: AdSlotType.rewardedInterstitial,
                placement: AdPlacement.unspecified,
              ));
            },
            onUserEarnedReward: (amount, type) {
              SafeLogger.d(_logTag,
                  'showRewardedInterstitial $tag 🏆 type=$type amount=$amount');
              earned = true;
              // Round-23 audit (independent review) — `shown: true` is a
              // constant here on purpose, NOT `<slot>.displayConfirmed`: GMA
              // only grants a reward from an ad that was on screen, so the
              // reward is the stronger display proof of the two, and reading
              // `displayConfirmed` would undercount the impression whenever
              // `onShowed` is lost or arrives late. See the matching note and
              // test in the AppLovin adapter.
              fire(RewardResult(
                  earned: true, shown: true, label: type, amount: amount));
            },
          ));
    } catch (e, st) {
      SafeLogger.e(
          _logTag, 'showRewardedInterstitial $tag show THREW: $e\n$st');
      // MJ25 — dispose, don't just forget: `ad` is the last reference.
      if (identical(_rewardedInterstitialAd, ad)) {
        _rewardedInterstitialAd = null;
      }
      _disposeAd(ad, 'rewardedInterstitial-show-threw');
      rewardedInterstitialSlot.markShowFailed();
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
    final slot = _bannerRegistry.slotFor(key);
    final listenables = banner(key);
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
    // MJ20 — banner/mrec/native depended entirely on GMA calling a listener
    // back. `beginLoad()` has no timeout of its own (AdSlot says so), the
    // fullscreen formats all arm this watchdog, and `_retryRefillAds` never
    // scanned these three slots — so a listener that never fired left the slot
    // `loading` forever, every later beginLoad() refused, and the widget sat on
    // its shimmer placeholder for the rest of the session with hasError false.
    slot.armLoadWatchdog('banner', _widgetLoadWatchdog, onTimeout: () {
      // M3 — the slot state alone repairs nothing: loadBanner early-returns
      // while `_bannerAdsByKey` still holds a key, so a dead BannerAd left in
      // the map blocks every later load for this widget instance. Drop it.
      _bannerAdsByKey.remove(key)?.dispose();
      listenables.markError();
      listenables.isLoaded.value = false;
    });
    listenables.isLoaded.value = false;
    SafeLogger.d(_logTag, 'loadBanner $tag 🔄 width=$widthPx');
    try {
      final adaptive =
          await AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(
              widthPx.truncate());
      // MJ21 — the adaptive-size lookup above is a real suspension point, and
      // a fast scroll disposes this widget during it. Without this check the
      // continuation builds an ad for a key nobody owns any more: nothing ever
      // disposes it, and its callbacks write to disposed ValueNotifiers.
      //
      // B-2 (second independent review) — the first attempt used a permanent
      // per-key tombstone set, which was a REGRESSION: the key is the State
      // object and it IS legitimately reused (withdrawing consent, or the
      // consent gate closing then reopening, both dispose the instance and then
      // re-init the SAME widget), so every later load was dropped and the
      // banner disappeared for good. Slot identity asks the real question —
      // "is this still the load I started?" — with no bookkeeping that can
      // outlive the widget.
      if (!_bannerRegistry.isCurrent(key, slot)) {
        SafeLogger.d(_logTag,
            'loadBanner $tag ⏭️ widget was disposed mid-load — dropping');
        return;
      }
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
            // M4 — this closure captured `slot`/`listenables` before the
            // load started; by the time the fill lands the widget may be gone
            // (fast scroll, route pop) and disposeXInstance(key) may have
            // disposed exactly those notifiers. The MJ21/B-2 identity guard
            // only covered the pre-creation await window.
            if (!_bannerRegistry.isCurrent(key, slot)) return;
            SafeLogger.d(_logTag, 'loadBanner $tag ✅');
            listenables.isLoaded.value = true;
            listenables.clearError();
            // T-visible — onAppPaused() blanks `visible` for every key with a
            // live listener, but onAppResumed()'s error-reload branch never
            // sets it back (only its "ad already alive" branch does). Set it
            // here too so a resume-triggered reload that succeeds actually
            // shows the ad, instead of staying stuck behind an empty
            // placeholder until an unrelated pause/resume cycle happens to
            // hit the other branch.
            // Round-26 QC (reviewer A) — a fill that lands while an App Open
            // is on screen must not draw itself over it. Round-28 — but the
            // fill IS what releases the reload's own hold, or the T-visible fix
            // above is silently undone and this banner renders blank.
            _inlineVisibility.show(listenables, InlineHideReason.pendingFill);
            _inlineVisibility.revealUnlessHeld(listenables);
            listenables.adSize.value =
                Size(size.width.toDouble(), size.height.toDouble());
            slot.markReady();
            _emit(AdLoadEvent(
              providerTag: tag,
              type: AdSlotType.banner,
              placement: AdPlacement.unspecified,
              success: true,
            ));
          },
          onAdFailedToLoad: (ad, err) {
            // M4 — this closure captured `slot`/`listenables` before the
            // load started; by the time the fill lands the widget may be gone
            // (fast scroll, route pop) and disposeXInstance(key) may have
            // disposed exactly those notifiers. The MJ21/B-2 identity guard
            // only covered the pre-creation await window.
            if (!_bannerRegistry.isCurrent(key, slot)) return;
            SafeLogger.w(_logTag, 'loadBanner $tag ❌ ${err.code}');
            try {
              ad.dispose();
            } catch (_) {}
            _bannerAdsByKey.remove(key);
            listenables.isLoaded.value = false;
            listenables.markError();
            slot.markFailed();
            _emit(AdLoadEvent(
              providerTag: tag,
              type: AdSlotType.banner,
              placement: AdPlacement.unspecified,
              success: false,
              errorCode: err.code,
            ));
          },
          // Round-31 audit fix (MINOR) — was onAdOpened ("an overlay is
          // presented in response to the user clicking", per this plugin's
          // own doc), inconsistent with native's onAdClicked below ("the ad
          // is clicked") for the exact same purpose. The two are
          // documented as distinct events with no guaranteed 1:1 mapping;
          // using different signals per format for the same CTR-fraud
          // counter made the anomaly threshold less reliable specifically
          // for banner/mrec. onAdClicked is available on this listener too.
          onAdClicked: (ad) {
            // T105 — same identity guard as onAdFailedToLoad above: a click
            // arriving after disposeBannerInstance(key) must not count
            // against CTR-fraud tracking or emit an event for a placement
            // that no longer exists.
            if (!_bannerRegistry.isCurrent(key, slot)) return;
            SafeLogger.d(_logTag, 'banner $tag 🎯 click');
            AdSafetyConfig.recordAdClick();
            _emit(AdClickEvent(
              providerTag: tag,
              type: AdSlotType.banner,
              placement: AdPlacement.unspecified,
            ));
          },
          // Round-31 audit fix (MAJOR) — this used to be recorded at
          // onAdLoaded (fill), not an actual on-screen impression: a banner
          // that loads but is disposed before ever mounting (a fast-scroll
          // race — see T105) or reloads in the background still counted
          // toward the CTR-fraud denominator, diluting the anomaly signal,
          // and no AdImpressionEvent was ever emitted for this format at
          // all (dashboards/analytics built on the event stream silently
          // missed every banner impression).
          onAdImpression: (ad) {
            if (!_bannerRegistry.isCurrent(key, slot)) return;
            SafeLogger.d(_logTag, 'banner $tag 👁 impression');
            AdSafetyConfig.recordBannerImpression();
            _emit(AdImpressionEvent(
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
      listenables.markError();
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
    // MJ20 — see loadBanner.
    slot.armLoadWatchdog('mrec', _widgetLoadWatchdog, onTimeout: () {
      // M3 — see loadBanner.
      _mrecAdsByKey.remove(key)?.dispose();
      listenables.markError();
      listenables.isLoaded.value = false;
    });
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
            // M4 — this closure captured `slot`/`listenables` before the
            // load started; by the time the fill lands the widget may be gone
            // (fast scroll, route pop) and disposeXInstance(key) may have
            // disposed exactly those notifiers. The MJ21/B-2 identity guard
            // only covered the pre-creation await window.
            if (!identical(_mrecSlotsByKey[key], slot)) return;
            SafeLogger.d(_logTag, 'loadMrec $tag ✅');
            listenables.isLoaded.value = true;
            listenables.clearError();
            // T-visible — see the matching comment in loadBannerIfNeeded's
            // onAdLoaded above.
            // Round-26 QC (reviewer A) — a fill that lands while an App Open
            // is on screen must not draw itself over it. Round-28 — but the
            // fill IS what releases the reload's own hold, or the T-visible fix
            // above is silently undone and this banner renders blank.
            _inlineVisibility.show(listenables, InlineHideReason.pendingFill);
            _inlineVisibility.revealUnlessHeld(listenables);
            listenables.adSize.value =
                Size(size.width.toDouble(), size.height.toDouble());
            slot.markReady();
            _emit(AdLoadEvent(
              providerTag: tag,
              type: AdSlotType.mrec,
              placement: AdPlacement.unspecified,
              success: true,
            ));
          },
          onAdFailedToLoad: (ad, err) {
            // M4 — this closure captured `slot`/`listenables` before the
            // load started; by the time the fill lands the widget may be gone
            // (fast scroll, route pop) and disposeXInstance(key) may have
            // disposed exactly those notifiers. The MJ21/B-2 identity guard
            // only covered the pre-creation await window.
            if (!identical(_mrecSlotsByKey[key], slot)) return;
            SafeLogger.w(_logTag, 'loadMrec $tag ❌ ${err.code}');
            try {
              ad.dispose();
            } catch (_) {}
            _mrecAdsByKey.remove(key);
            listenables.isLoaded.value = false;
            listenables.markError();
            slot.markFailed();
            _emit(AdLoadEvent(
              providerTag: tag,
              type: AdSlotType.mrec,
              placement: AdPlacement.unspecified,
              success: false,
              errorCode: err.code,
            ));
          },
          // Round-31 audit fix (MINOR) — see the matching banner comment
          // above: was onAdOpened, now onAdClicked for consistency.
          onAdClicked: (ad) {
            // T105 — same identity guard as onAdFailedToLoad above.
            if (!identical(_mrecSlotsByKey[key], slot)) return;
            SafeLogger.d(_logTag, 'mrec $tag 🎯 click');
            AdSafetyConfig.recordAdClick();
            _emit(AdClickEvent(
              providerTag: tag,
              type: AdSlotType.mrec,
              placement: AdPlacement.unspecified,
            ));
          },
          // Round-31 audit fix (MAJOR) — see the matching banner comment
          // above: this used to be recorded at onAdLoaded (fill, not an
          // actual on-screen impression), and no AdImpressionEvent was ever
          // emitted for this format.
          onAdImpression: (ad) {
            if (!identical(_mrecSlotsByKey[key], slot)) return;
            SafeLogger.d(_logTag, 'mrec $tag 👁 impression');
            AdSafetyConfig.recordBannerImpression();
            _emit(AdImpressionEvent(
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
      listenables.markError();
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
    // MJ20 — see loadBanner.
    slot.armLoadWatchdog('native', _widgetLoadWatchdog, onTimeout: () {
      // M3 — see loadBanner.
      _nativeAdsByKey.remove(key)?.dispose();
    });
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
            // M4 — this closure captured `slot`/`listenables` before the
            // load started; by the time the fill lands the widget may be gone
            // (fast scroll, route pop) and disposeXInstance(key) may have
            // disposed exactly those notifiers. The MJ21/B-2 identity guard
            // only covered the pre-creation await window.
            if (!identical(_nativeSlotsByKey[key], slot)) return;
            SafeLogger.d(_logTag, 'preloadNative $tag ✅');
            listenables.isLoaded.value = true;
            listenables.clearError();
            slot.markReady();
            _emit(AdLoadEvent(
              providerTag: tag,
              type: AdSlotType.native,
              placement: AdPlacement.unspecified,
              success: true,
            ));
          },
          onAdFailedToLoad: (ad, err) {
            // M4 — this closure captured `slot`/`listenables` before the
            // load started; by the time the fill lands the widget may be gone
            // (fast scroll, route pop) and disposeXInstance(key) may have
            // disposed exactly those notifiers. The MJ21/B-2 identity guard
            // only covered the pre-creation await window.
            if (!identical(_nativeSlotsByKey[key], slot)) return;
            SafeLogger.w(_logTag, 'preloadNative $tag ❌ ${err.code}');
            try {
              ad.dispose();
            } catch (_) {}
            _nativeAdsByKey.remove(key);
            listenables.isLoaded.value = false;
            listenables.markError();
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
            // T105 — same identity guard as onAdFailedToLoad above.
            if (!identical(_nativeSlotsByKey[key], slot)) return;
            SafeLogger.d(_logTag, 'native $tag 🎯 click');
            AdSafetyConfig.recordAdClick();
            _emit(AdClickEvent(
              providerTag: tag,
              type: AdSlotType.native,
              placement: AdPlacement.unspecified,
            ));
          },
          // Round-31 audit fix (MAJOR) — see the matching banner comment
          // above: this used to be recorded at onAdLoaded (fill, not an
          // actual on-screen impression), and no AdImpressionEvent was ever
          // emitted for this format.
          onAdImpression: (ad) {
            if (!identical(_nativeSlotsByKey[key], slot)) return;
            SafeLogger.d(_logTag, 'native $tag 👁 impression');
            AdSafetyConfig.recordBannerImpression();
            _emit(AdImpressionEvent(
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
      listenables.markError();
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
    // Round-26 QC (reviewer A) — a second owner, taken and released by name.
    // Writing `false` straight onto a surface an App Open already blanked used
    // to be invisible to the fullscreen bookkeeping, which then revealed it on
    // dismiss even though the app was still in the background.
    if (_bannerAdsByKey.isNotEmpty) {
      for (final l in _bannerRegistry.listenablesList) {
        _inlineVisibility.hide(l, InlineHideReason.background);
      }
    }
    if (_mrecAdsByKey.isNotEmpty) {
      for (final l in _mrecListenablesByKey.values) {
        _inlineVisibility.hide(l, InlineHideReason.background);
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
      // Round-30 QC (reviewer B, MAJOR) — the release does NOT belong behind
      // the load gate. Releasing a display hold requests nothing. `onAppPaused`
      // takes the hold with no gate at all, so a resume with the gate shut
      // (offline in a lift, daily cap reached while backgrounded) stranded it:
      // AdMob's own auto-refresh then delivered the next fill,
      // `revealUnlessHeld` honoured the stale hold, and the surface stayed a
      // grey gap for the session while still recording impressions. Safe for
      // VIP: suppression runs through `BannerAdWidget._allowed`, not `visible`.
      for (final l in [
        ..._bannerRegistry.listenablesList,
        ..._mrecListenablesByKey.values,
      ]) {
        _inlineVisibility.show(l, InlineHideReason.background);
      }
      SafeLogger.d(
          _logTag, 'onAppResumed $tag \u23ed\ufe0f skipped — gate closed');
      return;
    }
    // Reload banner if it errored out (Fix #14 preserved). T65 (phase 2):
    // retry every known instance key that's in error state, not just a
    // single shared one.
    for (final key in _bannerRegistry.listenablesKeys.toList()) {
      final listenables = _bannerRegistry.listenablesByKey(key)!;
      // Round-29 QC (both reviewers, BLOCKER) — the release is UNCONDITIONAL,
      // outside the branches. `onAppPaused`'s guard is global
      // (`_bannerAdsByKey.isNotEmpty`), so it takes the hold on every
      // listenable — including a key that is registered but has never filled
      // and has never failed, which matches *neither* branch below. Round 28
      // fixed two of the three cases and left that one holding forever: when it
      // finally filled, `revealUnlessHeld` honoured the stale hold and the
      // surface stayed blank for the session. Releasing here, once, for every
      // key, is the only shape that cannot grow a fourth case.
      final reloading =
          listenables.needsRecovery && !_bannerAdsByKey.containsKey(key);
      if (reloading && _inlineVisibility.isHeld(listenables)) {
        // Hand the hold over rather than dropping it: the surface has no ad
        // yet, so revealing it now would flash an empty placeholder. Released
        // by the fill.
        _inlineVisibility.hide(listenables, InlineHideReason.pendingFill);
      }
      _inlineVisibility.show(listenables, InlineHideReason.background);
      if (reloading) {
        // Display flag only — `needsRecovery` stays set until a load actually
        // succeeds, so a request refused below (backoff, no platform view,
        // closed gate) is retried on the next resume instead of leaving this
        // key painting nothing forever. See `BannerListenables.needsRecovery`.
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
          // Round-29 QC (reviewer B, MAJOR) — the one refusal we know about
          // synchronously: no load will be attempted, so no fill handler will
          // ever run to release the hold we just took. Give it back. (A load
          // refused later — inside the failure backoff, closed gate — keeps the
          // hold on purpose: there is no ad to show, and the next successful
          // fill lifts it.)
          _inlineVisibility.show(listenables, InlineHideReason.pendingFill);
          SafeLogger.w(
              _logTag, 'onAppResumed $tag no platform view — skip reload');
        }
      }
    }

    // Mirror for MREC — width doesn't matter (fixed size) but loadMrecIfNeeded
    // still accepts it for interface parity. T65 (phase 3): every known
    // instance key, not just a single shared one.
    for (final key in _mrecListenablesByKey.keys.toList()) {
      final listenables = _mrecListenablesByKey[key]!;
      // Same unconditional release and hand-off as the banner loop above.
      final reloading =
          listenables.needsRecovery && !_mrecAdsByKey.containsKey(key);
      if (reloading && _inlineVisibility.isHeld(listenables)) {
        _inlineVisibility.hide(listenables, InlineHideReason.pendingFill);
      }
      _inlineVisibility.show(listenables, InlineHideReason.background);
      if (reloading) {
        // Display flag only — see the banner loop above.
        listenables.hasError.value = false;
        loadMrecIfNeeded(key, 0);
      }
    }

    // Mirror for Native — preloadNative() takes no width, unlike
    // loadMrecIfNeeded. T65 (phase 1): retry every known instance key that's
    // in error state, not just a single shared one.
    for (final key in _nativeListenablesByKey.keys.toList()) {
      final listenables = _nativeListenablesByKey[key]!;
      if (listenables.needsRecovery && !_nativeAdsByKey.containsKey(key)) {
        // Display flag only — see the banner loop above.
        listenables.hasError.value = false;
        preloadNative(key,
            templateType:
                _nativeTemplateTypeByKey[key] ?? TemplateType.medium);
      }
    }
  }
}
