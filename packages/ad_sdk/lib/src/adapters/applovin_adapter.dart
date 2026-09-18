import 'dart:async';
import 'dart:collection';

import 'package:applovin_max/applovin_max.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart' show TemplateType;

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
import 'applovin_ad_revenue.dart';
import 'applovin_bridge.dart';

/// AppLovin MAX implementation of [AdProviderAdapter].
class AppLovinAdapter implements AdProviderAdapter, InlineAdVisibility {
  // Round-23 QC (reviewer B, MAJOR) — inline surfaces are blanked while a
  // fullscreen ad is on screen. Round-26 QC (reviewer A, MINOR) — ownership is
  // counted, not snapshotted; see [InlineVisibilityOwners]. AppLovin has only
  // one owner today (its `onAppPaused` disables auto-refresh rather than
  // blanking), but the bookkeeping is shared so a second one cannot be added
  // here without going through it.
  final InlineVisibilityOwners _inlineVisibility = InlineVisibilityOwners();

  /// The same bookkeeping over `autoRefreshEnabled` — the flag AppLovin
  /// actually honours, since `visible` is only read by the AdMob widget branch.
  final InlineVisibilityOwners _inlineRefresh =
      InlineVisibilityOwners((l) => l.autoRefreshEnabled);

  /// True between `setInlineAdsHidden(true)` and its matching `false`.
  bool _fullscreenOverInline = false;

  /// True between `onAppPaused()` and its matching `onAppResumed()`.
  ///
  /// Round-35 QC (reviewer B, MAJOR) — `_fullscreenOverInline` gets a surface
  /// created while the App Open is up hides it at construction; `background`
  /// had no equivalent, so a key first created while the app was backgrounded
  /// (VIP expiring mid-background is the one process-lifetime path that can
  /// reach it) started with `autoRefreshEnabled == true` and no owner holding
  /// it down — the exact "acquire only reaches pre-existing keys" shape rounds
  /// 28, 30, 31 and 32 each found and fixed for a different owner in this same
  /// file. Mirrors `_fullscreenOverInline` exactly.
  bool _appBackgroundedForInline = false;

  @override
  void setInlineAdsHidden(bool hidden) {
    // Round-29 QC (reviewer B, MAJOR) — `visible` is an AdMob-only flag. Only
    // `_buildAdmob()` in BannerAdWidget/MrecAdWidget reads it; `_buildAppLovin`
    // branches on `hasError` and the ad-view id, so flipping `visible` here was
    // a no-op and a MAX banner kept rendering and auto-refreshing UNDERNEATH
    // the App Open ad. That is the exact policy exposure fix 6 exists to close,
    // left unmitigated for one of the SDK's two shipped providers.
    //
    // Auto-refresh is the flag AppLovin honours, so that is the one to move.
    // `visible` is still tracked through the same ownership so the two
    // providers stay describable in one sentence, and so a future
    // `_buildAppLovin` that does read it inherits the behaviour.
    if (hidden) {
      _fullscreenOverInline = true;
      for (final key in _bannerRegistry.listenablesKeys.toList()) {
        _holdAppLovinInline(_bannerRegistry.listenablesByKey(key)!,
            _bannerAdViewIdByKey[key]?.value, InlineHideReason.fullscreen);
      }
      for (final key in _mrecRegistry.listenablesKeys.toList()) {
        _holdAppLovinInline(_mrecRegistry.listenablesByKey(key)!,
            _mrecAdViewIdByKey[key]?.value, InlineHideReason.fullscreen);
      }
      // Round-44 audit fix — native was never included in this pass (its own
      // doc comment admitted it: "never hides them the way banner/mrec are
      // hidden"), so a live MAX native ad stayed visible underneath an App
      // Open ad. Unlike banner/mrec, native has no auto-refresh ticker to
      // pause (MaxNativeAdView loads once, on mount) — only `visible` needs
      // to move, so this uses `_inlineVisibility` directly instead of
      // `_holdAppLovinInline` (which also takes the refresh hold).
      for (final l in _nativeRegistry.listenablesList) {
        _inlineVisibility.hide(l, InlineHideReason.fullscreen);
      }
      return;
    }
    _fullscreenOverInline = false;
    for (final l in [
      ..._bannerRegistry.listenablesList,
      ..._mrecRegistry.listenablesList,
      ..._nativeRegistry.listenablesList,
    ]) {
      _inlineVisibility.show(l, InlineHideReason.fullscreen);
      // Round-30 QC (reviewer A, MAJOR) — the refresh flag is released BY NAME
      // and comes back only when nobody else holds it. Writing `true` here
      // outright overwrote the pause `onAppPaused()` still owned, restarting a
      // MAX banner's refresh while the app was in the background: impressions
      // on an ad nobody can see, which is the invalid-traffic exposure this
      // whole fix exists to avoid.
      _inlineRefresh.show(l, InlineHideReason.fullscreen);
    }
  }

  /// Re-takes every refresh owner that is still true for [l], after a
  /// `forget()` that dropped all of them along with the discarded ad view.
  ///
  /// Round-32 QC (reviewer B, MAJOR) — the recovery branch used to re-take only
  /// `fullscreen`, so a banner recreated while another route sat on top of it
  /// came back auto-refreshing: billed impressions on a surface the user cannot
  /// see. Asking "which of these is still true?" instead of naming one owner is
  /// the same correction this whole area has needed nine times over.
  void _reassertAppLovinRefreshHolds(BannerListenables l, Object key,
      {required bool isMrec}) {
    if (_fullscreenOverInline) {
      _inlineRefresh.hide(l, InlineHideReason.fullscreen);
    }
    if (isMrec ? mrecRoutePaused(key) : bannerRoutePaused(key)) {
      _inlineRefresh.hide(l, InlineHideReason.routePaused);
    }
    // `background` is deliberately absent: this runs inside `onAppResumed`, so
    // by construction the app is in the foreground.
  }

  /// Pretend a MAX ad view exists for [key], so a test can exercise the
  /// "there is something live to pause" branch without a real bridge.
  @visibleForTesting
  void debugSetBannerAdViewIdForTest(Object key, AdViewId? id) =>
      _bannerAdViewIdFor(key).value = id;

  /// Takes [reason]'s hold on both flags for one inline surface.
  ///
  /// Round-31 QC (both reviewers, BLOCKER) — this used to skip the refresh hold
  /// when no MAX ad view existed yet, reasoning that "claiming it would leave
  /// refresh off when the ad finally arrives". That is precisely what
  /// [InlineVisibilityOwners.show] exists to prevent: the hold is released BY
  /// NAME on dismiss. The guard instead made fix 6 a no-op on the commonest
  /// real sequence — app launches, `BannerAdWidget` mounts, `preloadBanner` is
  /// in flight, the launch App Open goes up and finds `adViewId == null`, the
  /// preload lands, and `MaxAdView` attaches with auto-refresh on and refreshes
  /// underneath the fullscreen ad. `autoRefreshEnabled` is a plain notifier the
  /// widget reads at build time; holding it false before the view exists is
  /// correct.
  void _holdAppLovinInline(
      BannerListenables l, Object? adViewId, InlineHideReason reason) {
    _inlineVisibility.hide(l, reason);
    _inlineRefresh.hide(l, reason);
  }

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

  /// T185 — monotonic per-adapter counter, turned into a fresh
  /// [AdSlot.requestId] every time a fullscreen ad finishes loading. A
  /// plain counter (not a real UUID) is enough: this only ever needs to
  /// be unique within one adapter's lifetime, for on-device correlation.
  int _requestSeq = 0;
  String _nextRequestId() => '$tag-req${_requestSeq++}';

  /// T185 — was an `Expando<String>` keyed by the loaded [MaxAd] INSTANCE
  /// (see the smoke-test audit fix note above `_interstitialCreativeId`'s
  /// declaration for why that never worked against the real plugin: a
  /// fresh `MaxAd` is deserialized per callback, so the revenue callback's
  /// `ad` was NEVER a key already in the Expando — every real AppLovin
  /// fullscreen [AdRevenueEvent.requestId] was silently `null`). Each
  /// `onAdRevenuePaidCallback` below now passes the SLOT's current
  /// `requestId` directly when [_isStaleAd] says the paid event is for the
  /// currently-tracked ad, or `null` when it isn't — same creativeId-based
  /// check as the stale-callback guards, applied to revenue correlation.

  /// Round-31 audit fix — doc was stale/misleading: this is called from
  /// `onAdRevenuePaidCallback` (display/impression time, correct ILRD
  /// semantics), never from a load callback. `MaxAd.revenue` is `0` for no
  /// revenue / test mode → skip.
  ///
  /// Round-32 — the actual mapping now lives in `appLovinRevenueEvent`
  /// (applovin_ad_revenue.dart), shared with the widget-level
  /// banner/mrec/native `onAdRevenuePaidCallback`s, which don't have an
  /// `AppLovinAdapter` instance to call this method on.
  void _emitRevenueIfPresent(
      MaxAd ad, AdSlotType type, AdPlacement placement, String? requestId) {
    final event = appLovinRevenueEvent(ad,
        type: type, placement: placement, requestId: requestId);
    if (event != null) _emit(event);
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
  // T114 — map bookkeeping + disposed-sentinel pattern for slot/listenables
  // extracted into a shared InlineAdInstanceRegistry (see that class's own
  // doc comment); adViewId stays here — it's AppLovin-specific (a native
  // platform view id AdMob has no equivalent of).
  final InlineAdInstanceRegistry _bannerRegistry =
      InlineAdInstanceRegistry(AdSlotType.banner);
  final Map<Object, ValueNotifier<AdViewId?>> _bannerAdViewIdByKey = {};
  final Map<Object, bool> _bannerRoutePausedByKey = {};

  bool _bannerDisposed = false;
  final ValueNotifier<AdViewId?> _disposedBannerAdViewId =
      ValueNotifier<AdViewId?>(null)..dispose();

  // Round-30 QC (reviewer B, MAJOR) — a surface that appears while a
  // fullscreen ad is up inherits the hold; see AdMobAdapter's copy for the
  // reasoning. Round-31 — BOTH flags, because on AppLovin `visible` is inert:
  // `_buildAppLovin` never reads it, so a hold on it alone changes nothing a
  // user or an ad account can see.
  void _inheritBannerFullscreenHold(BannerListenables l) {
    if (_fullscreenOverInline) {
      _inlineVisibility.hide(l, InlineHideReason.fullscreen);
      _inlineRefresh.hide(l, InlineHideReason.fullscreen);
    }
    if (_appBackgroundedForInline) {
      _inlineRefresh.hide(l, InlineHideReason.background);
    }
  }

  ValueNotifier<AdViewId?> _bannerAdViewIdFor(Object key) {
    if (_bannerDisposed) return _disposedBannerAdViewId;
    return _bannerAdViewIdByKey.putIfAbsent(
        key, () => ValueNotifier<AdViewId?>(null));
  }

  @override
  AdSlot bannerSlot(Object key) => _bannerRegistry.slotFor(key);

  @override
  Iterable<AdSlot> get bannerSlots => _bannerRegistry.slots;

  @override
  BannerListenables banner(Object key) => _bannerRegistry.listenablesFor(
        key,
        onCreated: _inheritBannerFullscreenHold,
      );

  @override
  void disposeBannerInstance(Object key) {
    final goneB = _bannerRegistry.removeKey(key);
    if (goneB != null) {
      _inlineVisibility.forget(goneB);
      _inlineRefresh.forget(goneB);
      goneB.dispose();
    }
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
  // T114 (phase 2 of the banner extraction) — map bookkeeping + disposed-
  // sentinel pattern extracted into the same shared InlineAdInstanceRegistry
  // banner already uses; adViewId stays here (AppLovin-specific).
  final InlineAdInstanceRegistry _mrecRegistry =
      InlineAdInstanceRegistry(AdSlotType.mrec);
  final Map<Object, ValueNotifier<AdViewId?>> _mrecAdViewIdByKey = {};
  final Map<Object, bool> _mrecRoutePausedByKey = {};

  bool _mrecDisposed = false;
  final ValueNotifier<AdViewId?> _disposedMrecAdViewId =
      ValueNotifier<AdViewId?>(null)..dispose();

  // Round-30 QC (reviewer B, MAJOR) — a surface that appears while a
  // fullscreen ad is up inherits the hold; see AdMobAdapter's copy for the
  // reasoning. Round-31 — BOTH flags, because on AppLovin `visible` is inert:
  // `_buildAppLovin` never reads it, so a hold on it alone changes nothing a
  // user or an ad account can see.
  void _inheritMrecFullscreenHold(BannerListenables l) {
    if (_fullscreenOverInline) {
      _inlineVisibility.hide(l, InlineHideReason.fullscreen);
      _inlineRefresh.hide(l, InlineHideReason.fullscreen);
    }
    if (_appBackgroundedForInline) {
      _inlineRefresh.hide(l, InlineHideReason.background);
    }
  }

  ValueNotifier<AdViewId?> _mrecAdViewIdFor(Object key) {
    if (_mrecDisposed) return _disposedMrecAdViewId;
    return _mrecAdViewIdByKey.putIfAbsent(
        key, () => ValueNotifier<AdViewId?>(null));
  }

  @override
  AdSlot mrecSlot(Object key) => _mrecRegistry.slotFor(key);

  @override
  Iterable<AdSlot> get mrecSlots => _mrecRegistry.slots;

  @override
  Iterable<AdSlot> get nativeSlots => _nativeRegistry.slots;

  @override
  BannerListenables mrec(Object key) => _mrecRegistry.listenablesFor(
        key,
        onCreated: _inheritMrecFullscreenHold,
      );

  @override
  void disposeMrecInstance(Object key) {
    final goneM = _mrecRegistry.removeKey(key);
    if (goneM != null) {
      _inlineVisibility.forget(goneM);
      _inlineRefresh.forget(goneM);
      goneM.dispose();
    }
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

  /// Set as the first act of [dispose]; see the guard inside
  /// [_destroyWidgetAdViewWhenDetached] for why it is read after an await.
  bool _teardownStarted = false;

  Future<void> _destroyWidgetAdViewWhenDetached(
    AdViewId id,
    String what, {
    int attempt = 0,
  }) async {
    try {
      await _bridge.destroyWidgetAdView(id);
    } catch (e) {
      // Round-25 QC round 17 (`codex`, MAJOR) — checked AFTER the await, not
      // before it: `dispose()` cancels `_destroyRetryTimers` and clears the
      // bridge's listeners, but a destroy that was already in flight fails
      // afterwards (native refuses while the platform view is still attached)
      // and used to arm a FRESH timer at that point — one that outlives the
      // adapter and then talks to a torn-down bridge. Teardown means stop: the
      // native view goes away with its Activity / UIViewController anyway.
      if (_teardownStarted) {
        SafeLogger.d(
            _logTag,
            'destroyWidgetAdView ($what) failed after teardown — not '
            'retrying: $e');
        return;
      }
      if (attempt >= _destroyRetryDelays.length) {
        SafeLogger.w(
            _logTag,
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
  // T114 (phase 3) — map bookkeeping delegated to the same shared
  // InlineAdInstanceRegistry banner/mrec use, but native ALSO needs the
  // per-key tombstone set below (_disposedNativeKeys) — a second, DIFFERENT
  // disposal mechanism the registry does not (and should not) know about;
  // see that field's own doc comment for why identity-checking alone (what
  // banner/mrec use) doesn't work here. `_nativeSlotFor`/`_nativeListenablesFor`
  // below check the tombstone set FIRST, and only delegate to the registry
  // (which handles its own global-disposed sentinel) once a key is neither
  // tombstoned nor the whole adapter torn down.
  final InlineAdInstanceRegistry _nativeRegistry =
      InlineAdInstanceRegistry(AdSlotType.native);

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
  // T104 — LinkedHashSet (insertion-ordered) so eviction below always drops
  // the OLDEST tombstone first. Unbounded before this: a screen that scrolls
  // native ads through a long-lived ListView (T73's exact use case) adds one
  // entry per ad that scrolls away and is never revived, forever. Bounding it
  // trades a vanishingly rare edge case (a callback arriving for a key more
  // than [_maxDisposedNativeKeys] other disposals late) for a hard memory
  // ceiling — the tombstone's whole job is guarding against a callback
  // that's already unusually late; one that's `_maxDisposedNativeKeys`
  // disposals late is not a case worth holding memory open for indefinitely.
  final LinkedHashSet<Object> _disposedNativeKeys = LinkedHashSet<Object>();

  static const int _maxDisposedNativeKeys = 200;

  @visibleForTesting
  int get debugDisposedNativeKeysCount => _disposedNativeKeys.length;

  AdSlot _nativeSlotFor(Object key) {
    if (_nativeDisposed || _disposedNativeKeys.contains(key)) {
      return _disposedNativeSlot ??=
          (AdSlot(type: AdSlotType.native)..dispose());
    }
    return _nativeRegistry.slotFor(key);
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
    // Round-44 audit fix — native now inherits the fullscreen hold on
    // creation, same as banner/mrec, so one that mounts while an App Open is
    // already up starts hidden instead of drawing on top of it.
    return _nativeRegistry.listenablesFor(key,
        onCreated: (l) {
      if (_fullscreenOverInline) {
        _inlineVisibility.hide(l, InlineHideReason.fullscreen);
      }
    });
  }

  @override
  AdSlot nativeSlot(Object key) => _nativeSlotFor(key);

  @override
  BannerListenables native(Object key) => _nativeListenablesFor(key);

  @override
  void disposeNativeInstance(Object key) {
    // Re-inserting an already-present key doesn't change LinkedHashSet's
    // insertion order, so drop-then-add here keeps a revived-then-disposed
    // key correctly moved to the "most recent" end instead of evicting on
    // its original position.
    _disposedNativeKeys.remove(key);
    _disposedNativeKeys.add(key);
    while (_disposedNativeKeys.length > _maxDisposedNativeKeys) {
      _disposedNativeKeys.remove(_disposedNativeKeys.first);
    }
    final gone = _nativeRegistry.removeKey(key);
    if (gone != null) {
      _inlineVisibility.forget(gone);
      gone.dispose();
    }
  }

  /// Lift [key]'s [disposeNativeInstance] tombstone because a live widget is
  /// (re)starting a load for it. Called from `AdManager.recordNativeLoad`.
  ///
  /// Deliberately NOT on [AdProviderAdapter]: that interface is exported, so
  /// a new member there is a source-breaking change for anyone implementing
  /// it, and AdMob would only ever supply an empty body (it guards a
  /// mid-load dispose with slot identity — see `_bannerRegistry.isCurrent(
  /// key, slot)` in admob_adapter.dart — and keeps no tombstone to lift).
  void reviveNativeInstance(Object key) => _disposedNativeKeys.remove(key);

  /// Round-33 audit (R33-03) — public, concrete-class-only (not on
  /// [AdProviderAdapter]; that interface is exported, see
  /// [reviveNativeInstance]'s doc comment for why a new member there is a
  /// breaking change) check for `native_ad_widget.dart`'s
  /// `onAdRevenuePaidCallback`, which writes into shared state
  /// (`AdSafetyConfig`, `eventSink`) rather than a per-key notifier — so it
  /// has no other way to notice a late callback for an already-disposed
  /// [key] the way `onAdLoaded`/`onAdFailedToLoad` do (their write throws on
  /// the disposed sentinel; this one wouldn't).
  bool isNativeInstanceDisposed(Object key) =>
      _disposedNativeKeys.contains(key);

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

  /// Round-29 audit follow-up (MAJOR) — unlike AdMob, AppLovin wires ONE
  /// persistent listener per ad type at `initialize()` time (not a fresh
  /// closure per `show*()` call), so its `onAdHidden`/`onAdDisplayFailed`
  /// callbacks have no closure-local way to know whether they belong to the
  /// cycle currently being shown or a stale one from a prior cycle whose
  /// watchdog already resolved it.
  ///
  /// Smoke-test audit fix (2026-09-17, real device) — this used to be an
  /// `identical(ad, _interstitialAd)` check against the `MaxAd` object
  /// tracked here. **That never worked against the real `applovin_max`
  /// plugin**: its Dart bridge (`AppLovinMAX.createMaxAd`) deserializes a
  /// BRAND NEW `MaxAd` instance from the platform-channel arguments on
  /// EVERY single callback (load, displayed, clicked, revenue, hidden — see
  /// `applovin_max`'s `applovin_max.dart`), so the object handed to
  /// `onAdDisplayedCallback` is never `identical()` to the one stored here
  /// from `onAdLoadedCallback`, even for the exact same real, currently-
  /// displaying ad. On a real device this discarded EVERY legitimate
  /// `displayed`/`hidden`/earned-reward callback as "stale", 100% of the
  /// time — the 10s show-confirmation watchdog then always fired and
  /// reported the ad as "swallowed" even though it was genuinely on screen
  /// (rewarded ads: the user's earned reward was silently dropped). The
  /// existing unit tests never caught this because they thread ONE shared
  /// `MaxAd` instance through load→show→hide (see `applovin_adapter_test.
  /// dart`'s own comments) — an assumption about the real plugin that was
  /// never actually verified against it.
  ///
  /// A same-adapter monotonic counter (tried first, reverted) can't replace
  /// this either: nothing in ANY `MaxAd` callback round-trips a token this
  /// adapter itself minted, so there is no way to tell "a late event for an
  /// ad we've moved on from" apart from "a genuine event for the ad we just
  /// loaded" from timing/sequencing alone — by the time a stale event
  /// arrives, a purely adapter-side counter has already moved on too,
  /// making every check trivially "not stale". `_XCreativeId` below tracks
  /// [MaxAd.creativeId] instead — the one field the real network/mediation
  /// stack actually varies between genuinely different ad instances (real,
  /// revenue-generating loads get a fresh creative ID each time; AppLovin's
  /// OWN test-mode creative can repeat or come back empty, in which case
  /// [_isStaleAd] deliberately trusts the callback rather than guessing —
  /// a wrongly-accepted stale test-mode event costs nothing (0 revenue,
  /// $0 test ad), while wrongly-REJECTING every real one is the bug this
  /// fixes).
  String? _interstitialCreativeId;
  String? _rewardedCreativeId;

  /// Round-31 audit fix (MAJOR) — App Open never got this tracking when
  /// round-29 added it for interstitial/rewarded above. `showAppOpen`'s own
  /// comment documents `onAdHiddenCallback` as "unreliable — sometimes
  /// fires LATE (10-30s)"; without this, a late callback from a cycle the
  /// watchdog already force-resolved could set `_displayConfirmed`/mark
  /// dismissed/reload for whatever NEWER cycle is now current instead of
  /// being discarded as stale. See the smoke-test audit fix note above
  /// `_interstitialCreativeId` — same bug, same creativeId-based fix.
  String? _appOpenCreativeId;

  /// See `_interstitialCreativeId`'s doc comment. `null`/empty on either
  /// side means "no reliable signal" — trust the callback rather than
  /// discard it; AppLovin's own test-mode creatives commonly report an
  /// empty or repeated creative ID, and a real, wrongly-discarded callback
  /// (lost impression, lost reward) is far more costly than a wrongly-
  /// accepted stale test one (zero revenue either way).
  static bool _isStaleAd(String? trackedCreativeId, String incomingCreativeId) =>
      trackedCreativeId != null &&
      trackedCreativeId.isNotEmpty &&
      incomingCreativeId.isNotEmpty &&
      trackedCreativeId != incomingCreativeId;

  /// Audit round 42, MAJOR — [_isStaleAd] cannot tell apart a genuinely
  /// stale cross-cycle event from a genuinely current one when creativeId
  /// is empty/ambiguous on either side (deliberately, per its own doc
  /// comment above — trusting an ambiguous event is right in isolation).
  /// The gap: if cycle A's show-confirmation watchdog ([AdSlot.
  /// showConfirmTimeout], 10s) abandons it and cycle B starts showing
  /// before A's real native callback finally arrives (AppLovin's own docs:
  /// callbacks can be "late by 10-30s"), that late A event — ambiguous,
  /// so trusted — gets attributed to whichever caller B currently occupies
  /// [_rewardedDone]/[_interstitialDone], not to "no one". A user watching
  /// B could be told their (unfinished) ad was shown/earned based on A's
  /// completion, not B's.
  ///
  /// There is no native round-tripped identifier to distinguish the two
  /// events after the fact (the same limitation [_isStaleAd] itself is
  /// built around), so this closes the window from the OTHER end instead:
  /// refuse to START a new show cycle for this long after an abandonment.
  /// By the time a new show genuinely begins, the old cycle's straggler
  /// window has already closed, so any ambiguous event arriving during an
  /// ACTIVE show can be safely trusted as that show's own — exactly
  /// [_isStaleAd]'s original, correct assumption, restored to being true.
  /// Cost: for this long after a (rare — AppLovin fullscreen callbacks are
  /// otherwise reliable) swallowed show, a new show attempt is refused
  /// rather than started; that is a strictly safer failure than misrouting
  /// a reward.
  static const Duration _staleCallbackQuarantine = Duration(seconds: 35);

  bool _interstitialQuarantined = false;
  Timer? _interstitialQuarantineTimer;
  bool _rewardedQuarantined = false;
  Timer? _rewardedQuarantineTimer;

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
    // Round-30 QC (reviewer A) — an owner, not a condition. A MAX banner under
    // another route must not keep refreshing, and `onAppResumed` must be able
    // to release its own hold without having to know about this one.
    final l = banner(key);
    if (paused) {
      // Round-31 QC (reviewer B) — no `adViewId` guard. Pass 8 promoted
      // `routePaused` from a condition to an owner but inherited the same
      // broken *acquire* test: a route that pauses before the ad view attaches
      // took no hold, and the attach site never re-took one, so a MAX banner
      // refreshed underneath the route sitting on top of it.
      _inlineRefresh.hide(l, InlineHideReason.routePaused);
      return;
    }
    _inlineRefresh.show(l, InlineHideReason.routePaused);
  }

  @override
  bool mrecRoutePaused(Object key) => _mrecRoutePausedByKey[key] ?? false;

  @override
  void setMrecRoutePaused(Object key, bool paused) {
    _mrecRoutePausedByKey[key] = paused;
    final l = mrec(key);
    if (paused) {
      _inlineRefresh.hide(l, InlineHideReason.routePaused);
      return;
    }
    _inlineRefresh.show(l, InlineHideReason.routePaused);
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
    // T158 — onAdLoadFailedCallback (banner/MREC, below) disambiguates
    // WHICH surface failed purely by comparing the reported ad-unit id
    // against `cfg.bannerId`/`cfg.mrecId` — the bridge gives no other
    // correlation info on failure. If a host configures the same ad-unit
    // id for both (a plausible copy-paste mistake, not something the SDK
    // can refuse to accept — some networks/setups may even intend a
    // shared unit), that comparison can never tell the two apart, and
    // every MREC failure gets silently misrouted into the banner branch
    // instead (see that callback's own comment). No data is lost — the
    // affected surface still recovers via its 30s watchdog instead of
    // immediately — but it's a real, easy-to-hit footgun worth surfacing
    // loudly rather than only in a code comment nobody reads.
    if (cfg.bannerId.isNotEmpty && cfg.bannerId == cfg.mrecId) {
      SafeLogger.w(
          _logTag,
          '⚠️ AppLovin bannerId and mrecId are configured to the SAME '
          'ad-unit id (${cfg.bannerId}) — a load failure for one cannot be '
          'reliably attributed to the right surface, so an MREC failure '
          'may recover only via the 30s watchdog instead of immediately. '
          'Use two separate ad-unit ids for banner and MREC.');
    }
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
    // Round-30 audit (MAJOR) — this used to run AFTER `_bridge.initialize()`
    // below, which made it a permanent no-op on both platforms: verified
    // against the real `applovin_max` 4.6.4 native plugin source (Android
    // `AppLovinMAX.java`, iOS `AppLovinMAX.m`) — `setTestDeviceAdvertisingIds`
    // only stores into a field that `initialize()`'s OWN config-builder reads
    // exactly once and immediately nils; calling the setter after
    // `initialize()` has already run writes a value nothing ever reads
    // again. Same ordering mistake the consent flags above were explicitly
    // fixed for (MJ1) — moved here to match.
    if (kDebugMode && deviceGaid.isNotEmpty) {
      try {
        _bridge.setTestDeviceAdvertisingIds([deviceGaid]);
        SafeLogger.d(_logTag, 'AppLovin test device registered');
      } catch (e) {
        SafeLogger.w(_logTag, 'setTestDeviceAdvertisingIds failed: $e');
      }
    }
    try {
      await _bridge.initialize(cfg.sdkKey);
      SafeLogger.d(_logTag, 'initialize $tag ✅ SDK ready');
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
    // Round-25 QC round 16 (`codex`, MAJOR) — these three were set at the END
    // of this method, which is too late: the AdView-destroy loops below await
    // the native bridge per view, and a `preloadBanner`/`preloadMrec` that was
    // already in flight resumes inside that await and calls
    // `_bannerAdViewIdFor(key)` — a `putIfAbsent` that INSERTS into the very
    // map being iterated. Dart then throws `Concurrent modification during
    // iteration`, `AdManager._disposeAdapter` swallows it, and the host sees a
    // teardown that "succeeded" while everything after the throw never ran:
    // MREC views not destroyed, pending callbacks never answered, `_max` and
    // `_config` still populated on the abandoned adapter. Setting the flags
    // here makes the accessors hand back their scratch objects instead, so no
    // insertion can happen; the loops below are also iterated over snapshots
    // as a second line of defence.
    _teardownStarted = true;
    // T114 round-1 review (BLOCKER, caught for banner, applied here to mrec
    // from the start) — `markDisposed()` must run HERE, synchronously,
    // before any `await`-based AdView destroy call below — not at the end
    // of this method. A stale callback resuming inside one of those awaits
    // must get the disposed scratch object back from the registry, not the
    // REAL slot/listenables (see InlineAdInstanceRegistry.markDisposed()'s
    // own doc comment for the full race).
    _bannerRegistry.markDisposed();
    _mrecRegistry.markDisposed();
    // Native's OWN `_nativeDisposed` flag (checked first, below) already
    // fully gates `_nativeSlotFor`/`_nativeListenablesFor` before they ever
    // reach `_nativeRegistry` — this call is defense-in-depth (protects
    // against any future code path that calls `_nativeRegistry.slotFor()`/
    // `listenablesFor()` directly), not the actual fix native needed. Native's
    // real race protection is the pre-existing `_disposedNativeKeys`
    // per-key tombstone set (see its own doc comment for why a plain
    // identity check doesn't work for `MaxNativeAdView`'s callbacks).
    _nativeRegistry.markDisposed();
    _bannerDisposed = true;
    _mrecDisposed = true;
    _nativeDisposed = true;
    _appOpenShowTimeout?.cancel();
    _appOpenShowTimeout = null;
    // Audit round 42 — the stale-callback quarantine timers (see
    // `_staleCallbackQuarantine`'s doc comment) must not fire after
    // teardown and touch a disposed adapter's state.
    _interstitialQuarantineTimer?.cancel();
    _interstitialQuarantineTimer = null;
    _rewardedQuarantineTimer?.cancel();
    _rewardedQuarantineTimer = null;
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
    // T105 — nulling the bridge listeners above only stops FUTURE native
    // calls; one already sitting in the Dart event queue when they were
    // nulled still runs on its old closure and still reaches `_emit`, which
    // reads `eventSink` at call time. Nulling it here means that straggler
    // becomes a no-op instead of counting a click/open against a placement
    // that no longer exists — same race class as the round-26 reward-drop
    // fix, just for click/open events instead of a reward.
    eventSink = null;

    // Now destroy the native widget AdViews. Without this the native side
    // keeps the previous banner/mrec alive across destroy → re-init cycles.
    // T65 (phase 2) — every known BannerAdWidget instance's AdView, not just
    // one shared id.
    for (final adViewIdNotifier in _bannerAdViewIdByKey.values.toList()) {
      final oldBannerId = adViewIdNotifier.value;
      if (oldBannerId != null) {
        try {
          await _bridge.destroyWidgetAdView(oldBannerId);
        } catch (e) {
          SafeLogger.w(_logTag, 'destroyWidgetAdView (banner) threw: $e');
        }
      }
    }
    for (final adViewIdNotifier in _mrecAdViewIdByKey.values.toList()) {
      final oldMrecId = adViewIdNotifier.value;
      if (oldMrecId != null) {
        try {
          await _bridge.destroyWidgetAdView(oldMrecId);
        } catch (e) {
          SafeLogger.w(_logTag, 'destroyWidgetAdView (mrec) threw: $e');
        }
      }
    }
    // Round-38 audit fix (own finding, hedge) — a whole-adapter teardown
    // (e.g. a COPPA flip re-initialising AppLovin) can land while one of
    // these is genuinely `isShowing` on screen right now (rare: the host
    // must flip consent at the exact moment a fullscreen ad is up). The
    // listener clears above already mean the real dismiss event can never
    // reach Dart after this point regardless, so the placeholder callback
    // below still has to fire — the caller's pending `await
    // showRewardedAd()`/etc. must not hang forever. There is no
    // programmatic "close this ad" API in AppLovin MAX's plugin bridge, so
    // the native view itself keeps rendering until the user dismisses it —
    // this warning at least makes that rare, otherwise-silent case
    // diagnosable instead of looking like an ordinary teardown.
    for (final entry in {
      'appOpen': appOpenSlot,
      'interstitial': interstitialSlot,
      'rewarded': rewardedSlot,
    }.entries) {
      if (entry.value.isShowing) {
        SafeLogger.w(
            _logTag,
            'dispose() torn down while ${entry.key} was genuinely showing — '
            'its callback fires now with a placeholder outcome so the '
            'caller does not hang, but the native ad view stays on screen '
            '(AppLovin MAX has no programmatic dismiss API)');
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
    for (final slot in _bannerRegistry.slots) {
      slot.reset();
    }
    for (final slot in _mrecRegistry.slots) {
      slot.reset();
    }
    for (final slot in _nativeRegistry.slots) {
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
    _inlineRefresh.forgetAll();
    for (final id in _bannerAdViewIdByKey.values) {
      id.value = null;
    }
    _bannerRoutePausedByKey.clear();
    for (final l in _mrecRegistry.listenablesList) {
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
      ..._bannerRegistry.allKeys,
      ..._bannerAdViewIdByKey.keys,
    }) {
      disposeBannerInstance(key);
    }
    // `_bannerRegistry.markDisposed()`/`_bannerDisposed = true`/
    // `_mrecRegistry.markDisposed()`/`_mrecDisposed = true` already ran at
    // the top of this method — see the round-1 review comment there.
    for (final key in <Object>{
      ..._mrecRegistry.allKeys,
      ..._mrecAdViewIdByKey.keys,
    }) {
      disposeMrecInstance(key);
    }
    for (final key in _nativeRegistry.allKeys) {
      disposeNativeInstance(key);
    }
    // `_nativeRegistry.markDisposed()`/`_nativeDisposed = true` already ran
    // at the top of this method — see the round-1-derived comment there.

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
        // Round-29 audit (BLOCKER) — AdMob's round-27 `_fullscreenDisposed`
        // guard was never ported to AppLovin. A load already in flight when
        // dispose() ran (which sets `_teardownStarted` first, before
        // anything is torn down) still landed here and marked a slot on an
        // adapter nobody owns any more as ready.
        if (_teardownStarted) {
          SafeLogger.w(_logTag,
              'appOpen $tag ⛔ load landed after teardown() — discarding');
          return;
        }
        SafeLogger.d(_logTag, 'appOpen $tag ✅ loaded');
        if (_discardIfConsentStale(appOpenSlot, 'appOpen')) return;
        _appOpenCreativeId = ad.creativeId;
        final requestId = _nextRequestId();
        appOpenSlot.requestId = requestId;
        appOpenSlot.markReady();
        _emit(AdLoadEvent(
          providerTag: tag,
          type: AdSlotType.appOpen,
          placement: AdPlacement.splash,
          success: true,
        ));
      },
      onAdLoadFailedCallback: (id, err) {
        if (_teardownStarted) {
          SafeLogger.w(_logTag,
              'appOpen $tag ⛔ load failure landed after teardown() — discarding');
          return;
        }
        SafeLogger.w(_logTag, 'appOpen $tag ❌ load failed code=${err.code}');
        appOpenSlot.markFailed(errorCode: err.code.value);
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
        // Round-31 audit fix (MAJOR) — this had NO guard at all, unlike
        // interstitial/rewarded (round-29). `onAdHiddenCallback` below is
        // documented as "unreliable — sometimes fires LATE (10-30s)"; the
        // same applies to this callback. Without this, a late display
        // callback from a cycle the watchdog already force-resolved could
        // mark a NEWER cycle's slot displayed before its own ad actually
        // showed — see `_appOpenCreativeId`'s declaration.
        if (_isStaleAd(_appOpenCreativeId, ad.creativeId)) {
          SafeLogger.w(_logTag,
              'appOpen $tag ⚠️ displayed callback for a stale ad (late — a newer cycle is already current) — discarding');
          return;
        }
        appOpenSlot.markDisplayed();
        SafeLogger.d(_logTag, 'appOpen $tag ✅ displayed');
      },
      onAdRevenuePaidCallback: (ad) {
        _emitRevenueIfPresent(
            ad,
            AdSlotType.appOpen,
            AdPlacement.splash,
            _isStaleAd(_appOpenCreativeId, ad.creativeId)
                ? null
                : appOpenSlot.requestId);
      },
      onAdDisplayFailedCallback: (ad, err) {
        _appOpenShowTimeout?.cancel();
        _appOpenShowTimeout = null;
        // Round-31 audit fix (MAJOR) — was `_appOpenDismiss == null`, which
        // only detects "the watchdog already resolved THIS cycle". Once a
        // NEWER cycle calls showAppOpen() again, `_appOpenDismiss` is a
        // fresh non-null closure again, so this check would pass and a
        // late callback carrying the OLD cycle's stale `ad` would resolve
        // the NEW cycle instead. Ad-identity (see `_appOpenCreativeId`'s
        // declaration) catches this cross-cycle case; a same-cycle late
        // arrival always fails it too since `_appOpenCreativeId` only changes on a
        // fresh load.
        if (_isStaleAd(_appOpenCreativeId, ad.creativeId)) {
          SafeLogger.w(_logTag,
              'appOpen $tag ❌ display failed (late — a newer cycle is already current): ${err.message}');
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
        AdSafetyConfig.recordAdClick(fullscreen: true);
        _emit(AdClickEvent(
          providerTag: tag,
          type: AdSlotType.appOpen,
          placement: AdPlacement.splash,
        ));
      },
      onAdHiddenCallback: (ad) {
        _appOpenShowTimeout?.cancel();
        _appOpenShowTimeout = null;
        // Round-31 audit fix (MAJOR) — was `_appOpenDismiss == null`, which
        // only catches a late callback for a cycle the watchdog resolved
        // AND no newer cycle has started yet. Once a NEWER cycle calls
        // showAppOpen() again, `_appOpenDismiss` is a fresh non-null
        // closure, so this check would pass and a late callback carrying
        // the OLD cycle's stale `ad` would resolve/reload the NEW cycle
        // instead — see `_appOpenCreativeId`'s declaration and the "unreliable,
        // sometimes fires LATE" comment in [showAppOpen]. Acting on a stale
        // callback here would clobber whatever state the current cycle has
        // already moved to and fire a SECOND raw `_bridge.loadAppOpenAd`
        // call that bypasses AdManager's VIP/consent/daily-cap gates.
        if (_isStaleAd(_appOpenCreativeId, ad.creativeId)) {
          SafeLogger.d(_logTag,
              'appOpen $tag 👋 hidden (late — a newer cycle is already current)');
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

  /// Resolve an App Open show whose native `onAdHidden` never arrived.
  ///
  /// Round-23 audit, MAJOR — both timeout branches used to report a flat
  /// `dismiss(false)` and charge [AdSlot.markShowFailed]. When the display was
  /// confirmed, that is wrong on three counts: the failure backoff made App
  /// Open progressively rarer for exactly the users who engage with ads
  /// (a click-out to the store is the single most common way this callback is
  /// lost), AdManager recorded no impression against the daily/hourly and
  /// per-placement caps for an ad the user demonstrably saw, and it left the
  /// 30s inter-fullscreen throttle unarmed while the ad could still be on
  /// screen — so the next interstitial could stack straight on top of it.
  ///
  /// Round-24 review — a reviewer asked for the opposite: hold the slot in
  /// `showing` until an authoritative native signal arrives instead of
  /// resolving on a timer. Deliberately not adopted. `showing` blocks both the
  /// next load and the next show, so a lost callback would freeze App Open for
  /// the rest of the process — and a provably-lost callback is the only case
  /// this function ever runs in. Guessing the wrong bucket costs one
  /// impression on one show; holding `showing` forever costs every App Open
  /// after it. The 90s cap is well past any real ad, so the guess is only made
  /// once the callback is already gone.
  void _resolveAppOpenAfterLostCallback(void Function(bool) captured) {
    final displayed = appOpenSlot.displayConfirmed;
    if (displayed) {
      appOpenSlot.markDismissed();
    } else {
      appOpenSlot.markShowFailed();
    }
    _appOpenDismiss = null;
    captured(displayed);
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
            'showAppOpen $tag ⏰ TIMEOUT — app foreground for ${(attempt + 1) * tickSeconds}s without hidden callback (displayed=${appOpenSlot.displayConfirmed})');
        _resolveAppOpenAfterLostCallback(captured);
        return;
      }
      // iOS foreground (ad shows while resumed), or Android backgrounded (ad on
      // screen / user in browser via click): the ad is presumed still up. Keep
      // waiting for the native hidden callback until the 90 s hard cap.
      if (attempt >= maxAttempts) {
        SafeLogger.e(_logTag,
            'showAppOpen $tag ⏰ HARD CAP ${maxAttempts * tickSeconds}s reached (lifecycle=${lifecycle?.name}, displayed=${appOpenSlot.displayConfirmed})');
        _resolveAppOpenAfterLostCallback(captured);
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
        // Round-29 audit (BLOCKER) — same disposed-guard gap as App Open
        // above; see that comment.
        if (_teardownStarted) {
          SafeLogger.w(_logTag,
              'inter $tag ⛔ load landed after teardown() — discarding');
          return;
        }
        SafeLogger.d(_logTag, 'inter $tag ✅ loaded');
        if (_discardIfConsentStale(interstitialSlot, 'inter')) return;
        _interstitialCreativeId = ad.creativeId;
        final requestId = _nextRequestId();
        interstitialSlot.requestId = requestId;
        interstitialSlot.markReady();
        _emit(AdLoadEvent(
          providerTag: tag,
          type: AdSlotType.interstitial,
          placement: AdPlacement.unspecified,
          success: true,
        ));
      },
      onAdLoadFailedCallback: (id, err) {
        if (_teardownStarted) {
          SafeLogger.w(_logTag,
              'inter $tag ⛔ load failure landed after teardown() — discarding');
          return;
        }
        SafeLogger.w(_logTag, 'inter $tag ❌ load failed code=${err.code}');
        interstitialSlot.markFailed(errorCode: err.code.value);
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
        // Round-29 audit follow-up (MAJOR) — a stale `displayed` for an ad
        // this adapter has already moved on from must not disarm the
        // CURRENT cycle's watchdog. See `_interstitialCreativeId`'s declaration.
        if (_isStaleAd(_interstitialCreativeId, ad.creativeId)) {
          SafeLogger.d(_logTag, 'inter $tag ⛔ stale displayed — discarding');
          return;
        }
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
            ad,
            AdSlotType.interstitial,
            AdPlacement.unspecified,
            _isStaleAd(_interstitialCreativeId, ad.creativeId)
                ? null
                : interstitialSlot.requestId);
      },
      onAdDisplayFailedCallback: (ad, err) {
        // Round-29 audit follow-up (MAJOR) — see `_interstitialCreativeId`'s
        // declaration. A stale failure must not touch the current cycle's
        // slot/callback nor trigger a redundant reload.
        if (_isStaleAd(_interstitialCreativeId, ad.creativeId)) {
          SafeLogger.w(
              _logTag, 'inter $tag ⛔ stale display-failed — discarding');
          return;
        }
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
        AdSafetyConfig.recordAdClick(fullscreen: true);
        _emit(AdClickEvent(
          providerTag: tag,
          type: AdSlotType.interstitial,
          placement: AdPlacement.unspecified,
        ));
      },
      onAdHiddenCallback: (ad) {
        // Round-29 audit follow-up (MAJOR) — see `_interstitialCreativeId`'s
        // declaration.
        if (_isStaleAd(_interstitialCreativeId, ad.creativeId)) {
          SafeLogger.d(_logTag, 'inter $tag ⛔ stale hidden — discarding');
          return;
        }
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
    // Audit round 42, MAJOR — see `_staleCallbackQuarantine`'s doc comment.
    if (_interstitialQuarantined) {
      SafeLogger.w(
          _logTag,
          'showInterstitial $tag ⏳ quarantined — a prior cycle\'s '
          'show was never confirmed and its native callback may still be '
          'in flight; refusing a new show until the window clears');
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
      // Audit round 42, MAJOR — see `_staleCallbackQuarantine`'s doc
      // comment. This cycle's real native callback can still arrive late;
      // block a NEW show from starting until that straggler window closes.
      _interstitialQuarantined = true;
      _interstitialQuarantineTimer?.cancel();
      _interstitialQuarantineTimer = Timer(_staleCallbackQuarantine, () {
        _interstitialQuarantined = false;
      });
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
        // Round-29 audit (BLOCKER) — same disposed-guard gap as App Open
        // above; see that comment.
        if (_teardownStarted) {
          SafeLogger.w(_logTag,
              'rewarded $tag ⛔ load landed after teardown() — discarding');
          return;
        }
        SafeLogger.d(_logTag, 'rewarded $tag ✅ loaded');
        if (_discardIfConsentStale(rewardedSlot, 'rewarded')) return;
        _rewardedCreativeId = ad.creativeId;
        final requestId = _nextRequestId();
        rewardedSlot.requestId = requestId;
        rewardedSlot.markReady();
        _emit(AdLoadEvent(
          providerTag: tag,
          type: AdSlotType.rewarded,
          placement: AdPlacement.unspecified,
          success: true,
        ));
      },
      onAdLoadFailedCallback: (id, err) {
        if (_teardownStarted) {
          SafeLogger.w(_logTag,
              'rewarded $tag ⛔ load failure landed after teardown() — discarding');
          return;
        }
        SafeLogger.w(_logTag, 'rewarded $tag ❌ load failed code=${err.code}');
        rewardedSlot.markFailed(errorCode: err.code.value);
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
        // Round-29 audit follow-up (MAJOR) — see `_rewardedCreativeId`'s declaration.
        if (_isStaleAd(_rewardedCreativeId, ad.creativeId)) {
          SafeLogger.d(_logTag, 'rewarded $tag ⛔ stale displayed — discarding');
          return;
        }
        rewardedSlot.markDisplayed();
        SafeLogger.d(_logTag, 'rewarded $tag ✅ displayed');
      },
      onAdRevenuePaidCallback: (ad) {
        _emitRevenueIfPresent(
            ad,
            AdSlotType.rewarded,
            AdPlacement.unspecified,
            _isStaleAd(_rewardedCreativeId, ad.creativeId)
                ? null
                : rewardedSlot.requestId);
      },
      onAdDisplayFailedCallback: (ad, err) {
        if (_isStaleAd(_rewardedCreativeId, ad.creativeId)) {
          SafeLogger.w(
              _logTag, 'rewarded $tag ⛔ stale display-failed — discarding');
          return;
        }
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
            rewardedSlot.armLoadWatchdog(
                'rewarded', const Duration(seconds: 30));
          } catch (e) {
            SafeLogger.e(_logTag, 'reload rewarded threw: $e');
            rewardedSlot.markFailed();
          }
        }
      },
      onAdClickedCallback: (ad) {
        SafeLogger.d(_logTag, 'rewarded $tag 🎯 click');
        AdSafetyConfig.recordAdClick(fullscreen: true);
        _emit(AdClickEvent(
          providerTag: tag,
          type: AdSlotType.rewarded,
          placement: AdPlacement.unspecified,
        ));
      },
      onAdHiddenCallback: (ad) {
        // Round-29 audit follow-up (MAJOR) — see `_rewardedCreativeId`'s declaration.
        // Using ad identity (not `_rewardedDone`, which the earned-reward
        // path below may have already nulled for this SAME, still-current
        // cycle) correctly tells apart "this cycle already earned, now
        // legitimately dismissing" from "a truly stale cycle's hidden event
        // arriving after a newer cycle took over."
        if (_isStaleAd(_rewardedCreativeId, ad.creativeId)) {
          SafeLogger.d(_logTag, 'rewarded $tag ⛔ stale hidden — discarding');
          return;
        }
        SafeLogger.d(_logTag, 'rewarded $tag 👋 hidden');
        final displayed = rewardedSlot.displayConfirmed;
        rewardedSlot.markDismissed();
        final cb = _rewardedDone;
        _rewardedDone = null;
        // Round-23 audit, MAJOR — `shown` is the impression signal and comes
        // from the slot's display confirmation, not from whether a reward was
        // earned: a user who closes the ad early still SAW an ad, and
        // AdManager records it against the fullscreen/placement caps on this
        // flag. (`onAdReceivedReward` fires first when a reward WAS earned, so
        // `_rewardedDone` is already null by here on that path.)
        cb?.call(RewardResult(earned: false, shown: displayed));
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
            rewardedSlot.armLoadWatchdog(
                'rewarded', const Duration(seconds: 30));
          } catch (e) {
            SafeLogger.e(_logTag, 'reload rewarded threw: $e');
            rewardedSlot.markFailed();
          }
        }
      },
      onAdReceivedRewardCallback: (ad, reward) {
        // Round-29 audit follow-up (MAJOR) — see `_rewardedCreativeId`'s declaration.
        // Without this, a stale cycle's late earned-reward event could
        // steal a newer cycle's reward callback.
        if (_isStaleAd(_rewardedCreativeId, ad.creativeId)) {
          SafeLogger.w(
              _logTag, 'rewarded $tag ⛔ stale earned-reward — discarding');
          return;
        }
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
        // Round-23 audit (independent review) — `shown: true` is a constant
        // here on purpose, NOT `rewardedSlot.displayConfirmed`: a reward can
        // only be granted by an ad that was on screen, so the reward is the
        // stronger display proof of the two. Reading `displayConfirmed` would
        // undercount the impression whenever the display callback is lost or
        // arrives late — the very class of bug this round fixed. Locked down by
        // "a reward that arrives with no display callback still reports
        // shown=true" in test/applovin_adapter_test.dart.
        cb?.call(RewardResult(
          earned: true,
          shown: true,
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
    // Audit round 42, MAJOR — see `_staleCallbackQuarantine`'s doc comment.
    // Reward integrity is the highest-stakes case this quarantine protects.
    if (_rewardedQuarantined) {
      SafeLogger.w(
          _logTag,
          'showRewarded $tag ⏳ quarantined — a prior cycle\'s show was '
          'never confirmed and its native callback may still be in '
          'flight; refusing a new show until the window clears');
      onDone(RewardResult.skipped);
      return;
    }
    // Round-7 audit, MAJOR — see [AdSlot.beginShow] and the note on
    // showInterstitial above.
    if (!rewardedSlot.beginShow(onShowNeverConfirmed: () {
      final cb = _rewardedDone;
      _rewardedDone = null;
      // Audit round 42, MAJOR — see `_staleCallbackQuarantine`'s doc
      // comment. This cycle's real native callback can still arrive late;
      // block a NEW show from starting until that straggler window closes.
      _rewardedQuarantined = true;
      _rewardedQuarantineTimer?.cancel();
      _rewardedQuarantineTimer = Timer(_staleCallbackQuarantine, () {
        _rewardedQuarantined = false;
      });
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
        // Round-31 audit — a `_teardownStarted` check (matching round-29's
        // B3 guard on App Open/Interstitial/Rewarded) was tried here and
        // reverted: unlike those three, every mutation this callback makes
        // goes through `_bannerRegistry.slotFor`/`_mrecRegistry.slotFor`, which already
        // return a disposed scratch object once `_bannerDisposed`/
        // `_mrecDisposed` are set — and `dispose()` sets those flags in
        // the SAME synchronous block as `_teardownStarted`, right at its
        // top, well before the `await destroyWidgetAdView(...)` loop a
        // late callback could land during. Confirmed empirically: a
        // callback fired while dispose() is parked in that await still
        // gets a scratch slot with `isLoading == false`, so it's already a
        // no-op. See `dispose()`'s "second line of defence" comment next
        // to where it sets `_bannerDisposed`/`_mrecDisposed`.
        // T65 (phase 3) — same disambiguation as banner below: match the
        // reported adViewId against each known MREC key's own notifier.
        for (final entry in _mrecAdViewIdByKey.entries) {
          if (entry.value.value == ad.adViewId) {
            _handleWidgetAdLoaded(ad, mrec(entry.key),
                _mrecRegistry.slotFor(entry.key), AdSlotType.mrec, 'mrec');
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
        _handleWidgetAdLoaded(ad, banner(matchedKey),
            _bannerRegistry.slotFor(matchedKey), AdSlotType.banner, 'banner');
      },
      onAdLoadFailedCallback: (id, err) {
        // AppLovin passes back the ad-unit id, not the adViewId, on failure —
        // match against the configured bannerId/mrecId instead.
        var isMrec = id == _max?.mrecId && id != _max?.bannerId;
        // T158 — when bannerId == mrecId (see initialize()'s startup
        // warning for this misconfiguration), `id` alone can never tell
        // banner and MREC failures apart — the check above is always
        // false, silently misrouting every MREC failure into the banner
        // branch below. Refine using which registry actually has a load
        // in flight instead: far more often than not, exactly one of the
        // two genuinely does, even sharing an ad-unit id. Left `isMrec =
        // false` (falls through to the banner branch, same as before this
        // fix) for the genuinely ambiguous case — both loading at once,
        // or neither — rather than guessing.
        if (!isMrec && id == _max?.mrecId && id == _max?.bannerId) {
          final mrecLoading = _mrecRegistry.slots.any((slot) => slot.isLoading);
          final bannerLoading =
              _bannerRegistry.slots.any((slot) => slot.isLoading);
          if (mrecLoading && !bannerLoading) isMrec = true;
        }
        if (isMrec) {
          // T65 (phase 3) — same limitation/fallback as banner below: can't
          // attribute the failure to one specific key, so mark every
          // currently-loading MREC key failed.
          for (final key in _mrecRegistry.slotKeys.toList()) {
            final slot = _mrecRegistry.slotFor(key);
            if (slot.isLoading) {
              _handleWidgetAdLoadFailed(
                  mrec(key), slot, AdSlotType.mrec, 'mrec', err);
            }
          }
          return;
        }
        // T65 (phase 2) — the bridge only reports the ad-unit id on failure,
        // not a per-call correlation id, so a failed preload can't be
        // attributed to one specific BannerAdWidget key when multiple are
        // concurrently loading. Known limitation: mark every key currently
        // mid-load as failed rather than leaving any stranded in `loading`.
        for (final key in _bannerRegistry.slotKeys.toList()) {
          final slot = _bannerRegistry.slotFor(key);
          if (slot.isLoading) {
            _handleWidgetAdLoadFailed(
                banner(key), slot, AdSlotType.banner, 'banner', err);
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
    // Round-32 audit fix (MAJOR) — `recordBannerImpression()` and the
    // revenue event used to fire HERE, at fill/load time, not at an actual
    // on-screen impression: a load that fills while the widget is unmounted,
    // hidden, or mid-refresh still counted toward the CTR-fraud denominator
    // and emitted revenue for an ad nobody saw. Same class of bug round-31
    // already fixed for AdMob's banner/MREC (see its `onAdImpression`
    // callback) — moved to the real per-widget `onAdRevenuePaidCallback` in
    // `banner_ad_widget.dart`/`mrec_ad_widget.dart` instead, which is
    // AppLovin's actual impression-with-revenue signal for this ad-view API.
    // `isInitial` is now unused here as a result — kept for the log line.
    _emit(AdLoadEvent(
      providerTag: tag,
      type: type,
      placement: AdPlacement.unspecified,
      success: true,
    ));
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
      // twice over: `_bannerRegistry`'s slot map/`_mrecRegistry`'s slot map stayed empty on the
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
      final slot = _bannerRegistry.slotFor(key);
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
        _bannerRegistry.listenablesByKey(key)?.markError();
        _bannerRegistry.slotByKey(key)?.markFailed();
        return;
      }
      SafeLogger.d(_logTag, 'banner $tag ✅ preload started adViewId=$adViewId');
      // Round-25 QC round 16 — the adapter can be torn down while the preload
      // above is in flight. The native AdView we were just handed belongs to
      // nobody: the id notifier for this key is gone (or is the disposed
      // scratch one), so nothing would ever destroy it. Destroy it directly
      // rather than through `_destroyWidgetAdViewWhenDetached`, whose retry
      // timers were just cancelled by `dispose()` — a retry armed now would
      // outlive the adapter that owns it.
      if (_bannerDisposed) {
        SafeLogger.d(
            _logTag,
            'banner $tag ⏭️ adapter torn down mid-preload — destroying adViewId='
            '$adViewId');
        try {
          await _bridge.destroyWidgetAdView(adViewId);
        } catch (e) {
          SafeLogger.w(
              _logTag, 'destroyWidgetAdView (banner, post-dispose) threw: $e');
        }
        return;
      }
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
      if (!_bannerRegistry.isCurrent(key, slot)) {
        SafeLogger.d(
            _logTag,
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
        banner(key).isLoaded.value = false;
        banner(key).markError();
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
      _bannerRegistry.listenablesByKey(key)?.markError();
      _bannerRegistry.slotByKey(key)?.markFailed();
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
      // twice over: `_bannerRegistry`'s slot map/`_mrecRegistry`'s slot map stayed empty on the
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
      final slot = _mrecRegistry.slotFor(key);
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
        _mrecRegistry.listenablesByKey(key)?.markError();
        _mrecRegistry.slotByKey(key)?.markFailed();
        return;
      }
      SafeLogger.d(_logTag, 'mrec $tag ✅ preload started adViewId=$adViewId');
      // Round-25 QC round 16 — the adapter can be torn down while the preload
      // above is in flight. The native AdView we were just handed belongs to
      // nobody: the id notifier for this key is gone (or is the disposed
      // scratch one), so nothing would ever destroy it. Destroy it directly
      // rather than through `_destroyWidgetAdViewWhenDetached`, whose retry
      // timers were just cancelled by `dispose()` — a retry armed now would
      // outlive the adapter that owns it.
      if (_mrecDisposed) {
        SafeLogger.d(
            _logTag,
            'mrec $tag ⏭️ adapter torn down mid-preload — destroying adViewId='
            '$adViewId');
        try {
          await _bridge.destroyWidgetAdView(adViewId);
        } catch (e) {
          SafeLogger.w(
              _logTag, 'destroyWidgetAdView (mrec, post-dispose) threw: $e');
        }
        return;
      }
      // Round-7 audit, MAJOR — the widget owning this key can unmount while
      // the await above is still in flight (route pop, VIP grant, a rebuild
      // that changes the key). `disposeXInstance` then removed the slot,
      // listenables and id notifier from the maps and disposed them — but the
      // `mrec`/`_mrecAdViewIdFor` accessors below are
      // `putIfAbsent`, so they would silently RESURRECT a fresh set for a key
      // no widget is watching any more, and park this brand-new native AdView
      // in a notifier nothing will ever dispose: a leaked AdView plus a
      // zombie slot that makes every later preload for a re-mounted widget
      // bounce off `beginLoad()`. Identity, not `containsKey`, because dispose
      // followed by a re-mount installs a *different* slot for the same key,
      // and this in-flight load belongs to neither.
      if (!_mrecRegistry.isCurrent(key, slot)) {
        SafeLogger.d(
            _logTag,
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
        mrec(key).isLoaded.value = false;
        mrec(key).markError();
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
      _mrecRegistry.listenablesByKey(key)?.markError();
      _mrecRegistry.slotByKey(key)?.markFailed();
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
    _appBackgroundedForInline = true;
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
      // Round-32 QC (reviewer A, BLOCKER) — every mounted surface, not only
      // those that already have a MAX view. Round 31 removed this same broken
      // *acquire* from `_holdAppLovinInline` and the route setters and left it
      // here: a banner whose preload was in flight when the app backgrounded
      // took no hold, then attached with auto-refresh on while the user was
      // elsewhere. Taken BY NAME, so an App Open dismissed while the app is
      // still backgrounded cannot hand it back.
      for (final l in _bannerRegistry.listenablesList) {
        _inlineRefresh.hide(l, InlineHideReason.background);
      }
      SafeLogger.d(_logTag, 'onAppPaused $tag — banner.autoRefresh disabled');
    } catch (e, st) {
      SafeLogger.e(_logTag, 'onAppPaused side-effect threw: $e\n$st');
    }
    try {
      // T65 (phase 3) — every known MrecAdWidget instance, not just one.
      for (final l in _mrecRegistry.listenablesList) {
        _inlineRefresh.hide(l, InlineHideReason.background);
      }
      SafeLogger.d(_logTag, 'onAppPaused $tag — mrec.autoRefresh disabled');
    } catch (e, st) {
      SafeLogger.e(_logTag, 'onAppPaused mrec side-effect threw: $e\n$st');
    }
  }

  @override
  void onAppResumed() {
    // The app really is in the foreground the instant this runs — cleared
    // before the `canReload()` gate below, same as the ownership releases
    // that gate does not block.
    _appBackgroundedForInline = false;
    // C4, second layer. The five load entry points below are each gated too,
    // so this is defense-in-depth rather than the fix — it bails before the
    // platform-view/width plumbing runs and makes the skip visible in one log
    // line instead of several. Same rationale the SDK already applies in
    // `_retryRefillAds`.
    if (!canReload()) {
      // Round-31 QC (both reviewers, MAJOR) — pass 8 moved this release above
      // the gate in AdMobAdapter and did not carry it here. `onAppPaused` takes
      // the refresh hold with no gate at all, so a resume with the gate shut
      // (offline in a lift, daily cap reached while backgrounded) stranded it
      // and the MAX banner never refreshed again for the session. Releasing a
      // hold requests nothing; it does not belong behind a load gate.
      for (final l in [
        ..._bannerRegistry.listenablesList,
        ..._mrecRegistry.listenablesList,
      ]) {
        _inlineRefresh.show(l, InlineHideReason.background);
      }
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
      for (final key in _bannerRegistry.listenablesKeys.toList()) {
        final listenables = banner(key);
        final adViewIdNotifier = _bannerAdViewIdFor(key);
        // Round-33 QC (reviewer A, MAJOR) — released UNCONDITIONALLY, before
        // either branch below, mirroring AdMob's round-29 fix. The old
        // `else if (adViewIdNotifier.value != null)` guard meant a key whose
        // preload was still in flight when the app backgrounded — no ad view
        // yet, and no error yet either, so neither branch touched it — kept the
        // `background` hold forever: the preload would land, inherit
        // `autoRefreshEnabled == false`, and never refresh again for the
        // session. The app really is in the foreground now; nothing this
        // resume does depends on whether a view exists yet.
        _inlineRefresh.show(listenables, InlineHideReason.background);
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
          // The view is being thrown away and recreated, so no owner's hold on
          // it means anything any more.
          // Round-32 QC (reviewer B, MAJOR) — `forget()` drops EVERY owner, not
          // just the ones tied to the discarded ad view. Round 30 re-took
          // `fullscreen` on the next line and left `routePaused` behind, and
          // nothing else re-takes it because `setBannerRoutePaused` only fires
          // on a transition that has already happened: the recreated MaxAdView
          // attached with auto-refresh on while another route was still on top.
          // Re-assert every owner that is still true rather than one of them.
          _inlineRefresh.forget(listenables);
          listenables.autoRefreshEnabled.value = true;
          _reassertAppLovinRefreshHolds(listenables, key, isMrec: false);
          if (oldId != null) {
            unawaited(_bridge.destroyWidgetAdView(oldId).catchError((e) {
              SafeLogger.w(
                  _logTag, 'destroyWidgetAdView (onAppResumed) threw: $e');
            }));
          }
          preloadBanner(key);
        } else if (adViewIdNotifier.value != null && !bannerRoutePaused(key)) {
          SafeLogger.d(
              _logTag, 'onAppResumed $tag — banner.autoRefresh re-enabled');
        }
      }
    } catch (e, st) {
      SafeLogger.e(_logTag, 'onAppResumed side-effect threw: $e\n$st');
    }
    try {
      // T65 (phase 3) — every known MrecAdWidget instance, not just one.
      for (final key in _mrecRegistry.listenablesKeys.toList()) {
        final listenables = mrec(key);
        final adViewIdNotifier = _mrecAdViewIdFor(key);
        // Same unconditional release as the banner loop above.
        _inlineRefresh.show(listenables, InlineHideReason.background);
        if (listenables.needsRecovery) {
          SafeLogger.d(
              _logTag, 'onAppResumed $tag — mrec had error, recreating');
          final oldId = adViewIdNotifier.value;
          // Display flag only — see the banner branch above.
          listenables.hasError.value = false;
          adViewIdNotifier.value = null;
          // Round-32 QC (reviewer B, MAJOR) — `forget()` drops EVERY owner, not
          // just the ones tied to the discarded ad view. Round 30 re-took
          // `fullscreen` on the next line and left `routePaused` behind, and
          // nothing else re-takes it because `setBannerRoutePaused` only fires
          // on a transition that has already happened: the recreated MaxAdView
          // attached with auto-refresh on while another route was still on top.
          // Re-assert every owner that is still true rather than one of them.
          _inlineRefresh.forget(listenables);
          listenables.autoRefreshEnabled.value = true;
          _reassertAppLovinRefreshHolds(listenables, key, isMrec: true);
          if (oldId != null) {
            unawaited(_bridge.destroyWidgetAdView(oldId).catchError((e) {
              SafeLogger.w(
                  _logTag, 'destroyWidgetAdView (onAppResumed mrec) threw: $e');
            }));
          }
          preloadMrec(key);
        } else if (adViewIdNotifier.value != null && !mrecRoutePaused(key)) {
          SafeLogger.d(
              _logTag, 'onAppResumed $tag — mrec.autoRefresh re-enabled');
        }
      }
    } catch (e, st) {
      SafeLogger.e(_logTag, 'onAppResumed mrec side-effect threw: $e\n$st');
    }
  }
}
