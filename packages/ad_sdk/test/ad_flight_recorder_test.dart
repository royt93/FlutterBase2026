// T231 — Flight Recorder: hash-chained ad-display evidence log. Tests the
// pure logic (chain construction/tamper detection, signing round-trip,
// bounded-size drop-oldest, capacity validation) without touching
// AdManager/widgets — those are covered in ad_manager_flight_recorder_test.dart
// and banner_ad_widget_test.dart respectively.
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AdFlightRecorder chain construction', () {
    test('first entry has empty previousHash', () async {
      final recorder = AdFlightRecorder();
      await recorder.record(
        label: 'bannerVisible',
        slotType: 'banner',
        placement: 'home',
        providerTag: '[AdMob]',
      );

      expect(recorder.entries.single.previousHash, '');
    });

    test('each entry links to the previous entry\'s hash', () async {
      final recorder = AdFlightRecorder();
      await recorder.record(
          label: 'a', slotType: 'banner', placement: 'home', providerTag: '[AdMob]');
      await recorder.record(
          label: 'b', slotType: 'banner', placement: 'home', providerTag: '[AdMob]');

      expect(recorder.entries[1].previousHash, recorder.entries[0].hash);
      expect(recorder.entries[0].hash, isNotEmpty);
      expect(recorder.entries[1].hash, isNot(recorder.entries[0].hash));
    });

    test('clear() resets the chain anchor to empty', () async {
      final recorder = AdFlightRecorder();
      await recorder.record(
          label: 'a', slotType: 'banner', placement: 'home', providerTag: '[AdMob]');
      recorder.clear();
      await recorder.record(
          label: 'b', slotType: 'banner', placement: 'home', providerTag: '[AdMob]');

      expect(recorder.entries.single.previousHash, '');
    });
  });

  group('verifyFlightRecorderChain — tamper detection', () {
    test('an untouched chain verifies true', () async {
      final recorder = AdFlightRecorder();
      await recorder.record(
          label: 'bannerVisible',
          slotType: 'banner',
          placement: 'home',
          providerTag: '[AdMob]',
          viewabilityFraction: 1,
          screenX: 10,
          screenY: 20);
      await recorder.record(
          label: 'clicked',
          slotType: 'banner',
          placement: 'home',
          providerTag: '[AdMob]',
          touchActive: true);

      expect(await verifyFlightRecorderChain(recorder.entries), isTrue);
    });

    test('an empty chain verifies true (nothing to disprove)', () async {
      expect(await verifyFlightRecorderChain(const []), isTrue);
    });

    test('mutating one field of one entry breaks verification', () async {
      final recorder = AdFlightRecorder();
      await recorder.record(
          label: 'bannerVisible',
          slotType: 'banner',
          placement: 'home',
          providerTag: '[AdMob]',
          viewabilityFraction: 1);
      await recorder.record(
          label: 'clicked',
          slotType: 'banner',
          placement: 'home',
          providerTag: '[AdMob]');

      final tampered = List<FlightRecorderEntry>.from(recorder.entries);
      final original = tampered[0];
      tampered[0] = FlightRecorderEntry(
        timestampMs: original.timestampMs,
        label: original.label,
        slotType: original.slotType,
        placement: original.placement,
        providerTag: original.providerTag,
        // Tamper: claim full viewability instead of the recorded value —
        // exactly the kind of forged evidence the chain must catch.
        viewabilityFraction: 0,
        screenX: original.screenX,
        screenY: original.screenY,
        widthPx: original.widthPx,
        heightPx: original.heightPx,
        tcfConsentString: original.tcfConsentString,
        touchActive: original.touchActive,
        interactionDurationMs: original.interactionDurationMs,
        previousHash: original.previousHash,
        hash: original.hash, // hash NOT recomputed — mismatches payload now
      );

      expect(await verifyFlightRecorderChain(tampered), isFalse);
    });

    test('reordering two entries breaks the previousHash linkage', () async {
      final recorder = AdFlightRecorder();
      await recorder.record(
          label: 'a', slotType: 'banner', placement: 'home', providerTag: '[AdMob]');
      await recorder.record(
          label: 'b', slotType: 'banner', placement: 'home', providerTag: '[AdMob]');

      final reordered = recorder.entries.reversed.toList();

      expect(await verifyFlightRecorderChain(reordered), isFalse);
    });

    test('dropping a middle entry breaks the chain at that point', () async {
      final recorder = AdFlightRecorder();
      await recorder.record(
          label: 'a', slotType: 'banner', placement: 'home', providerTag: '[AdMob]');
      await recorder.record(
          label: 'b', slotType: 'banner', placement: 'home', providerTag: '[AdMob]');
      await recorder.record(
          label: 'c', slotType: 'banner', placement: 'home', providerTag: '[AdMob]');

      final withMiddleDropped = [recorder.entries[0], recorder.entries[2]];

      expect(await verifyFlightRecorderChain(withMiddleDropped), isFalse);
    });

    test('appending a fabricated entry with a forged previousHash fails',
        () async {
      final recorder = AdFlightRecorder();
      await recorder.record(
          label: 'a', slotType: 'banner', placement: 'home', providerTag: '[AdMob]');

      final forged = FlightRecorderEntry(
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        label: 'fabricated',
        slotType: 'banner',
        placement: 'home',
        providerTag: '[AdMob]',
        viewabilityFraction: 1,
        screenX: 0,
        screenY: 0,
        widthPx: 0,
        heightPx: 0,
        tcfConsentString: null,
        touchActive: false,
        interactionDurationMs: 0,
        previousHash: recorder.entries.single.hash,
        hash: 'not-a-real-sha256-of-anything',
      );

      final withForgery = [...recorder.entries, forged];

      expect(await verifyFlightRecorderChain(withForgery), isFalse);
    });
  });

  group('bounded size / drop-oldest', () {
    test('capacity caps the buffer, dropping oldest first', () async {
      final recorder = AdFlightRecorder(capacity: 3);
      for (var i = 0; i < 5; i++) {
        await recorder.record(
            label: 'e$i',
            slotType: 'banner',
            placement: 'home',
            providerTag: '[AdMob]');
      }

      expect(recorder.entries, hasLength(3));
      expect(recorder.entries.map((e) => e.label), ['e2', 'e3', 'e4']);
    });

    test('a trimmed (but still contiguous) window still verifies', () async {
      final recorder = AdFlightRecorder(capacity: 2);
      for (var i = 0; i < 4; i++) {
        await recorder.record(
            label: 'e$i',
            slotType: 'banner',
            placement: 'home',
            providerTag: '[AdMob]');
      }

      expect(await verifyFlightRecorderChain(recorder.entries), isTrue);
    });

    test('capacity <= 0 falls back to default instead of crashing', () async {
      final recorder = AdFlightRecorder(capacity: 0);
      await recorder.record(
          label: 'a', slotType: 'banner', placement: 'home', providerTag: '[AdMob]');

      expect(recorder.capacity, 2000);
      expect(recorder.entries, hasLength(1));
    });
  });

  group('signing round-trip', () {
    test('a signed bundle verifies and its chain verifies too', () async {
      final recorder = AdFlightRecorder();
      await recorder.record(
          label: 'bannerVisible',
          slotType: 'banner',
          placement: 'home',
          providerTag: '[AdMob]',
          tcfConsentString: 'CPabc.YA');
      final bundle = FlightRecorderBundle(
        entries: recorder.entries,
        generatedAtMs: DateTime(2026, 1, 1).millisecondsSinceEpoch,
      );

      final signed = await signFlightRecorderBundle(bundle);
      final envelopeJson = signed.toJsonString();

      expect(await verifySignedJsonPayload(envelopeJson), isTrue);
      expect(await verifySignedFlightRecorderBundle(envelopeJson), isTrue);
    });

    test('a bit-flipped payload fails full verification', () async {
      final recorder = AdFlightRecorder();
      await recorder.record(
          label: 'bannerVisible',
          slotType: 'banner',
          placement: 'home',
          providerTag: '[AdMob]');
      final bundle = FlightRecorderBundle(
          entries: recorder.entries, generatedAtMs: 0);
      final signed = await signFlightRecorderBundle(bundle);

      final tampered = SignedPayload(
        payloadJson:
            signed.payloadJson.replaceFirst('"bannerVisible"', '"tampered"'),
        publicKeyBase64: signed.publicKeyBase64,
        signatureBase64: signed.signatureBase64,
      );

      expect(await verifySignedFlightRecorderBundle(tampered.toJsonString()),
          isFalse);
    });

    test(
        'a validly-signed bundle whose payload was swapped for a '
        'tampered-chain payload still fails (signature alone is not enough)',
        () async {
      // This is the scenario the combined check exists for: someone who
      // controls the signing key (see class doc's threat model) re-signs a
      // forged copy. The signature on its own verifies fine — only the
      // hash-chain half of the check catches the forged entry.
      final recorder = AdFlightRecorder();
      await recorder.record(
          label: 'bannerVisible',
          slotType: 'banner',
          placement: 'home',
          providerTag: '[AdMob]',
          viewabilityFraction: 1);
      await recorder.record(
          label: 'clicked',
          slotType: 'banner',
          placement: 'home',
          providerTag: '[AdMob]');

      final original = recorder.entries[0];
      final forgedFirst = FlightRecorderEntry(
        timestampMs: original.timestampMs,
        label: original.label,
        slotType: original.slotType,
        placement: original.placement,
        providerTag: original.providerTag,
        viewabilityFraction: 0, // forged: claim never actually viewable
        screenX: original.screenX,
        screenY: original.screenY,
        widthPx: original.widthPx,
        heightPx: original.heightPx,
        tcfConsentString: original.tcfConsentString,
        touchActive: original.touchActive,
        interactionDurationMs: original.interactionDurationMs,
        previousHash: original.previousHash,
        hash: original.hash,
      );
      final forgedBundle = FlightRecorderBundle(
        entries: [forgedFirst, recorder.entries[1]],
        generatedAtMs: 0,
      );
      // Re-signed with the SAME on-device key — simulating "device owner
      // forges + re-signs", not "signature was never valid".
      final resigned = await signFlightRecorderBundle(forgedBundle);

      expect(await verifySignedJsonPayload(resigned.toJsonString()), isTrue,
          reason: 'the signature itself is legitimately valid');
      expect(
          await verifySignedFlightRecorderBundle(resigned.toJsonString()),
          isFalse,
          reason: 'but the hash chain inside it does not verify');
    });

    test('malformed bundle JSON fails closed, never throws', () async {
      expect(await verifySignedFlightRecorderBundle('not json'), isFalse);
      expect(await verifySignedFlightRecorderBundle('{}'), isFalse);
    });
  });

  group('FlightRecorderBundle JSON round-trip', () {
    test('fromJsonString(toJsonString()) reproduces entries exactly',
        () async {
      final recorder = AdFlightRecorder();
      await recorder.record(
          label: 'bannerVisible',
          slotType: 'banner',
          placement: 'home',
          providerTag: '[AdMob]',
          viewabilityFraction: 0.75,
          screenX: 12.5,
          screenY: 480,
          widthPx: 320,
          heightPx: 50,
          tcfConsentString: 'CPabc.YA',
          touchActive: false);
      final bundle = FlightRecorderBundle(
          entries: recorder.entries, generatedAtMs: 1234);

      final roundTripped =
          FlightRecorderBundle.fromJsonString(bundle.toJsonString());

      expect(roundTripped.generatedAtMs, 1234);
      expect(roundTripped.entries.single.toJson(),
          bundle.entries.single.toJson());
    });

    test('a null tcfConsentString round-trips as null (non-EEA user)',
        () async {
      final recorder = AdFlightRecorder();
      await recorder.record(
          label: 'bannerVisible',
          slotType: 'banner',
          placement: 'home',
          providerTag: '[AdMob]');
      final bundle =
          FlightRecorderBundle(entries: recorder.entries, generatedAtMs: 0);

      final roundTripped =
          FlightRecorderBundle.fromJsonString(bundle.toJsonString());

      expect(roundTripped.entries.single.tcfConsentString, isNull);
    });
  });

  group('interaction duration', () {
    test('click records milliseconds since the matching visible transition',
        () async {
      final recorder = AdFlightRecorder();
      await recorder.record(
        label: 'bannerVisible',
        slotType: 'banner',
        placement: 'home',
        providerTag: '[AdMob]',
        timestampMs: 1000,
      );
      await recorder.record(
        label: 'clicked',
        slotType: 'banner',
        placement: 'home',
        providerTag: '[AdMob]',
        touchActive: true,
        timestampMs: 1750,
      );

      expect(recorder.entries.last.interactionDurationMs, 750);
      expect(await verifyFlightRecorderChain(recorder.entries), isTrue,
          reason: 'interaction duration is itself committed into the hash');
    });

    test('touch without a prior matching visible entry records 0, not a '
        'fabricated duration', () async {
      final recorder = AdFlightRecorder();
      await recorder.record(
        label: 'clicked',
        slotType: 'interstitial',
        placement: 'home',
        providerTag: '[AdMob]',
        touchActive: true,
        timestampMs: 5000,
      );

      expect(recorder.entries.single.interactionDurationMs, 0);
    });

    test('a visible entry from another placement is not reused', () async {
      final recorder = AdFlightRecorder();
      await recorder.record(
        label: 'bannerVisible',
        slotType: 'banner',
        placement: 'shop',
        providerTag: '[AdMob]',
        timestampMs: 1000,
      );
      await recorder.record(
        label: 'clicked',
        slotType: 'banner',
        placement: 'home',
        providerTag: '[AdMob]',
        touchActive: true,
        timestampMs: 2000,
      );

      expect(recorder.entries.last.interactionDurationMs, 0);
    });
  });

  group('persistence', () {
    late AdPreferences prefs;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await AdPreferences.getInstance();
      await prefs.clearAllData();
    });

    test('a fresh recorder reloads prior hash-chain history after flush',
        () async {
      final first = AdFlightRecorder();
      first.attach(prefs);
      await first.record(
          label: 'bannerVisible',
          slotType: 'banner',
          placement: 'home',
          providerTag: '[AdMob]');
      await first.flush();

      final second = AdFlightRecorder();
      second.attach(prefs);

      expect(second.entries, hasLength(1));
      expect(second.entries.single.label, 'bannerVisible');
      expect(await verifyFlightRecorderChain(second.entries), isTrue);
    });

    test('recording after reload continues from the persisted last hash',
        () async {
      final first = AdFlightRecorder();
      first.attach(prefs);
      await first.record(
          label: 'bannerVisible',
          slotType: 'banner',
          placement: 'home',
          providerTag: '[AdMob]');
      await first.flush();

      final second = AdFlightRecorder();
      second.attach(prefs);
      final priorHash = second.entries.single.hash;
      await second.record(
          label: 'clicked',
          slotType: 'banner',
          placement: 'home',
          providerTag: '[AdMob]',
          touchActive: true);

      expect(second.entries.last.previousHash, priorHash);
      expect(await verifyFlightRecorderChain(second.entries), isTrue);
    });

    test('corrupt persisted JSON is discarded, not thrown', () async {
      await prefs.setFlightRecorderRaw('{not valid json');
      final recorder = AdFlightRecorder();

      recorder.attach(prefs);

      expect(recorder.entries, isEmpty);
    });

    test('not attached — record stays in memory only and never throws',
        () async {
      final recorder = AdFlightRecorder();
      await recorder.record(
          label: 'bannerVisible',
          slotType: 'banner',
          placement: 'home',
          providerTag: '[AdMob]');

      expect(recorder.entries, hasLength(1));
    });
  });
}
