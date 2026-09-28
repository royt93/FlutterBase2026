// T231 — AdManager-level opt-in wiring for the Flight Recorder: default OFF,
// zero overhead when disabled, DisputeKit extension, click-event hook.
import 'dart:convert';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    AdManager().disableFlightRecorder();
    AdManager().debugConfig = null;
  });

  group('opt-in / default off', () {
    test('flightRecorder is null until enableFlightRecorder is called', () {
      expect(AdManager().flightRecorder, isNull);
    });

    test('recordFlightRecorderEvent no-ops with zero entries when disabled',
        () async {
      await AdManager().recordFlightRecorderEvent(
        label: 'bannerVisible',
        type: AdSlotType.banner,
        placement: AdPlacement.home,
      );

      expect(AdManager().flightRecorder, isNull);
    });

    test('enableFlightRecorder wires a recorder that actually records',
        () async {
      AdManager().enableFlightRecorder(AdFlightRecorder());

      await AdManager().recordFlightRecorderEvent(
        label: 'bannerVisible',
        type: AdSlotType.banner,
        placement: AdPlacement.home,
        viewabilityFraction: 1,
      );

      expect(AdManager().flightRecorder!.entries, hasLength(1));
      expect(AdManager().flightRecorder!.entries.single.label, 'bannerVisible');
      expect(AdManager().flightRecorder!.entries.single.slotType, 'banner');
      expect(AdManager().flightRecorder!.entries.single.placement, 'home');
    });

    test('disableFlightRecorder drops the recorder back to null', () async {
      AdManager().enableFlightRecorder(AdFlightRecorder());
      AdManager().disableFlightRecorder();

      expect(AdManager().flightRecorder, isNull);
    });

    test('a global event (no type/placement) records slotType "global"',
        () async {
      AdManager().enableFlightRecorder(AdFlightRecorder());

      await AdManager().recordFlightRecorderEvent(label: 'consentChanged');

      final entry = AdManager().flightRecorder!.entries.single;
      expect(entry.slotType, 'global');
      expect(entry.placement, '-');
    });
  });

  group('exportSignedFlightRecorderBundle', () {
    test('returns null when the recorder was never enabled', () async {
      expect(await AdManager().exportSignedFlightRecorderBundle(), isNull);
    });

    test('signs an empty bundle when enabled but nothing was recorded yet',
        () async {
      AdManager().enableFlightRecorder(AdFlightRecorder());

      final signed = await AdManager().exportSignedFlightRecorderBundle();

      expect(signed, isNotNull);
      expect(await verifySignedJsonPayload(signed!.toJsonString()), isTrue);
      final bundle = FlightRecorderBundle.fromJsonString(signed.payloadJson);
      expect(bundle.entries, isEmpty);
    });

    test('signs and verifies a bundle with real entries', () async {
      AdManager().enableFlightRecorder(AdFlightRecorder());
      await AdManager().recordFlightRecorderEvent(
        label: 'bannerVisible',
        type: AdSlotType.banner,
        placement: AdPlacement.home,
      );

      final signed = await AdManager().exportSignedFlightRecorderBundle();

      expect(
          await verifySignedFlightRecorderBundle(signed!.toJsonString()),
          isTrue);
    });
  });

  group('DisputeKit.flightRecorderBundle', () {
    test('is null when the flight recorder was never enabled — existing '
        '3-key shape unchanged', () async {
      final kit = await AdManager().exportDisputeKit();

      expect(kit.flightRecorderBundle, isNull);
      final decoded = jsonDecode(kit.toJsonString()) as Map<String, dynamic>;
      expect(decoded.containsKey('flightRecorderBundle'), isFalse);
    });

    test('is populated and independently verifiable when enabled', () async {
      AdManager().enableFlightRecorder(AdFlightRecorder());
      await AdManager().recordFlightRecorderEvent(
        label: 'bannerVisible',
        type: AdSlotType.banner,
        placement: AdPlacement.home,
      );

      final kit = await AdManager().exportDisputeKit();

      expect(kit.flightRecorderBundle, isNotNull);
      expect(
          await verifySignedFlightRecorderBundle(
              jsonEncode(kit.flightRecorderBundle!.toJson())),
          isTrue);
      final decoded = jsonDecode(kit.toJsonString()) as Map<String, dynamic>;
      expect(decoded.containsKey('flightRecorderBundle'), isTrue);
    });
  });

  group('click events feed the flight recorder', () {
    test('an AdClickEvent on AdManager().events records a "clicked" entry '
        'when enabled', () async {
      AdManager().enableFlightRecorder(AdFlightRecorder());
      AdManager().debugEmit(const AdClickEvent(
        providerTag: '[AdMob]',
        type: AdSlotType.interstitial,
        placement: AdPlacement.home,
      ));
      // The click hook is fire-and-forget (unawaited) — give its Future a
      // microtask turn to complete before asserting.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final entries = AdManager().flightRecorder!.entries;
      expect(entries.any((e) => e.label == 'clicked' && e.touchActive), isTrue);
    });

    test('an AdClickEvent is a no-op for the flight recorder when disabled',
        () async {
      AdManager().debugEmit(const AdClickEvent(
        providerTag: '[AdMob]',
        type: AdSlotType.interstitial,
        placement: AdPlacement.home,
      ));
      await Future<void>.delayed(Duration.zero);

      expect(AdManager().flightRecorder, isNull);
    });
  });

  group('clearSdkData clears the live flight recorder', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await AdPreferences.getInstance();
      await prefs.clearAllData();
    });

    test('erases the live in-memory buffer, not just the persisted key',
        () async {
      AdManager().enableFlightRecorder(AdFlightRecorder());
      await AdManager().recordFlightRecorderEvent(
        label: 'bannerVisible',
        type: AdSlotType.banner,
        placement: AdPlacement.home,
      );
      expect(AdManager().flightRecorder!.entries, isNotEmpty);

      await AdManager().clearSdkData();

      expect(AdManager().flightRecorder!.entries, isEmpty,
          reason: 'a live instance must reflect the erasure immediately, '
              'same as ProviderFailoverAdvisor/consent-provenance-journal '
              'do for their own in-memory state');
    });

    test('is a no-op when the flight recorder was never enabled', () async {
      await AdManager().clearSdkData();
      expect(AdManager().flightRecorder, isNull);
    });
  });
}
