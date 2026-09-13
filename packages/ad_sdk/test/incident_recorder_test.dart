// T125 — offline incident recorder: a small ring buffer of state-transition
// snapshots (not full events, see AdEventLog for that), exportable as a
// signed bundle a publisher can hand a support case, replayable entirely
// locally via tool/incident_replay.dart. This file tests the same pure
// logic that tool exercises, without going through a file/process.
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

const _snapA = AdSdkStateSnapshot(
  isInitialised: false,
  canRequestAds: false,
  isOffline: true,
  isVipActive: false,
  fullscreenBusy: false,
);
const _snapB = AdSdkStateSnapshot(
  isInitialised: true,
  canRequestAds: false,
  isOffline: false,
  isVipActive: false,
  fullscreenBusy: false,
);
const _snapC = AdSdkStateSnapshot(
  isInitialised: true,
  canRequestAds: true,
  isOffline: false,
  isVipActive: false,
  fullscreenBusy: true,
);

const _config = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
      bannerId: 'b', interstitialId: 'i', appOpenId: 'ao', rewardedId: 'r'),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('IncidentRecorder ring buffer', () {
    test('records in order with deltaMs relative to the previous entry', () {
      final recorder = IncidentRecorder();
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);
      recorder.record('boot', _snapA, now: t0);
      recorder.record('adapterInitialized', _snapB,
          now: t0.add(const Duration(milliseconds: 500)));
      recorder.record('consentChanged', _snapC,
          now: t0.add(const Duration(milliseconds: 1300)));

      expect(recorder.entries.map((e) => e.label),
          ['boot', 'adapterInitialized', 'consentChanged']);
      expect(recorder.entries.map((e) => e.deltaMs), [0, 500, 800]);
      expect(recorder.entries.last.snapshot, _snapC);
    });

    test('drops oldest entries past capacity, keeps the newest window', () {
      final recorder = IncidentRecorder(capacity: 3);
      for (var i = 0; i < 5; i++) {
        recorder.record('e$i', _snapA, now: DateTime(2026, 1, 1, 12, 0, i));
      }
      expect(recorder.entries.map((e) => e.label), ['e2', 'e3', 'e4']);
    });

    test('clear() empties the buffer and resets the delta baseline', () {
      final recorder = IncidentRecorder();
      recorder.record('a', _snapA, now: DateTime(2026, 1, 1));
      recorder.clear();
      expect(recorder.entries, isEmpty);

      recorder.record('b', _snapB, now: DateTime(2026, 1, 2));
      expect(recorder.entries.single.deltaMs, 0,
          reason: 'after clear(), the next entry is a fresh baseline, not a '
              'multi-day delta from the entry that was wiped');
    });
  });

  // T199 — a wall clock that reads BEHIND the previous entry (NTP sync,
  // manual clock edit, timezone change) used to produce a raw negative
  // deltaMs — confusing in a timeline, and not something a reader could
  // tell apart from ordinary data.
  group('clock rollback detection (T199)', () {
    test('a clock that reads BEHIND the previous entry clamps deltaMs to '
        '0 and records the raw rollback amount', () {
      final recorder = IncidentRecorder();
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);
      recorder.record('a', _snapA, now: t0);
      recorder.record('b', _snapB,
          now: t0.subtract(const Duration(seconds: 5)));

      final entries = recorder.entries;
      expect(entries[0].clockRolledBackMs, isNull);
      expect(entries[1].deltaMs, 0,
          reason: 'clamped for display sanity — never a negative number');
      expect(entries[1].clockRolledBackMs, -5000,
          reason: 'the raw rollback amount must still be visible, not '
              'silently discarded by the clamp');
    });

    test('an ordinary forward-moving clock never sets clockRolledBackMs',
        () {
      final recorder = IncidentRecorder();
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);
      recorder.record('a', _snapA, now: t0);
      recorder.record('b', _snapB,
          now: t0.add(const Duration(milliseconds: 500)));

      expect(recorder.entries.every((e) => e.clockRolledBackMs == null),
          isTrue);
    });

    test('the first entry in a buffer never has a rollback (nothing to '
        'compare against yet)', () {
      final recorder = IncidentRecorder();
      recorder.record('a', _snapA, now: DateTime(2026, 1, 1));

      expect(recorder.entries.single.clockRolledBackMs, isNull);
      expect(recorder.entries.single.deltaMs, 0);
    });

    test('a rollback entry survives a JSON round-trip (IncidentBundle '
        'export/import) — not silently dropped', () {
      final recorder = IncidentRecorder();
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);
      recorder.record('a', _snapA, now: t0);
      recorder.record('b', _snapB,
          now: t0.subtract(const Duration(seconds: 2)));

      final bundle = IncidentBundle.capture(recorder, _config);
      final decoded = IncidentBundle.fromJsonString(bundle.toJsonString());

      expect(decoded.entries[1].clockRolledBackMs, -2000);
      expect(decoded.entries[1].deltaMs, 0);
    });

    test('an entry with no rollback omits clockRolledBackMs from the JSON '
        'entirely, not just as a null value — old exports without this '
        'field must decode identically to a real "no rollback" entry', () {
      const entry = IncidentEntry(
        label: 'a',
        snapshot: AdSdkStateSnapshot(
          isInitialised: true,
          canRequestAds: true,
          isOffline: false,
          isVipActive: false,
          fullscreenBusy: false,
        ),
        deltaMs: 0,
      );

      expect(entry.toJson().containsKey('clockRolledBackMs'), isFalse);
      expect(IncidentEntry.fromJson(entry.toJson()).clockRolledBackMs, isNull);
    });

    test('toString() surfaces the rollback for a human reading the '
        'timeline directly', () {
      final recorder = IncidentRecorder();
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);
      recorder.record('a', _snapA, now: t0);
      recorder.record('b', _snapB,
          now: t0.subtract(const Duration(seconds: 5)));

      expect(recorder.entries[1].toString(), contains('rolled back'));
    });
  });

  group('redactedConfigFingerprint', () {
    test('carries provider/safety shape but never an ad-unit ID or SDK key',
        () {
      final fp = redactedConfigFingerprint(_config);
      expect(fp['provider'], 'admob');
      expect(fp['hasAdMobConfig'], isTrue);
      expect(fp['hasAppLovinConfig'], isFalse);
      expect(fp.toString(), isNot(contains('interstitialId')));
      expect(fp.toString(), isNot(contains(' i,')));
      expect((fp['safety'] as Map)['dryRun'], isFalse);
    });
  });

  group('IncidentBundle JSON round-trip', () {
    test('fromJsonString(toJsonString()) reproduces the exact entry sequence',
        () {
      final recorder = IncidentRecorder();
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);
      recorder.record('boot', _snapA, now: t0);
      recorder.record('ready', _snapC,
          now: t0.add(const Duration(milliseconds: 250)));

      final bundle =
          IncidentBundle.capture(recorder, _config, now: t0);
      final json = bundle.toJsonString();
      final replayed = IncidentBundle.fromJsonString(json);

      expect(replayed.entries.length, bundle.entries.length);
      for (var i = 0; i < bundle.entries.length; i++) {
        expect(replayed.entries[i].label, bundle.entries[i].label);
        expect(replayed.entries[i].deltaMs, bundle.entries[i].deltaMs);
        expect(replayed.entries[i].snapshot, bundle.entries[i].snapshot);
      }
      expect(replayed.configFingerprint, bundle.configFingerprint);
    });

    test('replayIncidentBundleJson gives the same sequence as the source '
        'recorder — the actual "replay reproduces the recorded state '
        'sequence" contract', () {
      final recorder = IncidentRecorder();
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);
      recorder.record('a', _snapA, now: t0);
      recorder.record('b', _snapB,
          now: t0.add(const Duration(milliseconds: 100)));
      recorder.record('c', _snapC,
          now: t0.add(const Duration(milliseconds: 900)));

      final bundle = IncidentBundle.capture(recorder, _config, now: t0);
      final replayed = replayIncidentBundleJson(bundle.toJsonString());

      expect(replayed.map((e) => e.toString()).toList(),
          recorder.entries.map((e) => e.toString()).toList());
    });
  });

  group('signIncidentBundle (Ed25519, reuses compliance-signing infra)', () {
    test('a signed bundle verifies via verifySignedJsonPayload', () async {
      final recorder = IncidentRecorder();
      recorder.record('boot', _snapA, now: DateTime(2026, 1, 1));
      final bundle = IncidentBundle.capture(recorder, _config);

      final signed = await signIncidentBundle(bundle);
      final envelopeJson = signed.toJsonString();

      expect(await verifySignedJsonPayload(envelopeJson), isTrue);
      expect(signed.payloadJson, bundle.toJsonString());
    });

    test('a bit-flipped payload fails verification', () async {
      final recorder = IncidentRecorder();
      recorder.record('boot', _snapA, now: DateTime(2026, 1, 1));
      final bundle = IncidentBundle.capture(recorder, _config);
      final signed = await signIncidentBundle(bundle);

      final tampered = SignedPayload(
        payloadJson: signed.payloadJson.replaceFirst('"boot"', '"tampered"'),
        publicKeyBase64: signed.publicKeyBase64,
        signatureBase64: signed.signatureBase64,
      );

      expect(await verifySignedJsonPayload(tampered.toJsonString()), isFalse);
    });
  });

  group('T171 — capacity <= 0 falls back to the default instead of '
      'crashing on the first record()', () {
    test('capacity=0 still records instead of RangeError-ing immediately',
        () {
      final recorder = IncidentRecorder(capacity: 0);
      // T171 — with the old bare `assert(capacity > 0)` (stripped in
      // release builds), a 0 here made `removeRange(0, _entries.length -
      // capacity)` run with `_entries.length - 0 == _entries.length` right
      // after the very first add — same end as start, which is valid and
      // just clears the buffer straight back to empty (a silent, not a
      // crashing, bug). The real crash was for negative — see below.
      recorder.record('boot', _snapA, now: DateTime(2026, 1, 1));
      expect(recorder.capacity, 200,
          reason: 'substituted the class\'s own documented default');
      expect(recorder.entries, hasLength(1));
    });

    test('a negative capacity also falls back instead of throwing a '
        'RangeError on the very first record()', () {
      final recorder = IncidentRecorder(capacity: -5);
      expect(recorder.capacity, 200);
      // Old bug: entries.length(0) - capacity(-5) == 5, and
      // removeRange(0, 5) on a still-empty list throws a RangeError —
      // this used to crash on the FIRST call, not just once the buffer
      // filled up.
      recorder.record('boot', _snapA, now: DateTime(2026, 1, 1));
      expect(recorder.entries, hasLength(1));
    });
  });
}
