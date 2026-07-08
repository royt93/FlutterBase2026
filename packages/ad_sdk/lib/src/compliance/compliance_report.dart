import 'dart:convert';

import '../consent/consent_settings.dart';
import '../core/ad_safety_config.dart';

/// Evidence bundle a partner (or the dev) can hand to AdMob/AppLovin support
/// when an account is flagged/suspended: what consent state was in effect,
/// what the safety layer was enforcing, and the raw ad-event history for the
/// requested window. Built entirely from data the SDK already tracks —
/// nothing new is collected.
class ComplianceReport {
  const ComplianceReport({
    required this.generatedAt,
    required this.rangeFrom,
    required this.rangeTo,
    required this.safety,
    required this.hasUserConsent,
    required this.isAgeRestrictedUser,
    required this.doNotSell,
    required this.consentHasBeenAsked,
    required this.consentAskedAt,
    required this.vipActive,
    required this.events,
  });

  /// [events] should already be filtered to `[from, to]` by the caller
  /// (typically [AdEventLog.inRange]) — kept as a plain list here so this
  /// factory doesn't require a live [AdEventLog] instance.
  factory ComplianceReport.generate({
    required List<Map<String, dynamic>> events,
    required AdSafetySnapshot safety,
    required ConsentSettings consent,
    required bool vipActive,
    DateTime? from,
    DateTime? to,
    DateTime? now,
  }) {
    return ComplianceReport(
      generatedAt: now ?? DateTime.now(),
      rangeFrom: from,
      rangeTo: to,
      safety: safety,
      hasUserConsent: consent.hasUserConsent,
      isAgeRestrictedUser: consent.isAgeRestrictedUser,
      doNotSell: consent.doNotSell,
      consentHasBeenAsked: consent.hasBeenAsked,
      consentAskedAt: consent.askedAt,
      vipActive: vipActive,
      events: events,
    );
  }

  final DateTime generatedAt;
  final DateTime? rangeFrom;
  final DateTime? rangeTo;
  final AdSafetySnapshot safety;
  final bool hasUserConsent;
  final bool isAgeRestrictedUser;
  final bool doNotSell;
  final bool consentHasBeenAsked;
  final DateTime? consentAskedAt;
  final bool vipActive;
  final List<Map<String, dynamic>> events;

  Map<String, dynamic> toJson() => {
        'generatedAt': generatedAt.toIso8601String(),
        'rangeFrom': rangeFrom?.toIso8601String(),
        'rangeTo': rangeTo?.toIso8601String(),
        'safety': safety.toJson(),
        'consent': {
          'hasUserConsent': hasUserConsent,
          'isAgeRestrictedUser': isAgeRestrictedUser,
          'doNotSell': doNotSell,
          'hasBeenAsked': consentHasBeenAsked,
          'askedAt': consentAskedAt?.toIso8601String(),
        },
        'vipActive': vipActive,
        'eventCount': events.length,
        'events': events,
      };

  String toJsonString({bool pretty = false}) {
    final encoder =
        pretty ? const JsonEncoder.withIndent('  ') : const JsonEncoder();
    return encoder.convert(toJson());
  }
}
