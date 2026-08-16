// Unit tests for AdEventLog (T23) — the persisted ring buffer backing
// AdManager.exportComplianceReport().

import 'dart:convert';

import 'package:applovin_admob_sdk/src/compliance/ad_event_log.dart';
import 'package:applovin_admob_sdk/src/state/ad_event.dart';
import 'package:applovin_admob_sdk/src/state/ad_placement.dart';
import 'package:applovin_admob_sdk/src/state/ad_slot.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:fake_async/fake_async.dart';
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

    test('AdRevenueEvent.mediationWaterfall is captured when present', () {
      final log = AdEventLog(prefs);
      log.recordEvent(AdRevenueEvent(
        providerTag: '[AdMob]',
        type: AdSlotType.interstitial,
        placement: AdPlacement.unspecified,
        valueMicros: 5000,
        currencyCode: 'USD',
        precision: 'precise',
        mediationWaterfall: const [
          'com.google.ads.mediation.facebook.FacebookMediationAdapter',
          'com.google.ads.mediation.admob.AdMobAdapter',
        ],
      ));

      final entry = log.entries.single;
      expect(entry['mediationWaterfall'], [
        'com.google.ads.mediation.facebook.FacebookMediationAdapter',
        'com.google.ads.mediation.admob.AdMobAdapter',
      ]);
    });

    test('AdRevenueEvent.mediationWaterfall defaults to null', () {
      final log = AdEventLog(prefs);
      log.recordEvent(AdRevenueEvent(
        providerTag: '[AppLovin]',
        type: AdSlotType.rewarded,
        placement: AdPlacement.unspecified,
        valueMicros: 5000,
        currencyCode: 'USD',
      ));

      expect(log.entries.single['mediationWaterfall'], isNull);
    });

    test('recordEvent captures consentCountry when supplied', () {
      final log = AdEventLog(prefs);
      log.recordEvent(loadEvent(), consentCountry: 'DE');

      expect(log.entries.single['consentCountry'], 'DE');
    });

    test('recordEvent leaves consentCountry null when not supplied', () {
      final log = AdEventLog(prefs);
      log.recordEvent(loadEvent());

      expect(log.entries.single['consentCountry'], isNull);
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

    // T79 — the open-ended upper bound used to be `1 << 62`, unsafe if this
    // package ever compiles to Web/Wasm (JS numbers only represent integers
    // exactly up to 2^53-1). Confirms the replacement constant still
    // behaves as "no upper bound" for any realistic timestamp.
    test(
        'open-ended to still includes a realistic present-day timestamp '
        '(2^53-1 safe-integer sentinel, not the old 1 << 62)', () {
      final log = AdEventLog(prefs);
      // A real, present-day epoch-ms value — comfortably below 2^53-1
      // (~9.007e15) but was ALSO comfortably below the old `1 << 62`
      // (~4.6e18). What matters is that the new, smaller-but-still-huge
      // sentinel doesn't accidentally exclude anything realistic.
      final now = DateTime.now().millisecondsSinceEpoch;
      log.recordEvent(loadEvent(), timestampMs: now);

      final filtered =
          log.inRange(from: DateTime.fromMillisecondsSinceEpoch(0));
      expect(filtered.map((e) => e['timestampMs']), [now]);
    });
  });

  group('persistence', () {
    test('reloads previously persisted entries from AdPreferences', () async {
      final first = AdEventLog(prefs);
      first.recordEvent(loadEvent(), timestampMs: 42);
      // T70 — recordEvent debounces the actual disk write now; flush()
      // forces it immediately instead of waiting out the debounce window.
      await first.flush();

      final second = AdEventLog(prefs);
      expect(second.entries, hasLength(1));
      expect(second.entries.single['timestampMs'], 42);
    });

    test('corrupt persisted JSON is discarded, not thrown', () async {
      await prefs.setComplianceLogRaw('{not valid json');
      final log = AdEventLog(prefs);
      expect(log.entries, isEmpty);
    });

    // Fix #7: a valid JSON list where one entry is missing `timestampMs`
    // (e.g. hand-edited storage, or a future schema change) must not throw
    // — neither at load, nor later when inRange/export read `timestampMs`.
    test('a valid entry survives alongside one missing timestampMs', () async {
      await prefs.setComplianceLogRaw(jsonEncode([
        {'kind': 'ad_event', 'timestampMs': 50, 'eventType': 'AdLoadEvent'},
        {'kind': 'ad_event', 'eventType': 'AdLoadEvent'}, // missing timestampMs
      ]));

      final log = AdEventLog(prefs);
      expect(log.entries, hasLength(1));
      expect(log.entries.single['timestampMs'], 50);
      expect(() => log.inRange(), returnsNormally);
    });

    // T23 re-audit fix: rapid-fire recordEvent calls used to each fire an
    // unawaited setString — concurrent writes could finish out of order and
    // leave a stale, truncated snapshot persisted. Persists are now chained.
    test('rapid successive recordEvent calls persist all entries in order',
        () async {
      final log = AdEventLog(prefs);
      for (var i = 0; i < 20; i++) {
        log.recordEvent(loadEvent(), timestampMs: i);
      }
      await log.flush();

      final reloaded = AdEventLog(prefs);
      expect(reloaded.entries, hasLength(20));
      expect(reloaded.entries.map((e) => e['timestampMs']),
          List.generate(20, (i) => i));
    });
  });

  group('clear', () {
    test('empties the in-memory log and the persisted copy', () async {
      final log = AdEventLog(prefs);
      log.recordEvent(loadEvent());
      await log.clear();

      expect(log.entries, isEmpty);
      final reloaded = AdEventLog(prefs);
      expect(reloaded.entries, isEmpty);
    });
  });

  // T70 — recordEvent used to jsonEncode + setString the whole (up to
  // 5,000-entry) log on every single ad event. High-frequency apps could
  // burn CPU/disk I/O on the main isolate. Writes now debounce and coalesce.
  group('debounced persist (T70)', () {
    test('rapid events within the debounce window do not hit disk yet',
        () {
      fakeAsync((async) {
        final log = AdEventLog(prefs);
        log.recordEvent(loadEvent(), timestampMs: 1);
        async.elapse(const Duration(milliseconds: 500));
        log.recordEvent(loadEvent(), timestampMs: 2);
        async.elapse(const Duration(milliseconds: 500));

        expect(prefs.getComplianceLogRaw(), isNull,
            reason: 'still inside the debounce window — nothing written '
                'to disk yet');
      });
    });

    test('coalesces rapid events into a single write after the window',
        () {
      fakeAsync((async) {
        final log = AdEventLog(prefs);
        for (var i = 0; i < 5; i++) {
          log.recordEvent(loadEvent(), timestampMs: i);
          async.elapse(const Duration(milliseconds: 100));
        }
        // Past the debounce window from the LAST event, with no new event
        // resetting it again.
        async.elapse(const Duration(seconds: 2));

        final persisted = jsonDecode(prefs.getComplianceLogRaw()!) as List;
        expect(persisted, hasLength(5),
            reason: 'one coalesced write must contain every queued event');
      });
    });

    test('flush() forces an immediate write without waiting for the window',
        () async {
      final log = AdEventLog(prefs);
      log.recordEvent(loadEvent(), timestampMs: 1);
      expect(prefs.getComplianceLogRaw(), isNull);

      await log.flush();

      expect(prefs.getComplianceLogRaw(), isNotNull);
    });

    test('flush() with nothing pending is a harmless no-op', () async {
      final log = AdEventLog(prefs);
      await expectLater(log.flush(), completes);
    });
  });
}
