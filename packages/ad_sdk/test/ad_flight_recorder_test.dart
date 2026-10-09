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

    test('signed overflowing numeric input fails closed, never throws',
        () async {
      final recorder = AdFlightRecorder();
      await recorder.record(
          label: 'bannerVisible',
          slotType: 'banner',
          placement: 'home',
          providerTag: '[AdMob]');
      final bundle = FlightRecorderBundle(
          entries: recorder.entries, generatedAtMs: 0);
      final payload = bundle.toJsonString().replaceFirst('"screenX":0.0',
          '"screenX":1e400');
      expect(payload, isNot(bundle.toJsonString()));
      final signed = await signJsonPayload(payload);
      expect(await verifySignedJsonPayload(signed.toJsonString()), isTrue);
      expect(FlightRecorderBundle.fromJsonString(payload).entries.single.screenX,
          double.infinity);
      expect(await verifySignedFlightRecorderBundle(signed.toJsonString()),
          isFalse);
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

    group('pre-attach persistence (T234)', () {
      test(
          'record before attach persists after attach without another record '
          'or explicit flush', () async {
        final recorder = AdFlightRecorder();
        await recorder.record(
          label: 'preAttach',
          slotType: 'banner',
          placement: 'home',
          providerTag: '[SDK]',
        );

        recorder.attach(prefs);
        await Future<void>.delayed(const Duration(milliseconds: 1100));

        final raw = prefs.getFlightRecorderRaw();
        expect(raw, isNotNull,
            reason: 'attach() must schedule the write that record() could '
                'not schedule while preferences were unavailable');
        final persisted = FlightRecorderBundle.fromJsonString(raw!);
        expect(persisted.entries.map((e) => e.label), ['preAttach']);
      });

      test('attach with no pre-attach entries remains a storage no-op',
          () async {
        final recorder = AdFlightRecorder();

        recorder.attach(prefs);
        await Future<void>.delayed(const Duration(milliseconds: 1100));

        expect(prefs.getFlightRecorderRaw(), isNull);
      });

      test('stored history and pre-attach entry merge and both persist',
          () async {
        final stored = AdFlightRecorder()..attach(prefs);
        await stored.record(
          label: 'stored',
          slotType: 'banner',
          placement: 'home',
          providerTag: '[AdMob]',
          timestampMs: 1000,
        );
        await stored.flush();

        // This second recorder never saw the disk history above before
        // recording — its own hash chain starts fresh from `_lastHash ==
        // ''`, same as [stored]'s did. Unlike `BypassAuditTrail` (a plain
        // list, no chain), a chain built before `attach()` runs can never
        // be retroactively re-linked to history `attach()` loads afterward
        // — that would require re-hashing every pre-attach entry against
        // the loaded `_lastHash`, which is out of scope for T234's minimal
        // fix (mirrors T155's one-line `_schedulePersist()` call; nothing
        // more). T234's contract is narrower: no entry recorded before
        // attach() is silently lost. It says nothing about the two
        // sub-chains splicing into one continuously-verifiable chain.
        final recorder = AdFlightRecorder();
        await recorder.record(
          label: 'preAttach',
          slotType: 'mrec',
          placement: 'shop',
          providerTag: '[SDK]',
          timestampMs: 2000,
        );
        recorder.attach(prefs);
        await Future<void>.delayed(const Duration(milliseconds: 1100));

        final persisted = FlightRecorderBundle.fromJsonString(
            prefs.getFlightRecorderRaw()!);
        expect(persisted.entries.map((e) => e.label), ['stored', 'preAttach'],
            reason: 'T234: neither the disk history nor the pre-attach '
                'entry may be dropped by the merge');
        // Each entry's own hash is self-consistent in isolation (proving
        // neither was corrupted by the merge)...
        expect(
            await verifyFlightRecorderChain([persisted.entries.first]), isTrue);
        expect(
            await verifyFlightRecorderChain([persisted.entries.last]), isTrue);
        // ...but the two together do NOT form one continuous chain: the
        // preAttach entry's previousHash is "" (its own chain start), not
        // the stored entry's hash. This is the expected splice-boundary
        // break documented above, not a sign the fix is wrong.
        expect(persisted.entries.last.previousHash, isEmpty);
        expect(persisted.entries.last.previousHash,
            isNot(persisted.entries.first.hash));
        expect(await verifyFlightRecorderChain(persisted.entries), isFalse,
            reason: 'the full merged list does not chain continuously across '
                'the pre-attach/stored-history splice boundary — a known, '
                'documented limitation, not a regression T234 introduces');
      });

      test('record racing attach cannot drop or fork either entry', () async {
        final recorder = AdFlightRecorder();
        final first = recorder.record(
          label: 'first',
          slotType: 'banner',
          placement: 'home',
          providerTag: '[SDK]',
          timestampMs: 1000,
        );

        recorder.attach(prefs);
        final second = recorder.record(
          label: 'second',
          slotType: 'banner',
          placement: 'home',
          providerTag: '[SDK]',
          timestampMs: 2000,
        );
        await Future.wait([first, second]);
        await recorder.flush();

        final persisted = FlightRecorderBundle.fromJsonString(
            prefs.getFlightRecorderRaw()!);
        expect(persisted.entries.map((e) => e.label), ['first', 'second']);
        expect(await verifyFlightRecorderChain(persisted.entries), isTrue);
      });

      test('attach twice does not duplicate merged history', () async {
        final recorder = AdFlightRecorder();
        await recorder.record(
          label: 'preAttach',
          slotType: 'banner',
          placement: 'home',
          providerTag: '[SDK]',
        );

        recorder.attach(prefs);
        await recorder.flush();
        recorder.attach(prefs);

        expect(recorder.entries.map((e) => e.label), ['preAttach']);
        expect(await verifyFlightRecorderChain(recorder.entries), isTrue);
      });
    });
  });

  // T233 — real call sites (banner/MREC visibility, click) fire record()
  // via `unawaited(...)`, never awaiting one call before starting the
  // next. These mirror that fire-and-forget usage directly (no `await`
  // between the two `record()` calls) instead of a single-future
  // `Future.wait`, which would still run interleaved on the event loop
  // but is less obviously "call site shaped".
  group('concurrent unawaited record() calls (T233)', () {
    test('two unawaited calls fired back-to-back still form one linear '
        'chain', () async {
      final recorder = AdFlightRecorder();
      final f1 = recorder.record(
          label: 'bannerVisible',
          slotType: 'banner',
          placement: 'home',
          providerTag: '[AdMob]');
      final f2 = recorder.record(
          label: 'bannerHidden',
          slotType: 'banner',
          placement: 'home',
          providerTag: '[AdMob]');
      await Future.wait([f1, f2]);

      expect(recorder.entries, hasLength(2));
      expect(await verifyFlightRecorderChain(recorder.entries), isTrue,
          reason: 'a fork (two entries sharing one previousHash) must '
              'never happen for real unawaited call-site usage');
      final previousHashes = recorder.entries.map((e) => e.previousHash);
      expect(previousHashes.toSet(), hasLength(2),
          reason: 'no two entries may share the same previousHash — that '
              'is exactly what a fork looks like');
    });

    test('burst of 5 unawaited calls produces a valid linear chain, no '
        'forking, no dropped entries', () async {
      final recorder = AdFlightRecorder();
      final futures = <Future<void>>[];
      for (var i = 0; i < 5; i++) {
        futures.add(recorder.record(
            label: 'e$i',
            slotType: 'banner',
            placement: 'home',
            providerTag: '[AdMob]'));
      }
      await Future.wait(futures);

      expect(recorder.entries, hasLength(5));
      expect(await verifyFlightRecorderChain(recorder.entries), isTrue);
      final previousHashes = recorder.entries.map((e) => e.previousHash);
      expect(previousHashes.toSet(), hasLength(5));
      final hashes = recorder.entries.map((e) => e.hash);
      expect(hashes.toSet(), hasLength(5), reason: 'no duplicate hashes');
    });

    test('mixed burst: unawaited record() calls racing a clear() in '
        'between never leaves the chain forked or corrupt', () async {
      // Not T235's territory (disable/re-enable) — this only checks that
      // an in-flight record() racing a synchronous clear() doesn't leave
      // a stale entry chained onto a hash that clear() already reset.
      final recorder = AdFlightRecorder();
      final f1 = recorder.record(
          label: 'before-clear',
          slotType: 'banner',
          placement: 'home',
          providerTag: '[AdMob]');
      recorder.clear();
      final f2 = recorder.record(
          label: 'after-clear',
          slotType: 'banner',
          placement: 'home',
          providerTag: '[AdMob]');
      await Future.wait([f1, f2]);

      expect(await verifyFlightRecorderChain(recorder.entries), isTrue);
      final previousHashes = recorder.entries.map((e) => e.previousHash);
      expect(previousHashes.toSet().length, recorder.entries.length,
          reason: 'still no two entries sharing one previousHash');
    });
  });
}
