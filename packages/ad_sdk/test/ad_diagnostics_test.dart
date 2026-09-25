// Tests for AdManager.diagnostics() and its pure waterfall-indexing helper
// AdDiagnostics.lastWaterfallBySlotFrom (T41 brainstorm — one-shot
// mediation-waterfall + fill-rate + arbitrator snapshot).

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

AdRevenueEvent _rev(int micros, {List<String>? waterfall}) => AdRevenueEvent(
      providerTag: '[AdMob]',
      type: AdSlotType.interstitial,
      placement: AdPlacement.unspecified,
      valueMicros: micros,
      currencyCode: 'USD',
      mediationWaterfall: waterfall,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AdDiagnostics.lastWaterfallBySlotFrom (pure)', () {
    test('empty entries → empty map', () {
      expect(AdDiagnostics.lastWaterfallBySlotFrom(const []), isEmpty);
    });

    test('ignores non-AdRevenueEvent entries and entries without a waterfall',
        () {
      final result = AdDiagnostics.lastWaterfallBySlotFrom([
        {'eventType': 'AdLoadEvent', 'slotType': 'interstitial'},
        {'eventType': 'AdRevenueEvent', 'slotType': 'interstitial'},
      ]);
      expect(result, isEmpty);
    });

    test('keeps only the most recent waterfall per slot (oldest-first input)',
        () {
      final result = AdDiagnostics.lastWaterfallBySlotFrom([
        {
          'eventType': 'AdRevenueEvent',
          'slotType': 'interstitial',
          'mediationWaterfall': ['com.old.adapter'],
        },
        {
          'eventType': 'AdRevenueEvent',
          'slotType': 'rewarded',
          'mediationWaterfall': ['com.rewarded.adapter'],
        },
        {
          'eventType': 'AdRevenueEvent',
          'slotType': 'interstitial',
          'mediationWaterfall': ['com.new.adapter', 'com.other.adapter'],
        },
      ]);

      expect(result[AdSlotType.interstitial],
          ['com.new.adapter', 'com.other.adapter']);
      expect(result[AdSlotType.rewarded], ['com.rewarded.adapter']);
    });

    // T151 — a persisted compliance-log entry can outlive an SDK version
    // (an old slotType name), be corrupted, or have a field manually edited.
    // This is the sole reader of that log that used AdSlotType.values.byName
    // directly instead of a safe tryParse-style lookup — every other reader
    // in the package (ad_event_log.dart's own _load(), WaterfallTuner's
    // _Key.tryParse) skips a malformed entry instead of throwing, precisely
    // because this data is untrusted persisted state, not an in-memory
    // invariant.
    test(
        'a garbage/unknown slotType entry is skipped, not thrown — valid '
        'entries around it still process', () {
      final result = AdDiagnostics.lastWaterfallBySlotFrom([
        {
          'eventType': 'AdRevenueEvent',
          'slotType': 'interstitial',
          'mediationWaterfall': ['com.before.adapter'],
        },
        {
          'eventType': 'AdRevenueEvent',
          'slotType': 'not_a_real_slot_type',
          'mediationWaterfall': ['com.garbage.adapter'],
        },
        {
          'eventType': 'AdRevenueEvent',
          'slotType': 'rewarded',
          'mediationWaterfall': ['com.after.adapter'],
        },
      ]);

      expect(result[AdSlotType.interstitial], ['com.before.adapter']);
      expect(result[AdSlotType.rewarded], ['com.after.adapter']);
      expect(result.length, 2,
          reason: 'the garbage slotType must not appear under any key');
    });

    test('a null/missing slotType entry is skipped, not thrown', () {
      final result = AdDiagnostics.lastWaterfallBySlotFrom([
        {
          'eventType': 'AdRevenueEvent',
          'slotType': null,
          'mediationWaterfall': ['com.orphan.adapter'],
        },
        {
          'eventType': 'AdRevenueEvent',
          // slotType key entirely absent, not just null.
          'mediationWaterfall': ['com.also.orphan'],
        },
      ]);

      expect(result, isEmpty);
    });
  });

  group('AdManager().diagnostics()', () {
    tearDown(() {
      AdManager().disableArbitrator();
      AdManager().disableFillRateMonitor();
      AdManager().disableFillRateBaselineMonitor();
      AdManager().disableRevenueIntegrityLedger();
      AdManager().incidentRecorder.clear();
    });

    test('nothing enabled → empty fillRate map, null arbitrator fields', () {
      final d = AdManager().diagnostics();
      expect(d.fillRateBySlot, isEmpty);
      expect(d.arbitratorEstimatedEcpmMicros, isNull);
      expect(d.arbitratorVetoRate, isNull);
    });

    // T187
    test('revenueIntegrityLedger never enabled → pendingRevenueChecks is '
        'null', () {
      final d = AdManager().diagnostics();
      expect(d.pendingRevenueChecks, isNull);
    });

    test('revenueIntegrityLedger enabled → pendingRevenueChecks reflects '
        'its live pendingCount', () async {
      AdManager().enableRevenueIntegrityLedger(RevenueIntegrityLedger());
      AdManager().debugEmit(const AdShowEvent(
        providerTag: '[AdMob]',
        type: AdSlotType.interstitial,
        placement: AdPlacement.unspecified,
        success: true,
      ));
      await Future<void>.delayed(Duration.zero);

      expect(AdManager().diagnostics().pendingRevenueChecks, 1);

      AdManager().debugEmit(_rev(2000));
      await Future<void>.delayed(Duration.zero);

      expect(AdManager().diagnostics().pendingRevenueChecks, 0,
          reason: 'the matching revenue event must have cleared it');
    });

    test('recentRevenueIntegrityIncidents counts only '
        'revenue_integrity_missing: entries, ignoring unrelated ones', () {
      AdManager().incidentRecorder.record(
          'revenue_integrity_missing:[AdMob]:interstitial:unspecified',
          AdManager().stateSnapshot.value);
      AdManager().incidentRecorder.record(
          'revenue_integrity_missing:[AppLovin]:rewarded:unspecified',
          AdManager().stateSnapshot.value);
      AdManager()
          .incidentRecorder
          .record('some_unrelated_incident', AdManager().stateSnapshot.value);

      expect(AdManager().diagnostics().recentRevenueIntegrityIncidents, 2);
    });

    test('recentRevenueIntegrityIncidents defaults to 0, not null, when '
        'nothing was ever recorded', () {
      expect(AdManager().diagnostics().recentRevenueIntegrityIncidents, 0);
    });

    test('fillRateMonitor enabled → every slot type present, defaults to 1.0',
        () {
      AdManager().enableFillRateMonitor(FillRateMonitor());
      final d = AdManager().diagnostics();
      expect(d.fillRateBySlot.keys.toSet(), AdSlotType.values.toSet());
      expect(d.fillRateBySlot[AdSlotType.interstitial], 1.0,
          reason: 'no load attempts observed yet for this slot');
    });

    test('fillRateMonitor reflects fed AdLoadEvents', () async {
      AdManager().enableFillRateMonitor(FillRateMonitor());
      AdManager().debugEmit(const AdLoadEvent(
        providerTag: '[AdMob]',
        type: AdSlotType.rewarded,
        placement: AdPlacement.unspecified,
        success: false,
      ));
      await Future<void>.delayed(Duration.zero);

      final d = AdManager().diagnostics();
      expect(d.fillRateBySlot[AdSlotType.rewarded], 0.0);
    });

    test('arbitrator enabled → estimatedEcpm/vetoRate populated', () async {
      AdManager().enableArbitrator(MonetizationArbitrator());
      // T58: valueMicros is per-impression revenue; eCPM is per-1000, so a
      // realistic 2_000 micros/impression reports as a $2.00 eCPM.
      AdManager().debugEmit(_rev(2000));
      await Future<void>.delayed(Duration.zero);

      final d = AdManager().diagnostics();
      expect(d.arbitratorEstimatedEcpmMicros, 2000000);
      expect(d.arbitratorVetoRate, isNotNull);
    });

    // B: coverage — AdDiagnostics.toJson (lines 67-84) and
    // toSafeJsonString edge cases (lines 115-155).
    test('toJson contains all expected keys', () async {
      final d = AdManager().diagnostics();
      final j = d.toJson();
      expect(j.containsKey('lastWaterfallBySlot'), isTrue);
      expect(j.containsKey('fillRateBySlot'), isTrue);
      expect(j.containsKey('arbitratorEstimatedEcpmMicros'), isTrue);
      expect(j.containsKey('arbitratorVetoRate'), isTrue);
      expect(j.containsKey('fillRateRegressionBySlot'), isTrue);
      expect(j.containsKey('pendingRevenueChecks'), isTrue);
      expect(j.containsKey('recentRevenueIntegrityIncidents'), isTrue);
    });

    test('toJson fillRateRegressionBySlot contains all regression fields',
        () async {
      SharedPreferences.setMockInitialValues({});
      await AdManager().enableFillRateBaselineMonitor();
      final d = AdManager().diagnostics();
      final j = d.toJson();
      // Even with no data the map is present (may be empty).
      expect(j['fillRateRegressionBySlot'], isA<Map>());
    });

    test('toSafeJsonString throws ArgumentError for maxBytes < 256', () async {
      final d = AdManager().diagnostics();
      await expectLater(
        () => d.toSafeJsonString(maxBytes: 100),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('toSafeJsonString produces verifiable envelope', () async {
      final d = AdManager().diagnostics();
      final encoded = await d.toSafeJsonString();
      expect(await AdDiagnostics.verifySafeJsonString(encoded), isTrue);
    });

    test('toSafeJsonString truncates when waterfall exceeds maxBytes',
        () async {
      // Build a DiagnosticsSnapshot with a large waterfall to trigger
      // the while-loop truncation path.
      final bigWaterfall = List.generate(100, (i) => 'network_$i' * 20);
      AdManager().debugEmit(_rev(1000, waterfall: bigWaterfall));
      await Future<void>.delayed(Duration.zero);

      final d = AdManager().diagnostics();
      // Use a tiny maxBytes to force truncation.
      final encoded = await d.toSafeJsonString(maxBytes: 1024);
      expect(await AdDiagnostics.verifySafeJsonString(encoded), isTrue);
      expect(encoded.length, lessThanOrEqualTo(1024));
    });
  });
}
