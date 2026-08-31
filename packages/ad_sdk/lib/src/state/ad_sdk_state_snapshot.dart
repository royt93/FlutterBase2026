/// T109 — a single immutable read of the handful of top-level SDK signals a
/// host commonly needs together (e.g. "should I show a skeleton / disable
/// the watch-ad button right now?") without hand-wiring several separate
/// `ValueListenable`s (`isOfflineListenable`, `canRequestAdsListenable`,
/// `fullscreenBusy`, `vip.activeListenable`, `initRevision`) and reasoning
/// about their update order relative to each other.
class AdSdkStateSnapshot {
  const AdSdkStateSnapshot({
    required this.isInitialised,
    required this.canRequestAds,
    required this.isOffline,
    required this.isVipActive,
    required this.fullscreenBusy,
  });

  /// Mirrors `AdManager.isInitialised` — `initialize()` has completed and an
  /// adapter is live.
  final bool isInitialised;

  /// Mirrors `AdManager.canRequestAds` — consent/footgun gate is open.
  final bool canRequestAds;

  /// Mirrors `AdManager.isOfflineListenable`.
  final bool isOffline;

  /// `false` both when there is no VIP entitlement AND when the SDK hasn't
  /// initialised yet (`vip` is `null` until then) — a host checking "is this
  /// user VIP" gets the same answer either way: don't suppress ad UI.
  final bool isVipActive;

  /// Mirrors `AdManager.fullscreenBusy` — a fullscreen ad (or the loading
  /// buffer dialog) currently owns the screen.
  final bool fullscreenBusy;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AdSdkStateSnapshot &&
          other.isInitialised == isInitialised &&
          other.canRequestAds == canRequestAds &&
          other.isOffline == isOffline &&
          other.isVipActive == isVipActive &&
          other.fullscreenBusy == fullscreenBusy);

  @override
  int get hashCode => Object.hash(
      isInitialised, canRequestAds, isOffline, isVipActive, fullscreenBusy);

  @override
  String toString() => 'AdSdkStateSnapshot(isInitialised: $isInitialised, '
      'canRequestAds: $canRequestAds, isOffline: $isOffline, '
      'isVipActive: $isVipActive, fullscreenBusy: $fullscreenBusy)';
}
