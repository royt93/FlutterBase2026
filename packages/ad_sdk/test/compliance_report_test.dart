// Unit tests for ComplianceReport (T23).

import 'package:applovin_admob_sdk/src/compliance/compliance_report.dart';
import 'package:applovin_admob_sdk/src/consent/consent_settings.dart';
import 'package:applovin_admob_sdk/src/core/ad_safety_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const snapshot = AdSafetySnapshot(
    fullscreenAdsShownInSession: 2,
    maxFullscreenAdsPerSession: 6,
    hourlyAdCount: 1,
    maxFullscreenAdsPerHour: 3,
    dailyAdCount: 4,
    maxFullscreenAdsPerDay: 5,
    clickThroughRate: 0.1,
    suspiciousCtrThreshold: 0.3,
    clicksLastMinute: 0,
    suspiciousViolationCount: 0,
    isSuspended: false,
    dryRun: false,
  );

  group('generate', () {
    test('handles an empty event log without throwing', () {
      final report = ComplianceReport.generate(
        events: const [],
        safety: snapshot,
        consent: ConsentSettings.unset,
        vipActive: false,
        now: DateTime.utc(2026, 1, 1),
      );

      expect(report.events, isEmpty);
      expect(report.generatedAt, DateTime.utc(2026, 1, 1));
      expect(report.vipActive, isFalse);
      expect(report.hasUserConsent, isFalse);
    });

    test('carries through consent, safety and VIP state verbatim', () {
      final consent = ConsentSettings.accepted;
      final report = ComplianceReport.generate(
        events: const [
          {'kind': 'ad_event', 'timestampMs': 10},
        ],
        safety: snapshot,
        consent: consent,
        vipActive: true,
      );

      expect(report.hasUserConsent, isTrue);
      expect(report.consentHasBeenAsked, isTrue);
      expect(report.vipActive, isTrue);
      expect(report.safety.dailyAdCount, 4);
      expect(report.events, hasLength(1));
    });

    test('consentCountByCountry counts non-null consentCountry, ignores null',
        () {
      final report = ComplianceReport.generate(
        events: const [
          {'kind': 'ad_event', 'timestampMs': 1, 'consentCountry': 'DE'},
          {'kind': 'ad_event', 'timestampMs': 2, 'consentCountry': 'DE'},
          {'kind': 'ad_event', 'timestampMs': 3, 'consentCountry': 'US'},
          {'kind': 'ad_event', 'timestampMs': 4, 'consentCountry': null},
          {'kind': 'ad_event', 'timestampMs': 5},
        ],
        safety: snapshot,
        consent: ConsentSettings.unset,
        vipActive: false,
      );

      expect(report.consentCountByCountry, {'DE': 2, 'US': 1});
    });

    test('preserves the requested range even if no events fall inside it', () {
      final from = DateTime.utc(2026, 1, 1);
      final to = DateTime.utc(2026, 1, 2);
      final report = ComplianceReport.generate(
        events: const [],
        safety: snapshot,
        consent: ConsentSettings.unset,
        vipActive: false,
        from: from,
        to: to,
      );

      expect(report.rangeFrom, from);
      expect(report.rangeTo, to);
    });
  });

  group('toJson / toJsonString', () {
    test('round-trips every top-level field', () {
      final report = ComplianceReport.generate(
        events: const [
          {'kind': 'safety_block', 'timestampMs': 5, 'reason': 'Hourly cap'},
        ],
        safety: snapshot,
        consent: ConsentSettings.rejected,
        vipActive: false,
        now: DateTime.utc(2026, 5, 1),
      );

      final json = report.toJson();
      expect(json['generatedAt'], '2026-05-01T00:00:00.000Z');
      expect(json['vipActive'], false);
      expect(json['eventCount'], 1);
      expect(json['events'], report.events);
      expect(json['consent'], isA<Map<String, dynamic>>());
      expect((json['consent'] as Map)['hasUserConsent'], false);
      expect(json['safety'], snapshot.toJson());
    });

    test('toJsonString produces parseable, non-empty JSON', () {
      final report = ComplianceReport.generate(
        events: const [],
        safety: snapshot,
        consent: ConsentSettings.unset,
        vipActive: false,
      );

      final compact = report.toJsonString();
      final pretty = report.toJsonString(pretty: true);
      expect(compact, isNotEmpty);
      expect(pretty.contains('\n'), isTrue);
    });
  });

  group('AdSafetySnapshot.toJson', () {
    test('serializes every field', () {
      final json = snapshot.toJson();
      expect(json['fullscreenAdsShownInSession'], 2);
      expect(json['maxFullscreenAdsPerHour'], 3);
      expect(json['dailyAdCount'], 4);
      expect(json['clickThroughRate'], 0.1);
      expect(json['dryRun'], false);
    });
  });
}
