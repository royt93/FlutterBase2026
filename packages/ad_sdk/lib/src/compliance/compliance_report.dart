import 'dart:convert';

import '../consent/consent_settings.dart';
import '../core/ad_safety_config.dart';

/// T110 — declares which per-event fields get stripped before a
/// [ComplianceReport] is shared outside the device (e.g. handed to ad
/// network support). The report is generated with everything the SDK
/// tracks; redaction is an explicit, opt-in step the host applies before
/// export — nothing is silently withheld or silently leaked.
class ReportRedactionProfile {
  const ReportRedactionProfile(this.name, this.redactedEventFields);

  /// Shown in previews/logs — not otherwise load-bearing.
  final String name;

  /// Event-entry keys (see [AdEventLog.recordEvent]'s field names) to null
  /// out in every entry. Never touches [ComplianceReport]'s top-level
  /// consent/safety/VIP fields — those are the report's own compliance
  /// evidence, not per-event data, and redacting them would defeat the
  /// report's purpose.
  final Set<String> redactedEventFields;

  /// No redaction — every field the SDK tracked is kept. Use for the host's
  /// own on-device diagnostics only; never hand a `fullLocal` report to a
  /// third party.
  static const fullLocal = ReportRedactionProfile('fullLocal', {});

  /// Strips the two per-event fields most likely to be considered sensitive
  /// under a host's own privacy policy: the host-supplied `consentCountry`
  /// and `placement` (reveals the app's own screen/flow structure). A
  /// reasonable default for "safe to attach to an ad-network support
  /// ticket".
  static const supportSafe =
      ReportRedactionProfile('supportSafe', {'consentCountry', 'placement'});
}

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

  /// Count of [events] carrying a non-null `consentCountry`, grouped by that
  /// value. `consentCountry` is host-supplied analytics (see
  /// [ConsentSettings.country]) — not a real geolocation source, so this is
  /// only as accurate as what the host app chose to attach.
  Map<String, int> get consentCountByCountry {
    final counts = <String, int>{};
    for (final e in events) {
      final country = e['consentCountry'];
      if (country is String) {
        counts[country] = (counts[country] ?? 0) + 1;
      }
    }
    return counts;
  }

  /// T110 — bumped whenever a field in [toJson] is added, removed, or
  /// renamed, so a verifier (or a future version of this SDK) can tell
  /// which shape a given exported/signed report was built against.
  static const int schemaVersion = 1;

  /// T110 — a NEW report with [profile]'s declared event fields nulled out
  /// in every entry of [events]; every other field (consent/safety/VIP,
  /// [generatedAt]/[rangeFrom]/[rangeTo]) is copied unchanged — those are
  /// the report's own compliance evidence, not per-event data a host would
  /// want to strip. [ReportRedactionProfile.fullLocal] (nothing declared)
  /// returns `this` unchanged.
  ///
  /// Call this and read [toJsonString] as a preview BEFORE deciding to
  /// export/sign — then pass the redacted result (not the original) to
  /// `signComplianceReport` so the signature covers what's actually shared.
  ComplianceReport redacted(ReportRedactionProfile profile) {
    if (profile.redactedEventFields.isEmpty) return this;
    return ComplianceReport(
      generatedAt: generatedAt,
      rangeFrom: rangeFrom,
      rangeTo: rangeTo,
      safety: safety,
      hasUserConsent: hasUserConsent,
      isAgeRestrictedUser: isAgeRestrictedUser,
      doNotSell: doNotSell,
      consentHasBeenAsked: consentHasBeenAsked,
      consentAskedAt: consentAskedAt,
      vipActive: vipActive,
      events: [
        for (final e in events)
          {
            for (final entry in e.entries)
              entry.key: profile.redactedEventFields.contains(entry.key)
                  ? null
                  : entry.value,
          },
      ],
    );
  }

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
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
        'consentCountByCountry': consentCountByCountry,
        'events': events,
      };

  String toJsonString({bool pretty = false}) {
    final encoder =
        pretty ? const JsonEncoder.withIndent('  ') : const JsonEncoder();
    return encoder.convert(toJson());
  }
}
