import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart' show TemplateType;

import '../config/ad_config.dart';
import '../core/ad_consent.dart';
import '../core/ad_provider_adapter.dart';
import '../state/ad_event.dart';
import '../state/ad_placement.dart';
import '../state/ad_slot.dart';
import '../utils/safe_logger.dart';

/// T118 — a fully offline, no-network [AdProviderAdapter] that never talks to
/// AdMob or AppLovin. Every load "succeeds" (or "fails", if configured) after
/// [loadDelay], with no ad-unit ID and no platform-channel call — safe for
/// CI, screenshots/App-Store-review builds, or a local demo where burning
/// real ad-network spend/quota is unwanted.
///
/// This is the gap this package's own CI has documented for a while: every
/// integration-test job forces `AD_PROVIDER_ADMOB=true` because no real
/// AppLovin SDK key is committed to this repo (see `.github/workflows/test.yml`
/// and `CLAUDE.md`) — this adapter is a third, always-available option that
/// needs no credentials on either provider.
///
/// ```dart
/// AdManager().initialize(
///   config: AdConfig(provider: AdProvider.admob, admob: someRealConfig),
///   debugAdapterFactory: (_) => FakeAdProviderAdapter(),
/// );
/// ```
///
/// (`debugAdapterFactory` is `@visibleForTesting` — see `AdManager` for the
/// non-test wiring a host would use instead, e.g. picking this adapter only
/// under `kDebugMode` / a build flavor.)
class FakeAdProviderAdapter implements AdProviderAdapter {
  FakeAdProviderAdapter({
    this.shouldSucceed = true,
    this.loadDelay = Duration.zero,
  });

  /// Whether the NEXT load of any format resolves as a success. Read once
  /// per load call, so flip it between calls to script a failure/retry
  /// scenario in a test.
  bool shouldSucceed;

  /// Optional per-slot load outcome override. When null, [shouldSucceed] is
  /// used for every slot.
  Set<AdSlotType>? successfulLoadTypes;

  /// Artificial delay before a load resolves — `Duration.zero` (the
  /// default) resolves on the next microtask, same shape as a real adapter
  /// without actually waiting on anything.
  Duration loadDelay;

  /// Test/QA counters and knobs for deterministic assertions.
  int loadAppOpenCalls = 0;
  int loadInterstitialCalls = 0;
  int loadRewardedCalls = 0;
  int loadRewardedInterstitialCalls = 0;
  int showAppOpenCalls = 0;
  int showInterstitialCalls = 0;
  int showRewardedCalls = 0;
  int showRewardedInterstitialCalls = 0;
  bool appOpenAlreadyReadyNoOp = false;
  bool interstitialAlreadyReadyNoOp = false;
  bool rewardedAlreadyReadyNoOp = false;
  bool rewardedInterstitialAlreadyReadyNoOp = false;

  @override
  AdEventSink? eventSink;

  @override
  bool Function() canReload = () => true;

  @override
  String get tag => '[Fake]';

  bool _initialised = false;
  @override
  bool get isInitialised => _initialised;

  @override
  final AdSlot appOpenSlot = AdSlot(type: AdSlotType.appOpen);
  @override
  final AdSlot interstitialSlot = AdSlot(type: AdSlotType.interstitial);
  @override
  final AdSlot rewardedSlot = AdSlot(type: AdSlotType.rewarded);
  @override
  final AdSlot rewardedInterstitialSlot =
      AdSlot(type: AdSlotType.rewardedInterstitial);

  final Map<Object, AdSlot> _bannerSlots = {};
  final Map<Object, AdSlot> _mrecSlots = {};
  final Map<Object, AdSlot> _nativeSlots = {};
  final Map<Object, BannerListenables> _bannerListenables = {};
  final Map<Object, BannerListenables> _mrecListenables = {};
  final Map<Object, BannerListenables> _nativeListenables = {};

  @override
  AdSlot bannerSlot(Object key) =>
      _bannerSlots.putIfAbsent(key, () => AdSlot(type: AdSlotType.banner));
  @override
  Iterable<AdSlot> get bannerSlots => _bannerSlots.values;

  @override
  AdSlot mrecSlot(Object key) =>
      _mrecSlots.putIfAbsent(key, () => AdSlot(type: AdSlotType.mrec));
  @override
  Iterable<AdSlot> get mrecSlots => _mrecSlots.values;

  @override
  AdSlot nativeSlot(Object key) =>
      _nativeSlots.putIfAbsent(key, () => AdSlot(type: AdSlotType.native));
  @override
  Iterable<AdSlot> get nativeSlots => _nativeSlots.values;

  BannerListenables _listenablesFor(
          Map<Object, BannerListenables> map, Object key) =>
      map.putIfAbsent(
          key,
          () => BannerListenables(
                isLoaded: ValueNotifier<bool>(false),
                hasError: ValueNotifier<bool>(false),
                adSize: ValueNotifier<Size?>(null),
                autoRefreshEnabled: ValueNotifier<bool>(true),
                visible: ValueNotifier<bool>(true),
              ));

  @override
  BannerListenables banner(Object key) => _listenablesFor(_bannerListenables, key);
  @override
  BannerListenables mrec(Object key) => _listenablesFor(_mrecListenables, key);
  @override
  BannerListenables native(Object key) =>
      _listenablesFor(_nativeListenables, key);

  // ─── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  Future<bool> initialize(
    AdConfig config, {
    String deviceGaid = '',
    bool isAgeRestrictedUser = false,
    AdConsent? consent,
  }) async {
    _initialised = true;
    SafeLogger.d(tag, 'initialize [Fake] ✅ (no network, no real ad unit)');
    return true;
  }

  @override
  Future<void> dispose() async {
    _initialised = false;
    for (final slot in [
      appOpenSlot,
      interstitialSlot,
      rewardedSlot,
      rewardedInterstitialSlot,
      ..._bannerSlots.values,
      ..._mrecSlots.values,
      ..._nativeSlots.values,
    ]) {
      slot.dispose();
    }
    for (final l in [
      ..._bannerListenables.values,
      ..._mrecListenables.values,
      ..._nativeListenables.values,
    ]) {
      l.dispose();
    }
    _bannerSlots.clear();
    _mrecSlots.clear();
    _nativeSlots.clear();
    _bannerListenables.clear();
    _mrecListenables.clear();
    _nativeListenables.clear();
  }

  @override
  Future<void> discardCachedFullscreenAds() async {
    for (final slot in [appOpenSlot, interstitialSlot, rewardedSlot]) {
      if (slot.isReady) slot.reset();
    }
  }

  @override
  void applyConsent(AdConsent consent) {}

  // ─── Shared synthetic load/show helpers ────────────────────────────────────

  Future<void> _load(AdSlot slot, AdSlotType type,
      {void Function(bool loaded)? onAdLoaded}) async {
    if (!slot.beginLoad()) return;
    if (loadDelay > Duration.zero) await Future<void>.delayed(loadDelay);
    final succeeded = successfulLoadTypes?.contains(type) ?? shouldSucceed;
    if (succeeded) {
      slot.markReady();
    } else {
      slot.markFailed();
    }
    eventSink?.call(AdLoadEvent(
      providerTag: tag,
      type: type,
      placement: AdPlacement.unspecified,
      success: succeeded,
      errorCode: succeeded ? null : -1,
    ));
    onAdLoaded?.call(succeeded);
  }

  // ─── App Open ──────────────────────────────────────────────────────────────

  @override
  Future<void> loadAppOpen({void Function(bool loaded)? onAdLoaded}) {
    loadAppOpenCalls++;
    if (appOpenAlreadyReadyNoOp) return Future<void>.value();
    return _load(appOpenSlot, AdSlotType.appOpen, onAdLoaded: onAdLoaded);
  }

  @override
  Future<void> showAppOpen(
      {required void Function(bool dismissed) onDismiss}) async {
    showAppOpenCalls++;
    if (!appOpenSlot.beginShow()) {
      onDismiss(false);
      return;
    }
    appOpenSlot.markDisplayed();
    appOpenSlot.markDismissed();
    onDismiss(true);
  }

  // ─── Interstitial ──────────────────────────────────────────────────────────

  @override
  Future<void> loadInterstitial() {
    loadInterstitialCalls++;
    if (interstitialAlreadyReadyNoOp) return Future<void>.value();
    return _load(interstitialSlot, AdSlotType.interstitial);
  }

  @override
  Future<void> showInterstitial(
      {required void Function(bool shown) onDone}) async {
    showInterstitialCalls++;
    if (!interstitialSlot.beginShow()) {
      onDone(false);
      return;
    }
    interstitialSlot.markDisplayed();
    interstitialSlot.markDismissed();
    onDone(true);
  }

  // ─── Rewarded ──────────────────────────────────────────────────────────────

  @override
  Future<void> loadRewarded() {
    loadRewardedCalls++;
    if (rewardedAlreadyReadyNoOp) return Future<void>.value();
    return _load(rewardedSlot, AdSlotType.rewarded);
  }

  @override
  Future<void> showRewarded({
    required void Function(RewardResult result) onDone,
    String? ssvCustomData,
    String? ssvUserId,
  }) async {
    showRewardedCalls++;
    if (!rewardedSlot.beginShow()) {
      onDone(RewardResult.skipped);
      return;
    }
    rewardedSlot.markDisplayed();
    rewardedSlot.markDismissed();
    onDone(const RewardResult(earned: true, shown: true));
  }

  // ─── Rewarded Interstitial ─────────────────────────────────────────────────

  @override
  Future<void> loadRewardedInterstitial() {
    loadRewardedInterstitialCalls++;
    if (rewardedInterstitialAlreadyReadyNoOp) return Future<void>.value();
    return _load(rewardedInterstitialSlot, AdSlotType.rewardedInterstitial);
  }

  @override
  Future<void> showRewardedInterstitial({
    required void Function(RewardResult result) onDone,
  }) async {
    showRewardedInterstitialCalls++;
    if (!rewardedInterstitialSlot.beginShow()) {
      onDone(RewardResult.skipped);
      return;
    }
    rewardedInterstitialSlot.markDisplayed();
    rewardedInterstitialSlot.markDismissed();
    onDone(const RewardResult(earned: true, shown: true));
  }

  // ─── Banner ────────────────────────────────────────────────────────────────

  @override
  Future<void> preloadBanner(Object key) async {}

  @override
  Future<void> loadBannerIfNeeded(Object key, double widthPx) async {
    final slot = bannerSlot(key);
    final l = banner(key);
    await _load(slot, AdSlotType.banner);
    if (slot.isReady) {
      l.clearError();
      l.isLoaded.value = true;
      l.adSize.value = Size(widthPx, 50);
    } else {
      l.markError();
    }
  }

  @override
  Widget? buildAdmobBannerView(Object key) =>
      banner(key).isLoaded.value ? const _FakePlaceholderAd(label: 'Fake banner') : null;

  final Map<Object, bool> _bannerRoutePausedByKey = {};
  @override
  bool bannerRoutePaused(Object key) => _bannerRoutePausedByKey[key] ?? false;
  @override
  void setBannerRoutePaused(Object key, bool paused) =>
      _bannerRoutePausedByKey[key] = paused;

  @override
  String? get appLovinBannerId => null; // fake never speaks AppLovin
  @override
  ValueListenable<Object?> appLovinBannerAdViewId(Object key) =>
      _appLovinAdViewIdStub;
  static final ValueNotifier<Object?> _appLovinAdViewIdStub =
      ValueNotifier<Object?>(null);

  @override
  void disposeBannerInstance(Object key) {
    _bannerSlots.remove(key)?.dispose();
    _bannerListenables.remove(key)?.dispose();
    _bannerRoutePausedByKey.remove(key);
  }

  // ─── MREC ──────────────────────────────────────────────────────────────────

  @override
  Future<void> preloadMrec(Object key) async {}

  @override
  Future<void> loadMrecIfNeeded(Object key, double widthPx) async {
    final slot = mrecSlot(key);
    final l = mrec(key);
    await _load(slot, AdSlotType.mrec);
    if (slot.isReady) {
      l.clearError();
      l.isLoaded.value = true;
      l.adSize.value = const Size(300, 250);
    } else {
      l.markError();
    }
  }

  @override
  Widget? buildAdmobMrecView(Object key) =>
      mrec(key).isLoaded.value ? const _FakePlaceholderAd(label: 'Fake MREC') : null;

  final Map<Object, bool> _mrecRoutePausedByKey = {};
  @override
  bool mrecRoutePaused(Object key) => _mrecRoutePausedByKey[key] ?? false;
  @override
  void setMrecRoutePaused(Object key, bool paused) =>
      _mrecRoutePausedByKey[key] = paused;

  @override
  String? get appLovinMrecId => null;
  @override
  ValueListenable<Object?> appLovinMrecAdViewId(Object key) =>
      _appLovinAdViewIdStub;

  @override
  void disposeMrecInstance(Object key) {
    _mrecSlots.remove(key)?.dispose();
    _mrecListenables.remove(key)?.dispose();
    _mrecRoutePausedByKey.remove(key);
  }

  // ─── Native ────────────────────────────────────────────────────────────────

  @override
  Future<void> preloadNative(Object key,
      {TemplateType templateType = TemplateType.medium}) async {
    final slot = nativeSlot(key);
    final l = native(key);
    await _load(slot, AdSlotType.native);
    if (slot.isReady) {
      l.clearError();
      l.isLoaded.value = true;
    } else {
      l.markError();
    }
  }

  @override
  Widget? buildAdmobNativeView(Object key) =>
      native(key).isLoaded.value ? const _FakePlaceholderAd(label: 'Fake native') : null;

  @override
  void disposeNativeInstance(Object key) {
    _nativeSlots.remove(key)?.dispose();
    _nativeListenables.remove(key)?.dispose();
  }

  @override
  String? get appLovinNativeId => null;

  // ─── Lifecycle hooks ────────────────────────────────────────────────────────

  @override
  void onAppPaused() {}

  @override
  void onAppResumed() {}
}

/// Minimal, unmistakably-fake visual so a host glancing at a screenshot (or
/// this adapter's own widget tests) can immediately tell it isn't a real ad
/// unit. Intentionally not configurable — this adapter is for CI/demo, not
/// for building a look-alike placeholder UI.
class _FakePlaceholderAd extends StatelessWidget {
  const _FakePlaceholderAd({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: const Color(0xFFDDDDDD),
        child: Center(
          child: Text(label, style: const TextStyle(color: Color(0xFF666666))),
        ),
      );
}
