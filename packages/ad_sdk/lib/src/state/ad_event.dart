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
  }) : super(type: AdSlotType.rewarded);
  final String? label;
  final num? amount;
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
  });

  /// Revenue in micros (`$1.23` → `1_230_000`).
  final int valueMicros;

  /// Three-letter currency code, e.g. `USD`.
  final String currencyCode;

  /// AppLovin: the winning network of the mediation auction.
  final String? networkName;

  /// AdMob precision token (`'estimated'`, `'precise'`, ...). Null on AppLovin.
  final String? precision;

  /// Convenience: `valueMicros / 1_000_000` as a double.
  double get value => valueMicros / 1000000.0;
}
