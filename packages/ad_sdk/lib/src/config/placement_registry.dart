import '../state/ad_slot.dart' show AdSlotType;

/// T140 — per-placement BEHAVIOR overrides only. Deliberately does NOT
/// store ad unit IDs: those stay the single source of truth on
/// [AdMobConfig]/[AppLovinConfig] (see [PlacementRegistry]'s own doc
/// comment for why a second ID source would be a real risk here).
class PlacementSpec {
  const PlacementSpec({
    required this.format,
    this.frequencyCapOverride,
    this.minIntervalOverrideMs,
  });

  /// Which ad format this spec applies to. Enforced against the actual
  /// show call: `frequencyCapOverride` only applies when the show
  /// method's own format (`showInterstitial` → [AdSlotType.interstitial],
  /// etc.) matches this exactly (see `AdManager._placementCapOverride`).
  /// A mismatch — this [AdPlacement.id] reused across two different
  /// formats, say — silently skips the override for the non-matching
  /// call (falls back to whatever `AdSafetyParams` alone would resolve
  /// to), it does not throw or log; a host relying on the override firing
  /// for a format it didn't register should catch that via its own
  /// testing, same as any other misconfigured spec.
  final AdSlotType format;

  /// When set, this placement's daily cap for THIS show call becomes this
  /// value instead of whatever `AdSafetyParams.maxPerPlacementAdsPerDay` /
  /// `maxPerPlacementAdsPerDayById` would otherwise resolve to for it (see
  /// `AdSafetyConfig.placementDailyCapReached`'s `capOverride` parameter).
  /// `null` (default) — no override, existing `AdSafetyParams`-configured
  /// cap (or no cap at all) applies unchanged.
  final int? frequencyCapOverride;

  /// T181 — when set, this placement's minimum interval since the last
  /// fullscreen ad (any format — the app-wide throttle it overrides is
  /// itself global, not per-format) becomes this value, in milliseconds,
  /// instead of `AdSafetyParams.minTimeBetweenFullscreenAds` (see
  /// `AdSafetyConfig.canShowFullscreenAd`'s `minIntervalOverrideMs`
  /// parameter). Same override semantics as [frequencyCapOverride]: applies
  /// for THIS show call only, never mutates the underlying configured
  /// value, and `null` (default) leaves the app-wide throttle unchanged.
  ///
  /// A SMALLER value here loosens this placement's own throttle relative to
  /// the rest of the app (e.g. a rewarded-video placement the host wants
  /// available more often than interstitials); a LARGER value tightens it.
  /// Either way this only affects the "time since last fullscreen ad of ANY
  /// kind" check for a show attempt through THIS placement's format — it
  /// never changes what counts as "the last fullscreen ad" for any other
  /// placement's own check. A NEGATIVE value is rejected and falls back to
  /// the app-wide value, same as `null` — `0` is the real "no throttle for
  /// this placement" bypass; a negative number must not silently disable a
  /// real safety throttle.
  final int? minIntervalOverrideMs;
}

/// T140 — maps [AdPlacement.id] (the SDK's existing placement-identity
/// concept — see `ad_placement.dart`) to an optional [PlacementSpec]
/// behavior override. Pass to [AdConfig.placements]; `null` (the default)
/// leaves every show call's behavior completely unchanged — this is a
/// purely additive, opt-in feature.
///
/// Deliberately keyed by the SAME [AdPlacement] every show method
/// (`showInterstitial`, `showRewardedAd`, ...) already takes — no new
/// `placementId` parameter was added to those methods. A second identity
/// concept living alongside the existing one would risk exactly the kind
/// of "which one is the real source of truth" confusion this feature's
/// own design note warns against for ad unit IDs; reusing
/// `AdPlacement.id` avoids inventing that problem for placement identity
/// too.
///
/// ```dart
/// AdConfig(
///   // ...
///   placements: const PlacementRegistry({
///     'level_complete': PlacementSpec(
///       format: AdSlotType.interstitial,
///       frequencyCapOverride: 3, // stricter than the global default here
///       minIntervalOverrideMs: 120000, // 2 min — looser than app-wide here
///     ),
///   }),
/// )
/// ```
class PlacementRegistry {
  const PlacementRegistry(this._specs);

  // Round-2 independent review (MINOR) — stores the caller's Map
  // reference directly, no defensive copy, so this stays a `const`-
  // constructible config object (matching every other AdConfig field's
  // style). Pass a `const` map (as the example above does) for a spec
  // that never changes — this is the norm and what every existing caller
  // does. If a host deliberately passes a mutable Map instead, mutating it
  // after `initialize()` DOES change behavior live for later show calls
  // (no snapshot is taken) — that is allowed on purpose, not a bug, but
  // it is the host's responsibility to know if it does that.
  final Map<String, PlacementSpec> _specs;

  /// `null` if [placementId] has no registered [PlacementSpec] — every
  /// existing call site treats that identically to the registry not being
  /// configured at all.
  PlacementSpec? operator [](String placementId) => _specs[placementId];
}
