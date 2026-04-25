/// Provides an opaque, type-safe "where in the app this ad fires" identifier.
///
/// Use one of the suggested constants for common placements, or
/// [AdPlacement.custom] for app-specific slots:
///
/// ```dart
/// showInterstitialAd(slot: AdPlacement.home,           onDone: ...);
/// showInterstitialAd(slot: AdPlacement.shop,           onDone: ...);
/// showInterstitialAd(slot: AdPlacement.custom('checkout_v2'), onDone: ...);
/// ```
///
/// The string identifier is what gets emitted in [AdEvent] and used by
/// per-slot frequency caps (Phase 6 extra). Predefined constants exist only
/// for IDE auto-completion / typo prevention — at runtime, every placement is
/// just a string.
class AdPlacement {
  const AdPlacement.custom(this.id);

  /// Opaque identifier — surfaced in [AdEvent] events and used for caps.
  final String id;

  // ─── Suggested constants ──────────────────────────────────────────────────

  /// Generic "home / main screen" placement.
  static const AdPlacement home = AdPlacement.custom('home');

  /// In-app shop / IAP screen.
  static const AdPlacement shop = AdPlacement.custom('shop');

  /// After level/round complete.
  static const AdPlacement levelComplete = AdPlacement.custom('level_complete');

  /// Game-over screen.
  static const AdPlacement gameOver = AdPlacement.custom('game_over');

  /// Settings screen.
  static const AdPlacement settings = AdPlacement.custom('settings');

  /// Splash flow.
  static const AdPlacement splash = AdPlacement.custom('splash');

  /// "Unspecified" — when caller hasn't tagged the placement.
  static const AdPlacement unspecified = AdPlacement.custom('unspecified');

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is AdPlacement && other.id == id);

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'AdPlacement($id)';
}
