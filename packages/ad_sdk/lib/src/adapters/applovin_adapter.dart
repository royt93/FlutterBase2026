import 'dart:async';

import 'package:applovin_max/applovin_max.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart' show TemplateType;

import '../config/ad_config.dart';
import '../core/ad_consent.dart';
import '../core/ad_provider_adapter.dart';
import '../core/ad_safety_config.dart';
import '../state/ad_event.dart';
import '../state/ad_placement.dart';
import '../state/ad_slot.dart';
import '../utils/safe_logger.dart';
import 'applovin_bridge.dart';

/// AppLovin MAX implementation of [AdProviderAdapter].
class AppLovinAdapter implements AdProviderAdapter {
  /// [bridge] defaults to the real `AppLovinMAX` plugin; tests inject a fake.
  /// [lifecycleStateResolver] defaults to the real app lifecycle state; the App
  /// Open watchdog reads it through this seam so tests can drive the
  /// foreground/background branches deterministically.
  AppLovinAdapter({
    AppLovinBridge bridge = const RealAppLovinBridge(),
    AppLifecycleState? Function()? lifecycleStateResolver,
  })  : _bridge = bridge,
        _lifecycleState = lifecycleStateResolver ??
            (() => WidgetsBinding.instance.lifecycleState);

  final AppLovinBridge _bridge;
  final AppLifecycleState? Function() _lifecycleState;

  @override
  String get tag => '[AppLovin]';

  static const String _logTag = 'AppLovinAdapter';

  // ignore: unused_field
  AdConfig? _config;
  AppLovinConfig? _max;

  @override
  AdEventSink? eventSink;

  @override
  bool Function() canReload = () => true;

  void _emit(AdEvent e) => eventSink?.call(e);

  /// AppLovin returns revenue on every load callback via `MaxAd.revenue`.
  /// `0` = no revenue / test mode → skip.
  void _emitRevenueIfPresent(MaxAd ad, AdSlotType type, AdPlacement placement) {
    final amount = ad.revenue;
    if (amount <= 0) return;
    _emit(AdRevenueEvent(
      providerTag: tag,
      type: type,
      placement: placement,
      valueMicros: (amount * 1000000).round(),
      currencyCode: 'USD',
      networkName: ad.networkName,
      precision: ad.revenuePrecision,
      // AppLovin only reports the winning network per impression — not a
      // step-by-step waterfall like AdMob's ResponseInfo.adapterResponses.
      mediationWaterfall: [ad.networkName],
    ));
  }

  @override
  bool get isInitialised => _max != null;

  @override
  final AdSlot appOpenSlot = AdSlot(type: AdSlotType.appOpen);
  @override
  final AdSlot interstitialSlot = AdSlot(type: AdSlotType.interstitial);
  @override
  final AdSlot rewardedSlot = AdSlot(type: AdSlotType.rewarded);
  // T89 — no AppLovin MAX ad unit type maps to Google's "Rewarded
  // Interstitial" format. This slot deliberately never leaves idle;
  // loadRewardedInterstitial()/showRewardedInterstitial() below are
  // documented no-ops, same pattern as native's preloadNative() no-op.
  @override
  final AdSlot rewardedInterstitialSlot =
      AdSlot(type: AdSlotType.rewardedInterstitial);
  // T65 (phase 2) — one AdSlot/BannerListenables/adViewId per BannerAdWidget
  // instance, same reasoning as native (phase 1): AppLovin's banner had the
  // identical singleton bug agy found on AdMob — one shared
  // preloadWidgetAdView id, so two simultaneous BannerAdWidgets would fight
  // over the same MaxAdView.
  final Map<Object, AdSlot> _bannerSlotsByKey = {};
  final Map<Object, BannerListenables> _bannerListenablesByKey = {};
  final Map<Object, ValueNotifier<AdViewId?>> _bannerAdViewIdByKey = {};
  final Map<Object, bool> _bannerRoutePausedByKey = {};

  bool _bannerDisposed = false;
  AdSlot? _disposedBannerSlot;
  BannerListenables? _disposedBannerListenables;
  final ValueNotifier<AdViewId?> _disposedBannerAdViewId =
      ValueNotifier<AdViewId?>(null)..dispose();

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

  ValueNotifier<AdViewId?> _bannerAdViewIdFor(Object key) {
    if (_bannerDisposed) return _disposedBannerAdViewId;
    return _bannerAdViewIdByKey.putIfAbsent(
        key, () => ValueNotifier<AdViewId?>(null));
  }

  @override
  AdSlot bannerSlot(Object key) => _bannerSlotFor(key);

  @override
  Iterable<AdSlot> get bannerSlots => _bannerSlotsByKey.values;

  @override
  BannerListenables banner(Object key) => _bannerListenablesFor(key);

  @override
  void disposeBannerInstance(Object key) {
    _bannerSlotsByKey.remove(key)?.dispose();
    _bannerListenablesByKey.remove(key)?.dispose();
    final adViewId = _bannerAdViewIdByKey.remove(key);
    final id = adViewId?.value;
    adViewId?.dispose();
    // 2026-08-19 audit (Finding 5): this used to stop at the Dart-side
    // state above, never releasing the native AdView — every
    // BannerAdWidget that permanently unmounts leaked it on AppLovin.
    if (id != null) {
      unawaited(_destroyWidgetAdViewWhenDetached(id, 'banner'));
    }
    _bannerRoutePausedByKey.remove(key);
  }

  // T65 (phase 3) — one AdSlot/BannerListenables/adViewId per MrecAdWidget
  // instance, mirroring banner (phase 2) exactly.
  final Map<Object, AdSlot> _mrecSlotsByKey = {};
  final Map<Object, BannerListenables> _mrecListenablesByKey = {};
  final Map<Object, ValueNotifier<AdViewId?>> _mrecAdViewIdByKey = {};
  final Map<Object, bool> _mrecRoutePausedByKey = {};

  bool _mrecDisposed = false;
  AdSlot? _disposedMrecSlot;
  BannerListenables? _disposedMrecListenables;
  final ValueNotifier<AdViewId?> _disposedMrecAdViewId =
      ValueNotifier<AdViewId?>(null)..dispose();

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

  ValueNotifier<AdViewId?> _mrecAdViewIdFor(Object key) {
    if (_mrecDisposed) return _disposedMrecAdViewId;
    return _mrecAdViewIdByKey.putIfAbsent(
        key, () => ValueNotifier<AdViewId?>(null));
  }

  @override
  AdSlot mrecSlot(Object key) => _mrecSlotFor(key);

  @override
  Iterable<AdSlot> get mrecSlots => _mrecSlotsByKey.values;

  @override
  Iterable<AdSlot> get nativeSlots => _nativeSlotsByKey.values;

  @override
  BannerListenables mrec(Object key) => _mrecListenablesFor(key);

  @override
  void disposeMrecInstance(Object key) {
    _mrecSlotsByKey.remove(key)?.dispose();
    _mrecListenablesByKey.remove(key)?.dispose();
    final adViewId = _mrecAdViewIdByKey.remove(key);
    final id = adViewId?.value;
    adViewId?.dispose();
    // 2026-08-19 audit (Finding 5): see disposeBannerInstance above.
    if (id != null) {
      unawaited(_destroyWidgetAdViewWhenDetached(id, 'mrec'));
    }
    _mrecRoutePausedByKey.remove(key);
  }

  // B1 fix (audit_claude.md, 2026-08-20): AppLovin's native side refuses to
  // destroy a widget AdView while it's still attached to the view hierarchy
  // (`hasContainerView()` true — verified against applovin_max's Android/iOS
  // plugin source), which is exactly the state a AdView is in the instant its
  // owning widget's State.dispose() runs (detach from the platform view tree
  // completes slightly later). destroyWidgetAdView above used to just log and
  // give up on that rejection, leaking the native AdView on every dispose
  // that happened while the ad was still on screen — the common case, not an
  // edge case. Retrying a few times with backoff gives the detach time to
  // actually finish before we give up for good.
  static const List<Duration> _destroyRetryDelays = [
    Duration(milliseconds: 200),
    Duration(milliseconds: 500),
    Duration(seconds: 1),
  ];

  // m22 (audit_claude.md MINOR) — the retry used to sleep on a bare
  // `Future.delayed` with no handle, so a chain started by the last widget
  // unmount before teardown kept firing for up to ~1.7s AFTER dispose(),
  // calling into a bridge whose native listeners were already cleared. The
  // timers are tracked here and cancelled in dispose() instead.
  final Set<Timer> _destroyRetryTimers = {};

  Future<void> _destroyWidgetAdViewWhenDetached(
    AdViewId id,
    String what, {
    int attempt = 0,
  }) async {
    try {
      await _bridge.destroyWidgetAdView(id);
    } catch (e) {
      if (attempt >= _destroyRetryDelays.length) {
        SafeLogger.w(_logTag,
            'destroyWidgetAdView ($what dispose) still failing after $attempt '
            'retries, giving up: $e');
        return;
      }
      late final Timer timer;
      timer = Timer(_destroyRetryDelays[attempt], () {
        _destroyRetryTimers.remove(timer);
        unawaited(
            _destroyWidgetAdViewWhenDetached(id, what, attempt: attempt + 1));
      });
      _destroyRetryTimers.add(timer);
    }
  }

  // T65 (phase 1) — one AdSlot/BannerListenables per NativeAdWidget instance.
  // MaxNativeAdView loads on mount and is self-contained (this adapter never
  // drives isLoaded/hasError itself, NativeAdWidget's own listener callbacks
  // do — see native_ad_widget.dart), but that state still lived in ONE
  // shared bundle: two simultaneous NativeAdWidgets on AppLovin wouldn't
  // crash, but one ad finishing (or failing) would flip the OTHER widget's
  // shimmer/loaded state too, since both read/wrote the same notifiers.
  final Map<Object, AdSlot> _nativeSlotsByKey = {};
  final Map<Object, BannerListenables> _nativeListenablesByKey = {};

  // T65 (phase 1) — see AdMobAdapter's identical guard for the rationale:
  // once disposed, must not silently resurrect a live bundle for an unseen
  // key.
  bool _nativeDisposed = false;
  AdSlot? _disposedNativeSlot;
  BannerListenables? _disposedNativeListenables;

  // 2026-08-16 audit: MaxNativeAdView's listener callbacks (native_ad_widget
  // .dart) re-resolve `adapter.native(instanceKey)` on EVERY callback
  // invocation, not just once at load start (unlike AdMobAdapter's
  // preloadNative, which captures its `listenables`/`slot` locals once).
  // Without tracking disposed keys here, a callback that arrives after
  // `disposeNativeInstance(key)` already removed the map entry would
  // silently `putIfAbsent` a BRAND NEW, never-disposed `BannerListenables`
  // for that (permanently gone, per-widget-instance) key — an unbounded
  // leak for any screen that scrolls many native ads through a `ListView`
  // (T73's exact use case).
  //
  // A tombstone must NOT be permanent, though: the key is the widget's State
  // object and it IS legitimately reused — NativeAdWidget disposes the
  // instance and then re-inits the SAME `this` when personalisation is
  // withdrawn, and again when the consent gate closes then reopens. Left
  // permanent, the native ad never came back for that widget and its
  // callbacks wrote to disposed ValueNotifiers. [reviveNativeInstance] lifts
  // the tombstone (and drops the strong ref to the State object with it) on
  // the mount signal every re-init already sends, which always arrives
  // before any callback can resolve the key again — the same trap the AdMob
  // banner side hit, fixed there with slot identity (MJ21/B-2).
  final Set<Object> _disposedNativeKeys = {};

  AdSlot _nativeSlotFor(Object key) {
    if (_nativeDisposed || _disposedNativeKeys.contains(key)) {
      return _disposedNativeSlot ??=
          (AdSlot(type: AdSlotType.native)..dispose());
    }
    return _nativeSlotsByKey.putIfAbsent(
        key, () => AdSlot(type: AdSlotType.native));
  }

  BannerListenables _nativeListenablesFor(Object key) {
    if (_nativeDisposed || _disposedNativeKeys.contains(key)) {
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
    _disposedNativeKeys.add(key);
    _nativeSlotsByKey.remove(key)?.dispose();
    _nativeListenablesByKey.remove(key)?.dispose();
  }

  /// Lift [key]'s [disposeNativeInstance] tombstone because a live widget is
  /// (re)starting a load for it. Called from `AdManager.recordNativeLoad`.
  ///
  /// Deliberately NOT on [AdProviderAdapter]: that interface is exported, so
  /// a new member there is a source-breaking change for anyone implementing
  /// it, and AdMob would only ever supply an empty body (it guards a
  /// mid-load dispose with slot identity — see `identical(_bannerSlotsByKey
  /// [key], slot)` in admob_adapter.dart — and keeps no tombstone to lift).
  void reviveNativeInstance(Object key) => _disposedNativeKeys.remove(key);

  // Unlike banner/mrec, MaxNativeAdView loads on mount and is self-contained
  // — this adapter never drives isLoaded/hasError itself, the widget layer
  // sets them directly from MaxNativeAdView's own listener callbacks (see
  // native(key) above).

  @override
  ValueListenable<Object?> appLovinBannerAdViewId(Object key) =>
      _bannerAdViewIdFor(key);

  @override
  String? get appLovinBannerId => _max?.bannerId;

  @override
  ValueListenable<Object?> appLovinMrecAdViewId(Object key) =>
      _mrecAdViewIdFor(key);

  @override
  String? get appLovinMrecId => _max?.mrecId;

  @override
  String? get appLovinNativeId => _max?.nativeId;

  void Function(bool dismissed)? _appOpenDismiss;
  void Function(bool loaded)? _appOpenLoadCb;
  void Function(bool shown)? _interstitialDone;
  void Function(RewardResult result)? _rewardedDone;

  /// Set true in [showRewarded] when the caller supplied SSV identifying
  /// data for the in-flight show — read once by the reward callback to stamp
  /// [RewardResult.pendingServerConfirmation].
  bool _pendingSsv = false;

  Timer? _appOpenShowTimeout;

  @override
  bool bannerRoutePaused(Object key) => _bannerRoutePausedByKey[key] ?? false;

  @override
  void setBannerRoutePaused(Object key, bool paused) {
    _bannerRoutePausedByKey[key] = paused;
  }

  @override
  bool mrecRoutePaused(Object key) => _mrecRoutePausedByKey[key] ?? false;

  @override
  void setMrecRoutePaused(Object key, bool paused) {
    _mrecRoutePausedByKey[key] = paused;
  }

  /// T40 — true when [initialize] skipped native SDK init because the caller
  /// is age-restricted (COPPA). AppLovin MAX 4.x has no runtime child-directed
  /// API, so the only compliant option is to never initialize at all — the
  /// adapter stays `isInitialised == false` and every AppLovin ad surface is
  /// unavailable for the session (same as a normal init failure).
  bool _disabledForChildUser = false;
  bool get disabledForChildUser => _disabledForChildUser;

  @override
  Future<bool> initialize(
    AdConfig config, {
    String deviceGaid = '',
    bool isAgeRestrictedUser = false,
    AdConsent? consent,
  }) async {
    if (isAgeRestrictedUser || consent?.isAgeRestrictedUser == true) {
      _disabledForChildUser = true;
      SafeLogger.e(
        _logTag,
        'initialize ABORTED: isAgeRestrictedUser=true — AppLovin MAX 4.x has '
        'no COPPA child-directed init API, so the SDK is NOT initialized. '
        'This adapter (and every AppLovin ad surface) stays disabled for the '
        'session. Do not reuse AppLovin for a child-directed audience.',
      );
      return false;
    }
    final cfg = config.appLovin;
    if (cfg == null) {
      SafeLogger.e(_logTag, 'initialize: AppLovinConfig is null — aborted');
      return false;
    }
    _config = config;
    _max = cfg;
    SafeLogger.d(_logTag, 'initialize $tag wiring listeners…');
    _wireAppOpenListener(cfg.appOpenId);
    _wireInterstitialListener(cfg.interstitialId);
    _wireRewardedListener(cfg.rewardedId);
    // T01 — when Google UMP is the consent source, disable AppLovin's own CMP
    // flow so the user isn't prompted twice. Must be set BEFORE SDK init.
    if (config.disableAppLovinCmpFlow) {
      try {
        _bridge.setTermsAndPrivacyPolicyFlowEnabled(false);
        SafeLogger.d(_logTag, 'AppLovin CMP flow disabled (UMP is CMP)');
      } catch (e) {
        SafeLogger.w(_logTag, 'setTermsAndPrivacyPolicyFlowEnabled failed: $e');
      }
    }
    // MJ1 — privacy flags must reach MAX BEFORE its SDK init, which is why
    // this is here and not left to AdManager's post-init applyToProviders():
    // on an ordinary cold start (host never called setConsent, so nothing was
    // buffered) that post-init call was the FIRST time AppLovin heard about
    // consent, i.e. `_bridge.initialize` below had already run and made its
    // first request to MAX without it. AppLovin documents these as init-time
    // settings. Still idempotent with the later call.
    if (consent != null) {
      try {
        _bridge.setHasUserConsent(consent.hasUserConsent);
        _bridge.setDoNotSell(consent.doNotSell);
        SafeLogger.d(
            _logTag,
            () => 'privacy flags applied pre-init '
                '(consent=${consent.hasUserConsent}, '
                'doNotSell=${consent.doNotSell})');
      } catch (e) {
        // Never block init on this — the post-init apply still runs.
        SafeLogger.w(_logTag, 'pre-init privacy flags failed: $e');
      }
    }
    try {
      await _bridge.initialize(cfg.sdkKey);
      SafeLogger.d(_logTag, 'initialize $tag ✅ SDK ready');

      // Register THIS device as a test device in debug builds — required
      // by AppLovin to avoid serving real (revenue-counting) ads to the
      // developer. Failing to do so risks account suspension. Preserves
      // 1.x behaviour exactly.
      if (kDebugMode && deviceGaid.isNotEmpty) {
        try {
          _bridge.setTestDeviceAdvertisingIds([deviceGaid]);
          SafeLogger.d(_logTag, 'AppLovin test device registered: $deviceGaid');
        } catch (e) {
          SafeLogger.w(_logTag, 'setTestDeviceAdvertisingIds failed: $e');
        }
      }
      return true;
    } catch (e, st) {
      SafeLogger.e(_logTag, 'initialize $tag FAILED: $e\n$st');
      _max = null;
      _config = null;
      return false;
    }
  }

  /// Refuses to mark a fullscreen slot `ready` when its load was requested
  /// under a consent state the user has since narrowed.
  ///
  /// Round-7 audit, MAJOR. `discardCachedFullscreenAds()` only reset slots
  /// that were already `ready`; a slot still `loading` kept its request and
  /// its listener then marked it ready. That ad was requested with
  /// `setHasUserConsent(true)`, and withdrawing personalisation does not close
  /// the `canRequestAds` gate, so it was shown like any other.
  ///
  /// MAX owns its own native cache and exposes no handle to drop one ad, so
  /// this cannot un-cache it there. It does not have to: every show path
  /// refuses on `!slot.isReady`, so leaving the slot out of `ready` is what
  /// actually stops the ad from reaching a user, and the next show goes
  /// through a fresh load carrying the new consent state.
  bool _discardIfConsentStale(AdSlot slot, String label) {
    if (!slot.loadedUnderStaleConsent) return false;
    SafeLogger.w(
        _logTag,
        '$label $tag ⛔ loaded under consent the user has since narrowed — '
        'not caching it (MAX may still hold it natively; no show path can '
        'reach it while the slot is not ready)');
    slot.reset();
    return true;
  }

  @override
  Future<void> discardCachedFullscreenAds() async {
    // Round-7 audit, MAJOR — bump the consent generation first so a load
    // still in the air is recognised as stale when its listener fires. See
    // [AdSlot.consentEpoch] and [_discardIfConsentStale].
    AdSlot.consentEpoch++;
    // MAX caches fullscreen ads natively and exposes no Dart handle to throw
    // one away, so there is nothing to dispose here. Resetting the ready slots
    // is still worth doing: it forces the next show to go through a fresh
    // load* call rather than serving whatever MAX already holds, which is the
    // part this SDK can actually control.
    var reset = 0;
    for (final slot in <AdSlot>[
      appOpenSlot,
      interstitialSlot,
      rewardedSlot,
      rewardedInterstitialSlot,
    ]) {
      if (!slot.isReady) continue;
      slot.reset();
      reset++;
    }
    SafeLogger.d(
        _logTag,
        () => 'discardCachedFullscreenAds [AppLovin] — reset $reset ready '
            'slot(s); MAX owns its own cache, so this only guarantees the '
            'next show re-requests');
  }

  @override
  Future<void> dispose() async {
    SafeLogger.d(_logTag, 'dispose() $tag — clearing listeners + timers');
    _appOpenShowTimeout?.cancel();
    _appOpenShowTimeout = null;
    // m22 — drop any pending destroyWidgetAdView retry: the bridge is about
    // to lose its listeners below, and a retry landing after that talks to a
    // torn-down bridge for an AdView nobody owns any more.
    for (final t in _destroyRetryTimers) {
      t.cancel();
    }
    _destroyRetryTimers.clear();

    // Order matters: clear native listeners FIRST so any callback fired
    // mid-destruction (e.g. destroyWidgetAdView triggers an
    // `onAdDisplayFailedCallback`) is silently dropped instead of
    // mutating slot state on a half-disposed adapter.
    try {
      _bridge.setAppOpenAdListener(null);
      _bridge.setInterstitialListener(null);
      _bridge.setRewardedAdListener(null);
      _bridge.setWidgetAdViewAdListener(null);
    } catch (e) {
      SafeLogger.w(_logTag, 'dispose() listener clear threw: $e');
    }

    // Now destroy the native widget AdViews. Without this the native side
    // keeps the previous banner/mrec alive across destroy → re-init cycles.
    // T65 (phase 2) — every known BannerAdWidget instance's AdView, not just
    // one shared id.
    for (final adViewIdNotifier in _bannerAdViewIdByKey.values) {
      final oldBannerId = adViewIdNotifier.value;
      if (oldBannerId != null) {
        try {
          await _bridge.destroyWidgetAdView(oldBannerId);
        } catch (e) {
          SafeLogger.w(_logTag, 'destroyWidgetAdView (banner) threw: $e');
        }
      }
    }
    for (final adViewIdNotifier in _mrecAdViewIdByKey.values) {
      final oldMrecId = adViewIdNotifier.value;
      if (oldMrecId != null) {
        try {
          await _bridge.destroyWidgetAdView(oldMrecId);
        } catch (e) {
          SafeLogger.w(_logTag, 'destroyWidgetAdView (mrec) threw: $e');
        }
      }
    }
    _appOpenDismiss?.call(false);
    _appOpenDismiss = null;
    _appOpenLoadCb?.call(false);
    _appOpenLoadCb = null;
    _interstitialDone?.call(false);
    _interstitialDone = null;
    _rewardedDone?.call(RewardResult.skipped);
    _rewardedDone = null;
    appOpenSlot.reset();
    interstitialSlot.reset();
    rewardedSlot.reset();
    // Round 5 Minor — AppLovin never even reset this slot (AdMob did). It
    // stays idle by design on MAX, but a stale state across teardown is still
    // wrong.
    rewardedInterstitialSlot.reset();
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
      l.clearError();
      l.adSize.value = null;
      l.autoRefreshEnabled.value = true;
      l.visible.value = true;
    }
    for (final id in _bannerAdViewIdByKey.values) {
      id.value = null;
    }
    _bannerRoutePausedByKey.clear();
    for (final l in _mrecListenablesByKey.values) {
      l.isLoaded.value = false;
      l.clearError();
      l.adSize.value = null;
      l.autoRefreshEnabled.value = true;
      l.visible.value = true;
    }
    for (final id in _mrecAdViewIdByKey.values) {
      id.value = null;
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
    // m24 (audit_claude.md MINOR) — the slot map alone is not the key set:
    // `banner(key)`/`mrec(key)`/`native(key)` and
    // `appLovinBannerAdViewId(key)`/`appLovinMrecAdViewId(key)` each create
    // their own per-key entry independently of `bannerSlot(key)`, so a key
    // that was only ever asked for those had its ValueNotifiers left
    // undisposed here. Union of every per-key map.
    for (final key in <Object>{
      ..._bannerSlotsByKey.keys,
      ..._bannerListenablesByKey.keys,
      ..._bannerAdViewIdByKey.keys,
    }) {
      disposeBannerInstance(key);
    }
    _bannerDisposed = true;
    for (final key in <Object>{
      ..._mrecSlotsByKey.keys,
      ..._mrecListenablesByKey.keys,
      ..._mrecAdViewIdByKey.keys,
    }) {
      disposeMrecInstance(key);
    }
    _mrecDisposed = true;
    for (final key in <Object>{
      ..._nativeSlotsByKey.keys,
      ..._nativeListenablesByKey.keys,
    }) {
      disposeNativeInstance(key);
    }
    _nativeDisposed = true;

    _max = null;
    _config = null;
  }

  @override
  void applyConsent(AdConsent consent) {
    // No-op: AppLovin consent is forwarded via the static `AppLovinMAX`
    // privacy APIs in `applyConsentToProviders` (setHasUserConsent /
    // setDoNotSell). AppLovin has no per-request non-personalized flag, so
    // there is nothing to store on the adapter.
  }

  // ─── Repeated-failure warning (log-only) ──────────────────────────────────
  // Doesn't affect retry/backoff — that's already driven by
  // `AdSlot.consecutiveFailures` itself. This just escalates from the routine
  // per-attempt warning (logged unconditionally above) to a distinct line
  // once a slot is clearly in a failure streak, so log monitoring can tell a
  // one-off blip apart from a sustained outage.
  static const int _kRepeatedFailureThreshold = 3;

  void _logIfRepeatedFailure(String label, AdSlot slot, Object errCode) {
    if (slot.consecutiveFailures == _kRepeatedFailureThreshold) {
      SafeLogger.w(_logTag,
          '$label $tag ⚠️ $_kRepeatedFailureThreshold consecutive load failures (last code=$errCode)');
    }
  }

  // ─── App Open ─────────────────────────────────────────────────────────────

  void _wireAppOpenListener(String unitId) {
    _bridge.setAppOpenAdListener(AppOpenAdListener(
      onAdLoadedCallback: (ad) {
        SafeLogger.d(_logTag, 'appOpen $tag ✅ loaded');
        if (_discardIfConsentStale(appOpenSlot, 'appOpen')) return;
        appOpenSlot.markReady();
        _emit(AdLoadEvent(
          providerTag: tag,
          type: AdSlotType.appOpen,
          placement: AdPlacement.splash,
          success: true,
        ));
      },
      onAdLoadFailedCallback: (id, err) {
        SafeLogger.w(_logTag, 'appOpen $tag ❌ load failed code=${err.code}');
        appOpenSlot.markFailed();
        _logIfRepeatedFailure('appOpen', appOpenSlot, err.code);
        _emit(AdLoadEvent(
          providerTag: tag,
          type: AdSlotType.appOpen,
          placement: AdPlacement.splash,
          success: false,
          errorCode: err.code.value,
        ));
      },
      onAdDisplayedCallback: (ad) {
        appOpenSlot.markDisplayed();
        SafeLogger.d(_logTag, 'appOpen $tag ✅ displayed');
      },
      onAdRevenuePaidCallback: (ad) {
        _emitRevenueIfPresent(ad, AdSlotType.appOpen, AdPlacement.splash);
      },
      onAdDisplayFailedCallback: (ad, err) {
        _appOpenShowTimeout?.cancel();
        _appOpenShowTimeout = null;
        // Late arrival (see onAdHiddenCallback above) — watchdog already
        // resolved this show cycle; don't clobber state or double-reload.
        if (_appOpenDismiss == null) {
          SafeLogger.w(_logTag,
              'appOpen $tag ❌ display failed (late — watchdog already handled this show): ${err.message}');
          return;
        }
        SafeLogger.w(_logTag, 'appOpen $tag ❌ display failed: ${err.message}');
        appOpenSlot.markShowFailed();
        final cb = _appOpenDismiss;
        _appOpenDismiss = null;
        cb?.call(false);
        // beginReload (not beginLoad) — the show failed but the load path is
        // healthy, so refill immediately instead of waiting out the backoff
        // window the show-failure just armed.
        if (!canReload()) {
          SafeLogger.d(_logTag,
              'appOpen $tag ⏭️ reload skipped — AdManager gate closed');
          return;
        }
        if (appOpenSlot.beginReload()) {
          try {
            _bridge.loadAppOpenAd(unitId);
            // 2026-08-16 audit: this reload bypasses AdManager.loadAppOpenAd
            // entirely, so THAT method's own watchdog-arming never runs for
            // it. Without arming one directly here too, a native callback
            // that never arrives would leave the slot stuck `loading` forever.
            appOpenSlot.armLoadWatchdog('appOpen', const Duration(seconds: 30));
          } catch (e) {
            SafeLogger.e(_logTag, 'reload appOpen threw: $e');
            appOpenSlot.markFailed();
          }
        }
      },
      onAdClickedCallback: (ad) {
        SafeLogger.d(_logTag, 'appOpen $tag 🎯 click');
        AdSafetyConfig.recordAdClick();
        _emit(AdClickEvent(
          providerTag: tag,
          type: AdSlotType.appOpen,
          placement: AdPlacement.splash,
        ));
      },
      onAdHiddenCallback: (ad) {
        _appOpenShowTimeout?.cancel();
        _appOpenShowTimeout = null;
        // Late arrival: the smart-timeout watchdog already force-dismissed
        // this show cycle (_appOpenDismiss cleared, slot moved out of
        // `showing`) before AppLovin's native callback landed — see the
        // "unreliable, sometimes fires LATE" comment in [showAppOpen]. Acting
        // again here would clobber whatever state the reload-in-flight has
        // already moved to and fire a SECOND raw `_bridge.loadAppOpenAd`
        // call that bypasses AdManager's VIP/consent/daily-cap gates.
        if (_appOpenDismiss == null) {
          SafeLogger.d(_logTag,
              'appOpen $tag 👋 hidden (late — watchdog already handled this show)');
          return;
        }
        SafeLogger.d(_logTag, 'appOpen $tag 👋 hidden');
        appOpenSlot.markDismissed();
        final cb = _appOpenDismiss;
        _appOpenDismiss = null;
        cb?.call(true);
        if (!canReload()) {
          SafeLogger.d(_logTag,
              'appOpen $tag ⏭️ reload skipped — AdManager gate closed');
          return;
        }
        if (appOpenSlot.beginLoad()) {
          try {
            _bridge.loadAppOpenAd(unitId);
            // 2026-08-16 audit: same reasoning as onAdDisplayFailedCallback's
            // reload above — bypasses AdManager.loadAppOpenAd's watchdog.
            appOpenSlot.armLoadWatchdog('appOpen', const Duration(seconds: 30));
          } catch (e) {
            SafeLogger.e(_logTag, 'reload appOpen threw: $e');
            appOpenSlot.markFailed();
          }
        }
      },
    ));
  }

  @override
  Future<void> loadAppOpen({void Function(bool loaded)? onAdLoaded}) async {
    final cfg = _max;
    if (cfg == null) {
      onAdLoaded?.call(false);
      return;
    }
    if (appOpenSlot.isReady) {
      onAdLoaded?.call(true);
      return;
    }
    if (!appOpenSlot.beginLoad()) {
      onAdLoaded?.call(false);
      return;
    }
    final prev = _appOpenLoadCb;
    if (prev != null) prev(false);
    _appOpenLoadCb = onAdLoaded;
    appOpenSlot.pendingCallback = (success) {
      final cb = _appOpenLoadCb;
      _appOpenLoadCb = null;
      cb?.call(success);
    };
    SafeLogger.d(_logTag, 'loadAppOpen $tag 🔄 id=${cfg.appOpenId}');
    try {
      _bridge.loadAppOpenAd(cfg.appOpenId);
    } catch (e, st) {
      SafeLogger.e(_logTag, 'loadAppOpen $tag THREW: $e\n$st');
      appOpenSlot.markFailed();
    }
  }

  @override
  Future<void> showAppOpen(
      {required void Function(bool dismissed) onDismiss}) async {
    final cfg = _max;
    if (cfg == null) {
      onDismiss(false);
      return;
    }
    if (!appOpenSlot.isReady) {
      SafeLogger.w(_logTag, 'showAppOpen $tag ⚠️ not ready');
      onDismiss(false);
      return;
    }
    if (!appOpenSlot.beginShow()) {
      SafeLogger.w(_logTag, 'showAppOpen $tag ⚠️ already showing');
      onDismiss(false);
      return;
    }
    final old = _appOpenDismiss;
    _appOpenDismiss = null;
    if (old != null) old(false);
    _appOpenDismiss = onDismiss;

    SafeLogger.d(_logTag, 'showAppOpen $tag → _bridge.showAppOpenAd');
    try {
      _bridge.showAppOpenAd(cfg.appOpenId);
    } catch (e, st) {
      SafeLogger.e(_logTag, 'showAppOpen $tag THREW: $e\n$st');
      appOpenSlot.markShowFailed();
      final cb = _appOpenDismiss;
      _appOpenDismiss = null;
      cb?.call(false);
      return;
    }

    // Smart timeout: AppLovin's `onAdHiddenCallback` is unreliable — sometimes
    // fires LATE (10-30s after dismiss), especially when the user clicks the
    // ad and is sent to a browser/app store before returning.
    //
    // Strategy depends on platform, because the app lifecycle behaves
    // differently while a full-screen App Open ad is on screen:
    //   - ANDROID: the ad launches a separate Activity → Flutter goes
    //     `paused`/`inactive`. So `resumed` (foreground) WITHOUT a hidden
    //     callback genuinely means a hung overlay → force-dismiss after a
    //     short grace.
    //   - iOS: the ad is presented as a modal view controller WITHIN the app
    //     → Flutter stays `resumed` the whole time the ad shows. Foreground is
    //     therefore NOT a hung-ad signal; treating it as one (the old logic)
    //     force-dismissed every iOS App Open at ~10 s while it was displaying
    //     fine. On iOS we only rely on the native hidden/displayFailed
    //     callbacks plus the 90 s hard cap.
    //
    // An old fixed 10 s timeout also fired false-positive in QA (user click →
    // browser → 20+s → return), arming dismiss timestamps prematurely and
    // letting subsequent app-open trigger leak through the resume guard.
    _appOpenShowTimeout?.cancel();
    final captured = onDismiss;
    _scheduleAppOpenTimeoutCheck(captured, attempt: 0);
  }

  /// Test seam: put the App Open slot into `showing` and arm the watchdog with
  /// [captured] as the pending dismiss callback, so the lifecycle/platform
  /// branches of [_scheduleAppOpenTimeoutCheck] can be driven under `FakeAsync`.
  @visibleForTesting
  void debugStartAppOpenWatchdog(void Function(bool) captured) {
    appOpenSlot.beginLoad();
    appOpenSlot.markReady();
    appOpenSlot.beginShow();
    _appOpenDismiss = captured;
    _scheduleAppOpenTimeoutCheck(captured, attempt: 0);
  }

  /// Recursive lifecycle-aware timeout. On Android, force-dismisses shortly
  /// after observing the app foreground without a hidden callback (= hung
  /// overlay). On iOS the ad shows while the app stays `resumed`, so foreground
  /// is ignored and only the hard cap of 18 attempts × 5 s = 90 s applies.
  void _scheduleAppOpenTimeoutCheck(
    void Function(bool) captured, {
    required int attempt,
  }) {
    const tickSeconds = 5;
    const maxAttempts = 18; // 18 × 5 s = 90 s hard cap
    // iOS presents the App Open ad as an in-app modal VC, so Flutter never
    // leaves `resumed` while it shows — the foreground-as-hung heuristic only
    // holds on Android. See the comment block in [showAppOpen].
    final foregroundMeansHung = defaultTargetPlatform != TargetPlatform.iOS;
    _appOpenShowTimeout = Timer(const Duration(seconds: tickSeconds), () {
      _appOpenShowTimeout = null;
      // Already dismissed by AppLovin's normal callback path? Nothing to do.
      if (_appOpenDismiss != captured || !appOpenSlot.isShowing) {
        SafeLogger.d(_logTag,
            'showAppOpen $tag ⏰ tick #$attempt — already dismissed via callback, watcher exits');
        return;
      }
      final lifecycle = _lifecycleState();
      final isForeground = lifecycle == AppLifecycleState.resumed;

      if (isForeground && foregroundMeansHung) {
        // Android: app foreground but ad hasn't fired hidden. Could be:
        //   (a) Hung overlay — needs force-dismiss
        //   (b) Just-resumed transition — AppLovin's hidden callback is
        //       still in-flight via method channel (typically lands within
        //       ~500-1000 ms of the activity transition).
        //
        // Treat the FIRST foreground tick as a grace period — re-arm one
        // more tick to give AppLovin's natural callback time to land.
        // Only force-dismiss if app is STILL foreground on the second
        // foreground-observed tick.
        if (attempt < 1) {
          SafeLogger.d(_logTag,
              'showAppOpen $tag ⏰ tick #${attempt + 1} foreground but no callback yet — grace period, re-arming');
          _scheduleAppOpenTimeoutCheck(captured, attempt: attempt + 1);
          return;
        }
        SafeLogger.e(_logTag,
            'showAppOpen $tag ⏰ TIMEOUT — app foreground for ${(attempt + 1) * tickSeconds}s without hidden callback, force dismiss(false)');
        appOpenSlot.markShowFailed();
        _appOpenDismiss = null;
        captured(false);
        return;
      }
      // iOS foreground (ad shows while resumed), or Android backgrounded (ad on
      // screen / user in browser via click): the ad is presumed still up. Keep
      // waiting for the native hidden callback until the 90 s hard cap.
      if (attempt >= maxAttempts) {
        SafeLogger.e(_logTag,
            'showAppOpen $tag ⏰ HARD CAP ${maxAttempts * tickSeconds}s reached (lifecycle=${lifecycle?.name}) — force dismiss(false)');
        appOpenSlot.markShowFailed();
        _appOpenDismiss = null;
        captured(false);
        return;
      }
      SafeLogger.d(_logTag,
          'showAppOpen $tag ⏰ tick #${attempt + 1}/$maxAttempts (lifecycle=${lifecycle?.name}, fgHung=$foregroundMeansHung) — re-arming +${tickSeconds}s');
      _scheduleAppOpenTimeoutCheck(captured, attempt: attempt + 1);
    });
  }

  // ─── Interstitial ─────────────────────────────────────────────────────────

  void _wireInterstitialListener(String unitId) {
    _bridge.setInterstitialListener(InterstitialListener(
      onAdLoadedCallback: (ad) {
        SafeLogger.d(_logTag, 'inter $tag ✅ loaded');
        if (_discardIfConsentStale(interstitialSlot, 'inter')) return;
        interstitialSlot.markReady();
        _emit(AdLoadEvent(
          providerTag: tag,
          type: AdSlotType.interstitial,
          placement: AdPlacement.unspecified,
          success: true,
        ));
      },
      onAdLoadFailedCallback: (id, err) {
        SafeLogger.w(_logTag, 'inter $tag ❌ load failed code=${err.code}');
        interstitialSlot.markFailed();
        _logIfRepeatedFailure('inter', interstitialSlot, err.code);
        _emit(AdLoadEvent(
          providerTag: tag,
          type: AdSlotType.interstitial,
          placement: AdPlacement.unspecified,
          success: false,
          errorCode: err.code.value,
        ));
      },
      onAdDisplayedCallback: (ad) {
        // Disarms beginShow's watchdog — from here the user owns the clock.
        interstitialSlot.markDisplayed();
        SafeLogger.d(
            _logTag,
            () => 'inter $tag ✅ displayed | network=${ad.networkName} '
                'creativeId=${ad.creativeId} placement=${ad.placement} '
                'latency=${ad.latencyMillis}ms');
      },
      onAdRevenuePaidCallback: (ad) {
        SafeLogger.d(
            _logTag,
            () => 'inter $tag 💰 revenue=\$${ad.revenue} '
                'precision=${ad.revenuePrecision} network=${ad.networkName}');
        _emitRevenueIfPresent(
            ad, AdSlotType.interstitial, AdPlacement.unspecified);
      },
      onAdDisplayFailedCallback: (ad, err) {
        SafeLogger.w(
            _logTag,
            () =>
                'inter $tag ❌ display failed: code=${err.code} message="${err.message}"');
        interstitialSlot.markShowFailed();
        final cb = _interstitialDone;
        _interstitialDone = null;
        cb?.call(false);
        // beginReload — refill past the show-failure backoff window.
        if (!canReload()) {
          SafeLogger.d(
              _logTag, 'inter $tag ⏭️ reload skipped — AdManager gate closed');
          return;
        }
        if (interstitialSlot.beginReload()) {
          try {
            _bridge.loadInterstitial(unitId);
            // 2026-08-16 audit: bypasses AdManager.loadInterstitialAd's
            // watchdog — arm one directly so a native callback that never
            // arrives can't leave the slot stuck `loading` forever.
            interstitialSlot.armLoadWatchdog(
                'interstitial', const Duration(seconds: 30));
          } catch (e) {
            SafeLogger.e(_logTag, 'reload inter threw: $e');
            interstitialSlot.markFailed();
          }
        }
      },
      onAdClickedCallback: (ad) {
        SafeLogger.d(_logTag, 'inter $tag 🎯 click');
        AdSafetyConfig.recordAdClick();
        _emit(AdClickEvent(
          providerTag: tag,
          type: AdSlotType.interstitial,
          placement: AdPlacement.unspecified,
        ));
      },
      onAdHiddenCallback: (ad) {
        SafeLogger.d(_logTag, 'inter $tag 👋 hidden');
        interstitialSlot.markDismissed();
        final cb = _interstitialDone;
        _interstitialDone = null;
        cb?.call(true);
        if (!canReload()) {
          SafeLogger.d(
              _logTag, 'inter $tag ⏭️ reload skipped — AdManager gate closed');
          return;
        }
        if (interstitialSlot.beginLoad()) {
          try {
            _bridge.loadInterstitial(unitId);
            // 2026-08-16 audit: same reasoning as onAdDisplayFailedCallback's
            // reload above — bypasses AdManager.loadInterstitialAd's watchdog.
            interstitialSlot.armLoadWatchdog(
                'interstitial', const Duration(seconds: 30));
          } catch (e) {
            SafeLogger.e(_logTag, 'reload inter threw: $e');
            interstitialSlot.markFailed();
          }
        }
      },
    ));
  }

  @override
  Future<void> loadInterstitial() async {
    final cfg = _max;
    if (cfg == null) return;
    if (interstitialSlot.isReady) return;
    if (!interstitialSlot.beginLoad()) return;
    SafeLogger.d(_logTag, 'loadInterstitial $tag 🔄');
    try {
      _bridge.loadInterstitial(cfg.interstitialId);
    } catch (e, st) {
      SafeLogger.e(_logTag, 'loadInterstitial $tag THREW: $e\n$st');
      interstitialSlot.markFailed();
    }
  }

  @override
  Future<void> showInterstitial(
      {required void Function(bool shown) onDone}) async {
    final cfg = _max;
    if (cfg == null) {
      onDone(false);
      return;
    }
    if (!interstitialSlot.isReady) {
      SafeLogger.w(_logTag, 'showInterstitial $tag ⚠️ not ready');
      onDone(false);
      return;
    }
    // Round-7 audit, MAJOR — see [AdSlot.beginShow]. `_bridge.showInterstitial`
    // is fire-and-forget: AppLovin's `showAd()` on an ad its own cache has
    // since dropped logs an error natively and fires NO callback, so without
    // this watchdog the slot stayed `showing` and no interstitial ever loaded
    // again for the rest of the session.
    if (!interstitialSlot.beginShow(onShowNeverConfirmed: () {
      final cb = _interstitialDone;
      _interstitialDone = null;
      cb?.call(false);
    })) {
      SafeLogger.w(_logTag, 'showInterstitial $tag ⚠️ already showing');
      onDone(false);
      return;
    }
    final old = _interstitialDone;
    _interstitialDone = null;
    if (old != null) old(false);
    _interstitialDone = onDone;
    SafeLogger.d(_logTag,
        'showInterstitial $tag → _bridge.showInterstitial(${cfg.interstitialId})');
    try {
      _bridge.showInterstitial(cfg.interstitialId);
    } catch (e, st) {
      SafeLogger.e(_logTag, 'showInterstitial $tag THREW: $e\n$st');
      interstitialSlot.markShowFailed();
      final cb = _interstitialDone;
      _interstitialDone = null;
      cb?.call(false);
    }
  }

  /// Test seam: put interstitial slot into `showing`, [onDone]
  /// captured, immediately simulate AppLovin's `onAdHiddenCallback` (or
  /// `onAdDisplayFailedCallback` if [dismissed] is `false`) — same
  /// callback path `_wireInterstitialListener` drives in production.
  ///
  /// Unlike App Open, there is no watchdog/timer here — **a deliberate
  /// choice, not an oversight (R10-E)**. App Open's watchdog exists because
  /// it fires automatically on app foreground with no user-visible loading
  /// state, so a hang there is silent and needs a forced timeout to recover.
  /// Interstitial/rewarded loads are triggered by explicit app flow (level
  /// complete, reward request) with load times that are longer and far more
  /// variable than App Open's (rewarded in particular can legitimately take
  /// many seconds while AppLovin's waterfall mediates across networks) — a
  /// symmetric watchdog here risks killing a slow-but-healthy load far more
  /// often than it would recover a genuinely hung one, absent concrete
  /// evidence of real interstitial/rewarded hangs in production telemetry.
  /// AppLovin's fullscreen callbacks are treated as reliable for these two
  /// surfaces, so this hook only exercises the plain `beginShow()` →
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

  // ─── Rewarded ─────────────────────────────────────────────────────────────

  void _wireRewardedListener(String unitId) {
    _bridge.setRewardedAdListener(RewardedAdListener(
      onAdLoadedCallback: (ad) {
        SafeLogger.d(_logTag, 'rewarded $tag ✅ loaded');
        if (_discardIfConsentStale(rewardedSlot, 'rewarded')) return;
        rewardedSlot.markReady();
        _emit(AdLoadEvent(
          providerTag: tag,
          type: AdSlotType.rewarded,
          placement: AdPlacement.unspecified,
          success: true,
        ));
      },
      onAdLoadFailedCallback: (id, err) {
        SafeLogger.w(_logTag, 'rewarded $tag ❌ load failed code=${err.code}');
        rewardedSlot.markFailed();
        _logIfRepeatedFailure('rewarded', rewardedSlot, err.code);
        _emit(AdLoadEvent(
          providerTag: tag,
          type: AdSlotType.rewarded,
          placement: AdPlacement.unspecified,
          success: false,
          errorCode: err.code.value,
        ));
      },
      onAdDisplayedCallback: (ad) {
        rewardedSlot.markDisplayed();
        SafeLogger.d(_logTag, 'rewarded $tag ✅ displayed');
      },
      onAdRevenuePaidCallback: (ad) {
        _emitRevenueIfPresent(ad, AdSlotType.rewarded, AdPlacement.unspecified);
      },
      onAdDisplayFailedCallback: (ad, err) {
        SafeLogger.w(_logTag, 'rewarded $tag ❌ display failed: ${err.message}');
        rewardedSlot.markShowFailed();
        final cb = _rewardedDone;
        _rewardedDone = null;
        cb?.call(RewardResult.skipped);
        // beginReload — refill past the show-failure backoff window.
        if (!canReload()) {
          SafeLogger.d(_logTag,
              'rewarded $tag ⏭️ reload skipped — AdManager gate closed');
          return;
        }
        if (rewardedSlot.beginReload()) {
          try {
            _bridge.loadRewardedAd(unitId);
            // 2026-08-16 audit: bypasses AdManager.loadRewardedAd's
            // watchdog — arm one directly so a native callback that never
            // arrives can't leave the slot stuck `loading` forever.
            rewardedSlot.armLoadWatchdog('rewarded', const Duration(seconds: 30));
          } catch (e) {
            SafeLogger.e(_logTag, 'reload rewarded threw: $e');
            rewardedSlot.markFailed();
          }
        }
      },
      onAdClickedCallback: (ad) {
        SafeLogger.d(_logTag, 'rewarded $tag 🎯 click');
        AdSafetyConfig.recordAdClick();
        _emit(AdClickEvent(
          providerTag: tag,
          type: AdSlotType.rewarded,
          placement: AdPlacement.unspecified,
        ));
      },
      onAdHiddenCallback: (ad) {
        SafeLogger.d(_logTag, 'rewarded $tag 👋 hidden');
        rewardedSlot.markDismissed();
        final cb = _rewardedDone;
        _rewardedDone = null;
        cb?.call(RewardResult.skipped);
        if (!canReload()) {
          SafeLogger.d(_logTag,
              'rewarded $tag ⏭️ reload skipped — AdManager gate closed');
          return;
        }
        if (rewardedSlot.beginLoad()) {
          try {
            _bridge.loadRewardedAd(unitId);
            // 2026-08-16 audit: same reasoning as onAdDisplayFailedCallback's
            // reload above — bypasses AdManager.loadRewardedAd's watchdog.
            rewardedSlot.armLoadWatchdog('rewarded', const Duration(seconds: 30));
          } catch (e) {
            SafeLogger.e(_logTag, 'reload rewarded threw: $e');
            rewardedSlot.markFailed();
          }
        }
      },
      onAdReceivedRewardCallback: (ad, reward) {
        // Note: AppLovin **test creatives** report `amount=0` and empty
        // `label` regardless of what the dashboard rewarded ad-unit declares.
        // Real rewarded creatives in production return the configured values.
        // The `earned=true` flag is the source of truth for "user finished
        // watching" — `amount` is purely informational metadata.
        SafeLogger.d(
          _logTag,
          () =>
              'rewarded $tag 🏆 label="${reward.label}" amount=${reward.amount} '
              '(test creatives report 0/empty — earned=true is the truth)',
        );
        final cb = _rewardedDone;
        _rewardedDone = null;
        final pendingSsv = _pendingSsv;
        _pendingSsv = false;
        cb?.call(RewardResult(
          earned: true,
          label: reward.label,
          amount: reward.amount,
          pendingServerConfirmation: pendingSsv,
        ));
      },
    ));
  }

  @override
  Future<void> loadRewarded() async {
    final cfg = _max;
    if (cfg == null) return;
    if (rewardedSlot.isReady) return;
    if (!rewardedSlot.beginLoad()) return;
    SafeLogger.d(_logTag, 'loadRewarded $tag 🔄');
    try {
      _bridge.loadRewardedAd(cfg.rewardedId);
    } catch (e, st) {
      SafeLogger.e(_logTag, 'loadRewarded $tag THREW: $e\n$st');
      rewardedSlot.markFailed();
    }
  }

  @override
  Future<void> showRewarded({
    required void Function(RewardResult result) onDone,
    String? ssvCustomData,
    String? ssvUserId,
  }) async {
    final cfg = _max;
    if (cfg == null) {
      onDone(RewardResult.skipped);
      return;
    }
    if (!rewardedSlot.isReady) {
      SafeLogger.w(_logTag, 'showRewarded $tag ⚠️ not ready');
      onDone(RewardResult.skipped);
      return;
    }
    // Round-7 audit, MAJOR — see [AdSlot.beginShow] and the note on
    // showInterstitial above.
    if (!rewardedSlot.beginShow(onShowNeverConfirmed: () {
      final cb = _rewardedDone;
      _rewardedDone = null;
      cb?.call(RewardResult.skipped);
    })) {
      SafeLogger.w(_logTag, 'showRewarded $tag ⚠️ already showing');
      onDone(RewardResult.skipped);
      return;
    }
    final old = _rewardedDone;
    _rewardedDone = null;
    if (old != null) old(RewardResult.skipped);
    _rewardedDone = onDone;
    // AppLovin's SSV surface is a single `custom_data` string (no separate
    // userId field) — pass ssvCustomData verbatim, or fall back to ssvUserId
    // so a caller that only has a userId still gets it into the postback.
    final customData = ssvCustomData ?? ssvUserId;
    _pendingSsv = customData != null;
    SafeLogger.d(_logTag,
        'showRewarded $tag → _bridge.showRewardedAd(${cfg.rewardedId})');
    try {
      _bridge.showRewardedAd(cfg.rewardedId, customData: customData);
    } catch (e, st) {
      SafeLogger.e(_logTag, 'showRewarded $tag THREW: $e\n$st');
      rewardedSlot.markShowFailed();
      final cb = _rewardedDone;
      _rewardedDone = null;
      cb?.call(RewardResult.skipped);
    }
  }

  // T89 — documented no-ops: AppLovin MAX has no "Rewarded Interstitial" ad
  // unit type. rewardedInterstitialSlot never leaves idle, so
  // AdManager.loadRewardedInterstitialAd()'s `beginLoad()` call (if it ever
  // reached one) would simply never succeed — but these no-ops mean it never
  // even gets that far.
  @override
  Future<void> loadRewardedInterstitial() async {}

  @override
  Future<void> showRewardedInterstitial({
    required void Function(RewardResult result) onDone,
  }) async {
    onDone(const RewardResult(earned: false, shown: false));
  }

  /// Test seam: put the rewarded slot into `showing` with [onDone] captured,
  /// then immediately simulate AppLovin's `onAdHiddenCallback` (or
  /// `onAdDisplayFailedCallback` when [dismissed] is `false`) — mirrors
  /// [debugSimulateInterstitialShowAndDismiss]. No watchdog exists for
  /// rewarded either, so this only exercises the plain `beginShow()` →
  /// `markDismissed()`/`markShowFailed()` transition.
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

  // ─── Banner / MREC ──────────────────────────────────────────────────────

  // AppLovinMAX.setWidgetAdViewAdListener is backed by a SINGLE static
  // listener shared across every widget-ad-view format — installing a
  // second, format-specific listener would silently replace the first
  // one's callbacks. So banner and mrec share ONE listener here, installed
  // once, that dispatches per-callback by comparing `ad.adViewId` against
  // the current `_bannerAdViewId`/`_mrecAdViewId` to route state updates to
  // the right slot/listenables.
  bool _widgetListenerInstalled = false;

  void _ensureWidgetAdViewListener() {
    if (_widgetListenerInstalled) return;
    _widgetListenerInstalled = true;
    _bridge.setWidgetAdViewAdListener(WidgetAdViewAdListener(
      onAdLoadedCallback: (ad) {
        // T65 (phase 3) — same disambiguation as banner below: match the
        // reported adViewId against each known MREC key's own notifier.
        for (final entry in _mrecAdViewIdByKey.entries) {
          if (entry.value.value == ad.adViewId) {
            _handleWidgetAdLoaded(ad, _mrecListenablesFor(entry.key),
                _mrecSlotFor(entry.key), AdSlotType.mrec, 'mrec');
            return;
          }
        }
        // T65 (phase 2) — disambiguate WHICH BannerAdWidget instance this
        // callback belongs to by matching the adViewId the bridge just
        // reported against each key's own notifier (reliable: adViewId is
        // unique per successfully-created native view).
        Object? matchedKey;
        for (final entry in _bannerAdViewIdByKey.entries) {
          if (entry.value.value == ad.adViewId) {
            matchedKey = entry.key;
            break;
          }
        }
        if (matchedKey == null) {
          SafeLogger.w(_logTag,
              'banner $tag ✅ loaded but no matching widget key (stale callback?) — dropping');
          return;
        }
        _handleWidgetAdLoaded(ad, _bannerListenablesFor(matchedKey),
            _bannerSlotFor(matchedKey), AdSlotType.banner, 'banner');
      },
      onAdLoadFailedCallback: (id, err) {
        // AppLovin passes back the ad-unit id, not the adViewId, on failure —
        // match against the configured bannerId/mrecId instead.
        final isMrec = id == _max?.mrecId && id != _max?.bannerId;
        if (isMrec) {
          // T65 (phase 3) — same limitation/fallback as banner below: can't
          // attribute the failure to one specific key, so mark every
          // currently-loading MREC key failed.
          for (final key in _mrecSlotsByKey.keys.toList()) {
            final slot = _mrecSlotFor(key);
            if (slot.isLoading) {
              _handleWidgetAdLoadFailed(
                  _mrecListenablesFor(key), slot, AdSlotType.mrec, 'mrec', err);
            }
          }
          return;
        }
        // T65 (phase 2) — the bridge only reports the ad-unit id on failure,
        // not a per-call correlation id, so a failed preload can't be
        // attributed to one specific BannerAdWidget key when multiple are
        // concurrently loading. Known limitation: mark every key currently
        // mid-load as failed rather than leaving any stranded in `loading`.
        for (final key in _bannerSlotsByKey.keys.toList()) {
          final slot = _bannerSlotFor(key);
          if (slot.isLoading) {
            _handleWidgetAdLoadFailed(_bannerListenablesFor(key), slot,
                AdSlotType.banner, 'banner', err);
          }
        }
      },
    ));
  }

  void _handleWidgetAdLoaded(MaxAd ad, BannerListenables listenables,
      AdSlot slot, AdSlotType type, String label) {
    final isInitial = !listenables.isLoaded.value;
    SafeLogger.d(
      _logTag,
      '$label $tag ${isInitial ? '✅ initial loaded' : '♻️ refreshed'} '
      'adViewId=${ad.adViewId} network=${ad.networkName}',
    );
    listenables.isLoaded.value = true;
    listenables.clearError();
    final adSize = ad.size;
    if (adSize != null) {
      final sz = Size(adSize.width.toDouble(), adSize.height.toDouble());
      if (listenables.adSize.value != sz) listenables.adSize.value = sz;
    }
    slot.markReady();
    if (isInitial) AdSafetyConfig.recordBannerImpression();
    _emit(AdLoadEvent(
      providerTag: tag,
      type: type,
      placement: AdPlacement.unspecified,
      success: true,
    ));
    _emitRevenueIfPresent(ad, type, AdPlacement.unspecified);
  }

  void _handleWidgetAdLoadFailed(BannerListenables listenables, AdSlot slot,
      AdSlotType type, String label, MaxError err) {
    SafeLogger.w(_logTag, '$label $tag ❌ load failed code=${err.code}');
    listenables.isLoaded.value = false;
    listenables.markError();
    slot.markFailed();
    _logIfRepeatedFailure(label, slot, err.code);
    _emit(AdLoadEvent(
      providerTag: tag,
      type: type,
      placement: AdPlacement.unspecified,
      success: false,
      errorCode: err.code.value,
    ));
  }

  /// Round-7 audit, MAJOR — matches AdMob's `_widgetLoadWatchdog`.
  static const Duration _widgetLoadWatchdog = Duration(seconds: 30);

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
    final cfg = _max;
    if (cfg == null) return;
    SafeLogger.d(_logTag, 'preloadBanner $tag 🔄 id=${cfg.bannerId}');
    _ensureWidgetAdViewListener();

    try {
    // M3 — register this key in the slot map AND put it into `loading` before
    // the request goes out. Without it the no-fill handler below was dead code
    // twice over: `_bannerSlotsByKey`/`_mrecSlotsByKey` stayed empty on the
    // success path, and its `if (slot.isLoading)` filter could never be true
    // because nothing on either adapter's widget-format path ever called
    // beginLoad. A banner that got no fill therefore sat in the widget's
    // shimmer for the rest of the session — the resume recovery keys off the
    // failure flags, which never got set — and emitted no failure event, so
    // fill-rate monitoring saw nothing. AdMob's equivalent paths have always
    // called beginLoad; this brings AppLovin in line, and with it the load
    // watchdog that state enables.
    // Round-6 QC — honour the answer. Throwing it away sent the request
    // with the slot left in cooldown, which is precisely the state that made
    // the no-fill handler dead code, so the retry path stayed broken even
    // after the first fix. AdMob's banner path has always returned here, with
    // the same rationale: a flapping banner is cheap to skip.
    final slot = _bannerSlotFor(key);
    // A refusal here is safe to honour outright: the recovery path keeps
    // `BannerListenables.needsRecovery` set until a load actually succeeds, so
    // a slot turned away for being in backoff is simply retried on the next
    // resume rather than stranded blank. No backoff bypass is needed, and the
    // backoff itself is what rate-limits a flapping app.
    if (!slot.beginLoad()) {
      SafeLogger.d(_logTag,
          'preloadBanner $tag \u23ed\ufe0f already loading/showing or in cooldown');
      return;
    }
      final adViewId = await _bridge.preloadWidgetAdView(
        cfg.bannerId,
        AdFormat.banner,
      );
      if (adViewId == null) {
        SafeLogger.w(_logTag, 'banner $tag ❌ preload returned null adViewId');
        // Map lookups, not the `...For(key)` accessors: those are
        // `putIfAbsent`, so on a key whose widget unmounted during the await
        // they would resurrect a fresh slot/listenables pair for a key nobody
        // watches — and a resurrected slot stays in `bannerSlots`, which the
        // reload/refill sweeps iterate, so the adapter would keep requesting
        // ads for a dead widget. Same reason as the identity check below.
        _bannerListenablesByKey[key]?.markError();
        _bannerSlotsByKey[key]?.markFailed();
        return;
      }
      SafeLogger.d(_logTag, 'banner $tag ✅ preload started adViewId=$adViewId');
      // Round-7 audit, MAJOR — the widget owning this key can unmount while
      // the await above is still in flight (route pop, VIP grant, a rebuild
      // that changes the key). `disposeXInstance` then removed the slot,
      // listenables and id notifier from the maps and disposed them — but the
      // `_bannerListenablesFor`/`_bannerAdViewIdFor` accessors below are
      // `putIfAbsent`, so they would silently RESURRECT a fresh set for a key
      // no widget is watching any more, and park this brand-new native AdView
      // in a notifier nothing will ever dispose: a leaked AdView plus a
      // zombie slot that makes every later preload for a re-mounted widget
      // bounce off `beginLoad()`. Identity, not `containsKey`, because dispose
      // followed by a re-mount installs a *different* slot for the same key,
      // and this in-flight load belongs to neither.
      if (!identical(_bannerSlotsByKey[key], slot)) {
        SafeLogger.d(_logTag,
            'banner $tag ⏭️ instance disposed while loading — destroying adViewId='
            '$adViewId');
        unawaited(_destroyWidgetAdViewWhenDetached(adViewId, 'banner'));
        return;
      }
      // Round-7 audit, MAJOR — the M3 comment above promised "and with it the
      // load watchdog that state enables", but nothing ever armed one here.
      // From this point the slot waits on `_ensureWidgetAdViewListener`'s
      // callbacks; if neither ever fires (a mediated network that hangs its
      // own request, a native AdView that never attaches) the slot stays
      // `loading` for the rest of the session, every later preload returns at
      // the `beginLoad()` guard above — including the one the resume recovery
      // makes — and the widget keeps its shimmer forever. AdMob's three widget
      // paths have armed this since MJ20; AppLovin's two had not.
      //
      // The timeout deliberately does NOT destroy the native AdView or clear
      // the id notifier: `markError()` arms `needsRecovery`, and the resume
      // recovery is the path that already knows how to tear the old view down
      // and re-request (see onAppResumed). Doing it twice, from two places, is
      // how the earlier double-destroy leaks happened.
      slot.armLoadWatchdog('banner', _widgetLoadWatchdog, onTimeout: () {
        _bannerListenablesFor(key).isLoaded.value = false;
        _bannerListenablesFor(key).markError();
      });
      final notifier = _bannerAdViewIdFor(key);
      final oldId = notifier.value;
      notifier.value = adViewId;
      // M5 fix (audit_claude.md, 2026-08-20): preloadBanner can be called
      // again for a key that already has a live adViewId (VIP-expiry
      // preload, connectivity-restore refill) — overwriting the notifier
      // without destroying the old native AdView first leaked it exactly
      // like B1, just from a different call path.
      if (oldId != null && oldId != adViewId) {
        unawaited(_destroyWidgetAdViewWhenDetached(oldId, 'banner'));
      }
    } catch (e, st) {
      SafeLogger.e(_logTag, 'banner $tag preload THREW: $e\n$st');
      // Map lookups for the same reason as the null branch above.
      _bannerListenablesByKey[key]?.markError();
      _bannerSlotsByKey[key]?.markFailed();
    }
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
    // No-op by design, not a gap: the banner widget (`_AppLovinMaxAdView` in
    // banner_ad_widget.dart) renders via `MaxAdView(isAdaptiveBannerEnabled:
    // true)`, which reads the live MediaQuery width itself at build time —
    // widthPx has nothing to forward to. See README "AppLovin banner width".
  }

  @override
  Widget? buildAdmobBannerView(Object key) => null;

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
    final cfg = _max;
    if (cfg == null) return;
    if (cfg.mrecId.isEmpty) {
      // Host app doesn't configure MREC — AppLovin's native MaxAdView throws
      // a fatal (uncatchable, off the platform-channel call) IllegalArgumentException
      // "No Ad Unit ID specified" if we call loadAd() with an empty id.
      SafeLogger.d(
          _logTag, 'preloadMrec $tag ⏭️ skipped — no mrecId configured');
      return;
    }
    SafeLogger.d(_logTag, 'preloadMrec $tag 🔄 id=${cfg.mrecId}');
    _ensureWidgetAdViewListener();

    try {
    // M3 — register this key in the slot map AND put it into `loading` before
    // the request goes out. Without it the no-fill handler below was dead code
    // twice over: `_bannerSlotsByKey`/`_mrecSlotsByKey` stayed empty on the
    // success path, and its `if (slot.isLoading)` filter could never be true
    // because nothing on either adapter's widget-format path ever called
    // beginLoad. A banner that got no fill therefore sat in the widget's
    // shimmer for the rest of the session — the resume recovery keys off the
    // failure flags, which never got set — and emitted no failure event, so
    // fill-rate monitoring saw nothing. AdMob's equivalent paths have always
    // called beginLoad; this brings AppLovin in line, and with it the load
    // watchdog that state enables.
    // Round-6 QC — honour the answer. Throwing it away sent the request
    // with the slot left in cooldown, which is precisely the state that made
    // the no-fill handler dead code, so the retry path stayed broken even
    // after the first fix. AdMob's banner path has always returned here, with
    // the same rationale: a flapping mrec is cheap to skip.
    final slot = _mrecSlotFor(key);
    // A refusal here is safe to honour outright: the recovery path keeps
    // `BannerListenables.needsRecovery` set until a load actually succeeds, so
    // a slot turned away for being in backoff is simply retried on the next
    // resume rather than stranded blank. No backoff bypass is needed, and the
    // backoff itself is what rate-limits a flapping app.
    if (!slot.beginLoad()) {
      SafeLogger.d(_logTag,
          'preloadMrec $tag \u23ed\ufe0f already loading/showing or in cooldown');
      return;
    }
      final adViewId = await _bridge.preloadWidgetAdView(
        cfg.mrecId,
        AdFormat.mrec,
      );
      if (adViewId == null) {
        SafeLogger.w(_logTag, 'mrec $tag ❌ preload returned null adViewId');
        // Map lookups, not the `...For(key)` accessors: those are
        // `putIfAbsent`, so on a key whose widget unmounted during the await
        // they would resurrect a fresh slot/listenables pair for a key nobody
        // watches — and a resurrected slot stays in `bannerSlots`, which the
        // reload/refill sweeps iterate, so the adapter would keep requesting
        // ads for a dead widget. Same reason as the identity check below.
        _mrecListenablesByKey[key]?.markError();
        _mrecSlotsByKey[key]?.markFailed();
        return;
      }
      SafeLogger.d(_logTag, 'mrec $tag ✅ preload started adViewId=$adViewId');
      // Round-7 audit, MAJOR — the widget owning this key can unmount while
      // the await above is still in flight (route pop, VIP grant, a rebuild
      // that changes the key). `disposeXInstance` then removed the slot,
      // listenables and id notifier from the maps and disposed them — but the
      // `_mrecListenablesFor`/`_mrecAdViewIdFor` accessors below are
      // `putIfAbsent`, so they would silently RESURRECT a fresh set for a key
      // no widget is watching any more, and park this brand-new native AdView
      // in a notifier nothing will ever dispose: a leaked AdView plus a
      // zombie slot that makes every later preload for a re-mounted widget
      // bounce off `beginLoad()`. Identity, not `containsKey`, because dispose
      // followed by a re-mount installs a *different* slot for the same key,
      // and this in-flight load belongs to neither.
      if (!identical(_mrecSlotsByKey[key], slot)) {
        SafeLogger.d(_logTag,
            'mrec $tag ⏭️ instance disposed while loading — destroying adViewId='
            '$adViewId');
        unawaited(_destroyWidgetAdViewWhenDetached(adViewId, 'mrec'));
        return;
      }
      // Round-7 audit, MAJOR — the M3 comment above promised "and with it the
      // load watchdog that state enables", but nothing ever armed one here.
      // From this point the slot waits on `_ensureWidgetAdViewListener`'s
      // callbacks; if neither ever fires (a mediated network that hangs its
      // own request, a native AdView that never attaches) the slot stays
      // `loading` for the rest of the session, every later preload returns at
      // the `beginLoad()` guard above — including the one the resume recovery
      // makes — and the widget keeps its shimmer forever. AdMob's three widget
      // paths have armed this since MJ20; AppLovin's two had not.
      //
      // The timeout deliberately does NOT destroy the native AdView or clear
      // the id notifier: `markError()` arms `needsRecovery`, and the resume
      // recovery is the path that already knows how to tear the old view down
      // and re-request (see onAppResumed). Doing it twice, from two places, is
      // how the earlier double-destroy leaks happened.
      slot.armLoadWatchdog('mrec', _widgetLoadWatchdog, onTimeout: () {
        _mrecListenablesFor(key).isLoaded.value = false;
        _mrecListenablesFor(key).markError();
      });
      final notifier = _mrecAdViewIdFor(key);
      final oldId = notifier.value;
      notifier.value = adViewId;
      // M5 fix — see the matching comment in preloadBanner above.
      if (oldId != null && oldId != adViewId) {
        unawaited(_destroyWidgetAdViewWhenDetached(oldId, 'mrec'));
      }
    } catch (e, st) {
      SafeLogger.e(_logTag, 'mrec $tag preload THREW: $e\n$st');
      // Map lookups for the same reason as the null branch above.
      _mrecListenablesByKey[key]?.markError();
      _mrecSlotsByKey[key]?.markFailed();
    }
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
    // No-op: AppLovin's MaxAdView is fixed-size (300x250) for MREC — there is
    // no adaptive width to forward, unlike AdMob's separate mrec code path.
  }

  @override
  Widget? buildAdmobMrecView(Object key) => null;

  @override
  Future<void> preloadNative(Object key,
      {TemplateType templateType = TemplateType.medium}) async {
    // T73 — templateType is a Google/AdMob native-template concept; AppLovin
    // has no equivalent (MaxNativeAdView is a self-contained custom-drawn
    // layout), so it's accepted for interface compatibility and ignored.
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
    // No-op: unlike banner/mrec's MaxAdView, MaxNativeAdView is a
    // self-contained widget that loads on mount via its own adUnitId +
    // listener — there is no `preloadWidgetAdView`/adViewId bridge to drive
    // ahead of time for this format.
    SafeLogger.d(_logTag, 'preloadNative $tag (no-op for AppLovin)');
  }

  @override
  Widget? buildAdmobNativeView(Object key) => null;

  @override
  void onAppPaused() {
    // The diagnostic log reads several ValueNotifier values + our slot
    // states. If the host activity is mid-recreation (AppLovin dismiss
    // path on Android can briefly leave Flutter widgets in a weird state),
    // any of these reads CAN theoretically throw — wrap in try-catch so
    // the actual side-effect (disabling banner/mrec autoRefresh) always runs.
    try {
      SafeLogger.d(
        _logTag,
        () => 'onAppPaused $tag '
            '| bannerKeys=${_bannerAdViewIdByKey.length} '
            '| mrecKeys=${_mrecAdViewIdByKey.length} '
            '| inter=${interstitialSlot.value.name} '
            '| rewarded=${rewardedSlot.value.name} '
            '| appOpen=${appOpenSlot.value.name} '
            '| pendingDismissCallback=${_appOpenDismiss != null}',
      );
    } catch (e) {
      SafeLogger.w(_logTag, 'onAppPaused diagnostic log threw: $e');
    }
    try {
      // T65 (phase 2) — every known BannerAdWidget instance, not just one.
      for (final entry in _bannerAdViewIdByKey.entries) {
        if (entry.value.value != null) {
          _bannerListenablesFor(entry.key).autoRefreshEnabled.value = false;
        }
      }
      SafeLogger.d(_logTag, 'onAppPaused $tag — banner.autoRefresh disabled');
    } catch (e, st) {
      SafeLogger.e(_logTag, 'onAppPaused side-effect threw: $e\n$st');
    }
    try {
      // T65 (phase 3) — every known MrecAdWidget instance, not just one.
      for (final entry in _mrecAdViewIdByKey.entries) {
        if (entry.value.value != null) {
          _mrecListenablesFor(entry.key).autoRefreshEnabled.value = false;
        }
      }
      SafeLogger.d(_logTag, 'onAppPaused $tag — mrec.autoRefresh disabled');
    } catch (e, st) {
      SafeLogger.e(_logTag, 'onAppPaused mrec side-effect threw: $e\n$st');
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
    try {
      SafeLogger.d(
        _logTag,
        () => 'onAppResumed $tag '
            '| bannerKeys=${_bannerAdViewIdByKey.length} '
            '| mrecKeys=${_mrecAdViewIdByKey.length} '
            '| inter=${interstitialSlot.value.name} '
            '| rewarded=${rewardedSlot.value.name} '
            '| appOpen=${appOpenSlot.value.name}',
      );
    } catch (e) {
      SafeLogger.w(_logTag, 'onAppResumed diagnostic log threw: $e');
    }
    try {
      // T65 (phase 2) — every known BannerAdWidget instance, not just one.
      for (final key in _bannerListenablesByKey.keys.toList()) {
        final listenables = _bannerListenablesFor(key);
        final adViewIdNotifier = _bannerAdViewIdFor(key);
        if (listenables.needsRecovery) {
          SafeLogger.d(
              _logTag, 'onAppResumed $tag — banner had error, recreating');
          final oldId = adViewIdNotifier.value;
          // Display flag only — `needsRecovery` deliberately stays set until a
          // load actually succeeds, so a request refused below (backoff, closed
          // gate, missing config) is retried on the next resume instead of
          // leaving this key blank forever.
          listenables.hasError.value = false;
          adViewIdNotifier.value = null;
          listenables.autoRefreshEnabled.value = true;
          if (oldId != null) {
            unawaited(_bridge.destroyWidgetAdView(oldId).catchError((e) {
              SafeLogger.w(
                  _logTag, 'destroyWidgetAdView (onAppResumed) threw: $e');
            }));
          }
          preloadBanner(key);
        } else if (adViewIdNotifier.value != null &&
            !bannerRoutePaused(key)) {
          listenables.autoRefreshEnabled.value = true;
          SafeLogger.d(
              _logTag, 'onAppResumed $tag — banner.autoRefresh re-enabled');
        }
      }
    } catch (e, st) {
      SafeLogger.e(_logTag, 'onAppResumed side-effect threw: $e\n$st');
    }
    try {
      // T65 (phase 3) — every known MrecAdWidget instance, not just one.
      for (final key in _mrecListenablesByKey.keys.toList()) {
        final listenables = _mrecListenablesFor(key);
        final adViewIdNotifier = _mrecAdViewIdFor(key);
        if (listenables.needsRecovery) {
          SafeLogger.d(
              _logTag, 'onAppResumed $tag — mrec had error, recreating');
          final oldId = adViewIdNotifier.value;
          // Display flag only — see the banner branch above.
          listenables.hasError.value = false;
          adViewIdNotifier.value = null;
          listenables.autoRefreshEnabled.value = true;
          if (oldId != null) {
            unawaited(_bridge.destroyWidgetAdView(oldId).catchError((e) {
              SafeLogger.w(_logTag,
                  'destroyWidgetAdView (onAppResumed mrec) threw: $e');
            }));
          }
          preloadMrec(key);
        } else if (adViewIdNotifier.value != null && !mrecRoutePaused(key)) {
          listenables.autoRefreshEnabled.value = true;
          SafeLogger.d(
              _logTag, 'onAppResumed $tag — mrec.autoRefresh re-enabled');
        }
      }
    } catch (e, st) {
      SafeLogger.e(_logTag, 'onAppResumed mrec side-effect threw: $e\n$st');
    }
  }
}
