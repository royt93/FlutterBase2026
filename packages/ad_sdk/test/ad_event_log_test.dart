// Unit tests for AdEventLog (T23) — the persisted ring buffer backing
// AdManager.exportComplianceReport().

import 'package:applovin_admob_sdk/src/compliance/ad_event_log.dart';
import 'package:applovin_admob_sdk/src/state/ad_event.dart';
import 'package:applovin_admob_sdk/src/state/ad_placement.dart';
import 'package:applovin_admob_sdk/src/state/ad_slot.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AdPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await AdPreferences.getInstance();
    await prefs.clearAllData();
  });

  AdLoadEvent loadEvent({bool success = true}) => AdLoadEvent(
        providerTag: '[AdMob]',
        type: AdSlotType.interstitial,
        placement: AdPlacement.home,
        success: success,
        errorCode: success ? null : 3,
      );

  group('recordEvent', () {
    test('empty log starts empty', () {
      final log = AdEventLog(prefs);
      expect(log.entries, isEmpty);
    });

    test('records an AdEvent with the expected shape', () {
      final log = AdEventLog(prefs);
      log.recordEvent(loadEvent(), timestampMs: 1000);

      expect(log.entries, hasLength(1));
      final entry = log.entries.single;
      expect(entry['kind'], 'ad_event');
      expect(entry['timestampMs'], 1000);
      expect(entry['eventType'], 'AdLoadEvent');
      expect(entry['providerTag'], '[AdMob]');
      expect(entry['slotType'], 'interstitial');
      expect(entry['placement'], 'home');
      expect(entry['success'], true);
      expect(entry['errorCode'], isNull);
    });

    test('records every AdEvent subtype without throwing', () {
      final log = AdEventLog(prefs);
      log.recordEvent(loadEvent());
      log.recordEvent(AdShowEvent(
        providerTag: '[AppLovin]',
        type: AdSlotType.rewarded,
        placement: AdPlacement.shop,
        success: false,
      ));
      log.recordEvent(AdClickEvent(
        providerTag: '[AdMob]',
        type: AdSlotType.banner,
        placement: AdPlacement.unspecified,
      ));
      log.recordEvent(AdRewardEvent(
        providerTag: '[AdMob]',
        placement: AdPlacement.custom('daily_bonus'),
        label: 'coins',
        amount: 100,
      ));
      log.recordEvent(AdRevenueEvent(
        providerTag: '[AppLovin]',
        type: AdSlotType.appOpen,
        placement: AdPlacement.splash,
        valueMicros: 12000,
        currencyCode: 'USD',
        networkName: 'applovin_max',
        precision: 'estimated',
      ));

      expect(log.entries, hasLength(5));
      expect(log.entries.map((e) => e['kind']), everyElement('ad_event'));
    });

    test('recordSafetyBlock captures the block reason', () {
      final log = AdEventLog(prefs);
      log.recordSafetyBlock('Hourly cap: 3 ads', timestampMs: 2000);

      expect(log.entries, hasLength(1));
      final entry = log.entries.single;
      expect(entry['kind'], 'safety_block');
      expect(entry['timestampMs'], 2000);
      expect(entry['reason'], 'Hourly cap: 3 ads');
    });
  });

  group('ring buffer cap', () {
    test('drops the oldest entries once maxEntries is exceeded', () {
      final log = AdEventLog(prefs, maxEntries: 3);
      for (var i = 0; i < 5; i++) {
        log.recordEvent(loadEvent(), timestampMs: i);
      }

      expect(log.entries, hasLength(3));
      expect(log.entries.map((e) => e['timestampMs']), [2, 3, 4]);
    });

    test('never exceeds cap across many inserts', () {
      final log = AdEventLog(prefs, maxEntries: 10);
      for (var i = 0; i < 500; i++) {
        log.recordEvent(loadEvent(), timestampMs: i);
      }
      expect(log.entries.length, 10);
      expect(log.entries.last['timestampMs'], 499);
    });
  });

  group('inRange', () {
    test('returns everything when both bounds are null', () {
      final log = AdEventLog(prefs);
      log.recordEvent(loadEvent(), timestampMs: 1);
      log.recordEvent(loadEvent(), timestampMs: 2);
      expect(log.inRange(), hasLength(2));
    });

    test('filters inclusively by from/to', () {
      final log = AdEventLog(prefs);
      for (final ts in [100, 200, 300, 400]) {
        log.recordEvent(loadEvent(), timestampMs: ts);
      }
      final filtered = log.inRange(
        from: DateTime.fromMillisecondsSinceEpoch(200),
        to: DateTime.fromMillisecondsSinceEpoch(300),
      );
      expect(filtered.map((e) => e['timestampMs']), [200, 300]);
    });

    test('open-ended from filters only the lower bound', () {
      final log = AdEventLog(prefs);
      for (final ts in [100, 200, 300]) {
        log.recordEvent(loadEvent(), timestampMs: ts);
      }
      final filtered =
          log.inRange(from: DateTime.fromMillisecondsSinceEpoch(200));
      expect(filtered.map((e) => e['timestampMs']), [200, 300]);
    });
  });

  group('persistence', () {
    test('reloads previously persisted entries from AdPreferences', () async {
      final first = AdEventLog(prefs);
      first.recordEvent(loadEvent(), timestampMs: 42);
      // recordEvent persists fire-and-forget; give the microtask a turn.
      await Future<void>.delayed(Duration.zero);

      final second = AdEventLog(prefs);
      expect(second.entries, hasLength(1));
      expect(second.entries.single['timestampMs'], 42);
    });

    test('corrupt persisted JSON is discarded, not thrown', () async {
      await prefs.setComplianceLogRaw('{not valid json');
      final log = AdEventLog(prefs);
      expect(log.entries, isEmpty);
    });
  });

  group('clear', () {
    test('empties the in-memory log and the persisted copy', () async {
      final log = AdEventLog(prefs);
      log.recordEvent(loadEvent());
      await Future<void>.delayed(Duration.zero);
      await log.clear();

      expect(log.entries, isEmpty);
      final reloaded = AdEventLog(prefs);
      expect(reloaded.entries, isEmpty);
    });
  });
}
