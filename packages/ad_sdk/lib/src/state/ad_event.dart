import 'ad_placement.dart';
import 'ad_slot.dart';

/// Sealed event class emitted on `AdManager().events` stream — Phase 6 (Q19E).
///
/// Lets the host app pipe ad lifecycle into Firebase Analytics, AppsFlyer,
/// Sentry, etc. with zero coupling.
///
/// ```dart
/// AdManager().events.listen((event) {
///   if (event is AdRevenue) {
///     FirebaseAnalytics.instance.logAdImpression(
///       adPlatform: event.providerTag,
///       value: event.amount,
///       currency: event.currency,
///     );
///   }
/// });
/// ```
sealed class AdEvent {
  const AdEvent({
    required this.providerTag,
    required this.type,
    required this.placement,
  });

  /// `'[AdMob]'` or `'[AppLovin]'`.
  final String providerTag;

  final AdSlotType type;
  final AdPlacement placement;
}

class AdLoadEvent extends AdEvent {
  const AdLoadEvent({
    required super.providerTag,
    required super.type,
    required super.placement,
    required this.success,
    this.errorCode,
  });
  final bool success;
  final int? errorCode;
}

class AdShowEvent extends AdEvent {
  const AdShowEvent({
    required super.providerTag,
    required super.type,
    required super.placement,
    required this.success,
  });
  final bool success;
}

class AdClickEvent extends AdEvent {
  const AdClickEvent({
    required super.providerTag,
    required super.type,
    required super.placement,
  });
}

class AdRewardEvent extends AdEvent {
  const AdRewardEvent({
    required super.providerTag,
    required super.placement,
    required this.label,
    required this.amount,
    this.pendingServerConfirmation = false,
  }) : super(type: AdSlotType.rewarded);
  final String? label;
  final num? amount;

  /// Mirrors `RewardResult.pendingServerConfirmation` — true only when the
  /// triggering `showRewardedAd` call supplied `ssvCustomData`/`ssvUserId`.
  /// Purely informational passthrough; this SDK does not verify anything.
  final bool pendingServerConfirmation;
}

/// Emitted when the underlying ad SDK reports paid revenue (`OnPaidEventCallback`
/// for AdMob, ad-revenue listener for AppLovin). Phase 6 (Q19A).
class AdRevenueEvent extends AdEvent {
  const AdRevenueEvent({
    required super.providerTag,
    required super.type,
    required super.placement,
    required this.valueMicros,
    required this.currencyCode,
    this.networkName,
    this.precision,
    this.mediationWaterfall,
  });

  /// Revenue in micros (`$1.23` → `1_230_000`).
  final int valueMicros;

  /// Three-letter currency code, e.g. `USD`.
  final String currencyCode;

  /// AppLovin: the winning network of the mediation auction.
  final String? networkName;

  /// AdMob precision token (`'estimated'`, `'precise'`, ...). Null on AppLovin.
  final String? precision;

  /// Adapter class names tried by the mediation waterfall for this impression.
  ///
  /// AdMob: the full ordered waterfall from `ResponseInfo.adapterResponses`
  /// (one entry per adapter the mediation SDK attempted, winner last).
  /// AppLovin MAX only reports the winning network per impression (no
  /// step-by-step waterfall), so this is a single-element list containing
  /// just that network name. Null if the underlying SDK call didn't return
  /// response info.
  final List<String>? mediationWaterfall;

  /// Convenience: `valueMicros / 1_000_000` as a double.
  double get value => valueMicros / 1000000.0;
}

/// Emitted by [AdSafetyConfig]'s progressive-cooldown trigger (T25) —
/// every CTR anomaly or click-spam detection fires one of these on
/// `AdManager().events`, dry-run mode included (so partners still see the
/// signal even when the block itself is bypassed).
///
/// This is a global, safety-layer diagnostic, not tied to any one ad slot —
/// [providerTag], [type], [placement] carry non-meaningful sentinel values
/// (`'[Safety]'`, [AdSlotType.interstitial], [AdPlacement.unspecified]).
/// Read [reason]/[violationCount]/[pauseDurationMs] instead.
class AdAnomalyEvent extends AdEvent {
  const AdAnomalyEvent({
    required this.reason,
    required this.violationCount,
    required this.pauseDurationMs,
  }) : super(
          providerTag: '[Safety]',
          type: AdSlotType.interstitial,
          placement: AdPlacement.unspecified,
        );

  /// Human-readable trigger, e.g. `'CTR anomaly: ...'` or `'Click spam: ...'`.
  final String reason;

  /// Cumulative suspicious-violation count after this trigger (session-scoped,
  /// persisted across cold starts via [AdPreferences]).
  final int violationCount;

  /// Computed cooldown duration in ms (exponential backoff, capped at 24h).
  final int pauseDurationMs;
}

/// Emitted by the opt-in `MonetizationArbitrator` (default OFF — see
/// `AdManager().enableArbitrator`) when it vetoes a would-have-shown ad in
/// favor of nudging the user toward VIP instead.
///
/// The SDK owns no upsell UI: this is purely a signal on `AdManager().events`
/// for the host app's own listener to react to (e.g. show its VIP screen).
/// [providerTag] carries a non-meaningful sentinel value (`'[Arbitrator]'`) —
/// no ad adapter is involved, since none was shown.
class ArbitratorNudgeEvent extends AdEvent {
  const ArbitratorNudgeEvent({
    required super.type,
    required super.placement,
    required this.estimatedEcpmMicros,
  }) : super(providerTag: '[Arbitrator]');

  /// The trailing eCPM estimate (micros) that led to the veto.
  final int estimatedEcpmMicros;
}
