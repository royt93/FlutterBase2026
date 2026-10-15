import 'dart:convert';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'T146: CohortOptimizer signs and verifies records on physical device',
    (tester) async {
      final prefs = await AdPreferences.getInstance();
      final optimizer = CohortOptimizer(prefs, minSessionsPerProvider: 2);

      await optimizer.recordSession(
        provider: AdProvider.admob,
        impressions: 10,
        revenueMicros: 10000,
      );
      await optimizer.recordSession(
        provider: AdProvider.admob,
        impressions: 10,
        revenueMicros: 10000,
      );
      await optimizer.recordSession(
        provider: AdProvider.appLovin,
        impressions: 10,
        revenueMicros: 50000,
      );
      await optimizer.recordSession(
        provider: AdProvider.appLovin,
        impressions: 10,
        revenueMicros: 50000,
      );

      final recommendation = await optimizer.recommendedProviderForNextInit();
      expect(recommendation, equals(AdProvider.appLovin));

      final records = await optimizer.loadVerifiedRecords();
      expect(records.length, greaterThanOrEqualTo(4));

      final now = DateTime.now();
      final fixture = await signJsonPayload(
        jsonEncode([
          {
            'provider': AdProvider.admob.name,
            'impressions': 1,
            'revenueMicros': 100,
            'timestampMs': now
                .subtract(const Duration(days: 91))
                .millisecondsSinceEpoch,
          },
          {
            'provider': AdProvider.appLovin.name,
            'impressions': 100,
            'revenueMicros': 100000,
            'timestampMs': now
                .add(const Duration(days: 1))
                .millisecondsSinceEpoch,
          },
          {
            'provider': AdProvider.admob.name,
            'impressions': 2,
            'revenueMicros': 200,
            'timestampMs': now
                .subtract(const Duration(days: 89))
                .millisecondsSinceEpoch,
          },
        ]),
      );
      await prefs.setCohortOptimizerRecordsRaw(fixture.toJsonString());
      await optimizer.recordSession(
        provider: AdProvider.admob,
        impressions: 3,
        revenueMicros: 300,
      );

      final retained = await optimizer.loadVerifiedRecords();
      expect(retained.map((record) => record.impressions), [2, 3]);
      expect(
        await verifySignedJsonPayload(prefs.getCohortOptimizerRecordsRaw()!),
        isTrue,
      );
    },
  );
}
