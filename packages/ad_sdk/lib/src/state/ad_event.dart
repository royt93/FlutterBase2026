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
    this.requestId,
  });
  final bool success;

  /// T185 — per-load correlation ID stamped by the adapter (see
  /// [AdSlot.requestId]), carried through to this event so
  /// `RevenueIntegrityLedger` can match this show to its
  /// [AdRevenueEvent] EXACTLY instead of guessing by provider/type/
  /// placement within a time window. `null` for any adapter/format that
  /// doesn't stamp one (banner/mrec/native never emit `AdShowEvent` at
  /// all) — the ledger's pre-T185 time-window match is the exact same
  /// fallback whenever this is null on either side.
  final String? requestId;
}

/// T77 — emitted whenever a `loadX`/`showX` call is gated/skipped before
/// reaching the adapter (VIP suppression, safety cap, cooldown/busy,
/// consent not granted, no network, ...), instead of only going through
/// `SafeLogger`. Lets a host build a funnel/dashboard without parsing log
/// text.
class AdSkipEvent extends AdEvent {
  const AdSkipEvent({
    required super.providerTag,
    required super.type,
    required super.placement,
    required this.action,
    required this.reason,
  });

  /// `'load'` or `'show'`.
  final String action;

  /// Short machine-readable reason, e.g. `'vip'`, `'daily_cap'`, `'cooldown'`,
  /// `'consent'`, `'no_network'`, `'adapter_null'`, `'busy'`.
  final String reason;
}

class AdClickEvent extends AdEvent {
  const AdClickEvent({
    required super.providerTag,
    required super.type,
    required super.placement,
  });
}

/// Round-29 audit (MINOR) — AdMob's `GmaShowCallbacks.onImpression` was
/// wired at the bridge layer (`gma_bridge.dart`) but never passed by any
/// adapter call site, so it was dead: this finishes that wiring for the
/// four AdMob fullscreen types. Not asymmetric with AppLovin — MAX has no
/// equivalent native impression callback, and impressions are already
/// counted via the show-outcome path (`markDisplayed()`/`AdShowEvent`)
/// regardless of this event; this is a distinct, purely additive signal
/// (raw native "impression recorded" moment) for a host that wants it,
/// mirroring [AdClickEvent]'s shape exactly.
class AdImpressionEvent extends AdEvent {
  const AdImpressionEvent({
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
    this.requestId,
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

  /// T185 — see [AdShowEvent.requestId]. `null` for banner/mrec/native (no
  /// matching `AdShowEvent` exists for those to correlate against).
  final String? requestId;

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

/// T127 — flagship self-healing dual-provider runtime, **observe-only**
/// prototype. Emitted by the opt-in `SelfHealingObserver` (default OFF — see
/// `AdManager().enableSelfHealingObserver`) when `WaterfallTuner`'s trailing
/// fill-rate/eCPM data recommends [wouldSwitchToProvider] over the currently
/// active provider for [type]/[placement].
///
/// This is a REPORT, not an action: the SDK still serves exactly one
/// provider per session (`AdConfig.provider`) and this event never causes a
/// provider switch — it exists purely for a host app (or telemetry) to see
/// what a future auto-act version would have done. [providerTag] is the
/// CURRENT provider (the one this recommends moving away from), matching
/// `AdEvent`'s usual "who did/would do this" convention.
class AdSelfHealingObserveEvent extends AdEvent {
  const AdSelfHealingObserveEvent({
    required super.providerTag,
    required super.type,
    required super.placement,
    required this.wouldSwitchToProvider,
    required this.currentScore,
    required this.recommendedScore,
  });

  /// `'[AdMob]'` or `'[AppLovin]'` — the provider the trailing data favors.
  final String wouldSwitchToProvider;

  /// `WaterfallTuner`'s fill-rate×eCPM score for the current provider.
  final double currentScore;

  /// Same score for [wouldSwitchToProvider] — strictly greater than
  /// [currentScore] (that's why this event fired at all).
  final double recommendedScore;
}
