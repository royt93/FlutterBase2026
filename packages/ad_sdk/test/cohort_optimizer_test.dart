import 'dart:convert';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeSecureStorage extends FlutterSecureStorage {
  final Map<String, String> _store = {};

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _store[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _store.remove(key);
    } else {
      _store[key] = value;
    }
  }
}

Future<int?> _readAnchor(AdPreferences prefs) async {
  final raw = prefs.getCohortOptimizerClockAnchorRaw();
  if (raw == null) return null;
  final bundle = jsonDecode(raw) as Map<String, dynamic>;
  return jsonDecode(bundle['payloadJson'] as String) as int;
}

Future<void> _writeStateForTest(
  AdPreferences prefs,
  _FakeSecureStorage storage, {
  required List<Map<String, Object>> records,
  required int anchor,
}) async {
  final signedRecords = await signJsonPayload(
    jsonEncode(records),
    secureStorage: storage,
  );
  final signedAnchor = await signJsonPayload(
    jsonEncode(anchor),
    secureStorage: storage,
  );
  await prefs.setCohortOptimizerRecordsRaw(signedRecords.toJsonString());
  await prefs.setCohortOptimizerClockAnchorRaw(signedAnchor.toJsonString());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AdPreferences.resetForTest();
    AdPreferences.debugBeforeCohortWrite = null;
    AdPreferences.debugCohortRecordsWriteResult = null;
    AdPreferences.debugCohortAnchorWriteResult = null;
    AdPreferences.debugCohortRestoreWriteResult = null;
    CohortOptimizer.debugNowMs = null;
    CohortOptimizer.debugSimulateReleaseMode = false;
  });

  test(
    'CohortOptimizer rejects negative impressions without mutating storage',
    () async {
      final prefs = await AdPreferences.getInstance();
      final optimizer = CohortOptimizer(prefs, storage: _FakeSecureStorage());
      await optimizer.recordSession(
        provider: AdProvider.admob,
        impressions: 1,
        revenueMicros: 100,
      );
      final previousRecords = prefs.getCohortOptimizerRecordsRaw();
      final previousAnchor = prefs.getCohortOptimizerClockAnchorRaw();

      await expectLater(
        optimizer.recordSession(
          provider: AdProvider.admob,
          impressions: -1,
          revenueMicros: 100,
        ),
        throwsArgumentError,
      );

      expect(prefs.getCohortOptimizerRecordsRaw(), previousRecords);
      expect(prefs.getCohortOptimizerClockAnchorRaw(), previousAnchor);
    },
  );

  test(
    'CohortOptimizer rejects negative revenue without mutating storage',
    () async {
      final prefs = await AdPreferences.getInstance();
      final optimizer = CohortOptimizer(prefs, storage: _FakeSecureStorage());
      await optimizer.recordSession(
        provider: AdProvider.admob,
        impressions: 1,
        revenueMicros: 100,
      );
      final previousRecords = prefs.getCohortOptimizerRecordsRaw();
      final previousAnchor = prefs.getCohortOptimizerClockAnchorRaw();

      await expectLater(
        optimizer.recordSession(
          provider: AdProvider.admob,
          impressions: 1,
          revenueMicros: -1,
        ),
        throwsArgumentError,
      );

      expect(prefs.getCohortOptimizerRecordsRaw(), previousRecords);
      expect(prefs.getCohortOptimizerClockAnchorRaw(), previousAnchor);
    },
  );

  test('CohortOptimizer accepts zero and large non-negative metrics', () async {
    final prefs = await AdPreferences.getInstance();
    final optimizer = CohortOptimizer(prefs, storage: _FakeSecureStorage());

    await optimizer.recordSession(
      provider: AdProvider.admob,
      impressions: 0,
      revenueMicros: 0,
    );
    const largeMetric = 1000000000000;
    await optimizer.recordSession(
      provider: AdProvider.appLovin,
      impressions: largeMetric,
      revenueMicros: largeMetric,
    );

    final records = await optimizer.loadVerifiedRecords();
    expect(records, hasLength(2));
    expect(records.first.impressions, 0);
    expect(records.first.revenueMicros, 0);
    expect(records.last.impressions, largeMetric);
    expect(records.last.revenueMicros, largeMetric);
  });

  test(
    'CohortOptimizer ecpm aggregation does not overflow integer limits',
    () async {
      final prefs = await AdPreferences.getInstance();
      final storage = _FakeSecureStorage();
      final optimizer = CohortOptimizer(
        prefs,
        storage: storage,
        minSessionsPerProvider: 2,
      );
      final now = DateTime.now().millisecondsSinceEpoch;
      const maxInt = 0x7fffffffffffffff;
      await _writeStateForTest(
        prefs,
        storage,
        records: [
          for (var i = 0; i < 2; i++)
            {
              'provider': AdProvider.admob.name,
              'impressions': maxInt,
              'revenueMicros': maxInt,
              'timestampMs': now,
            },
          for (var i = 0; i < 2; i++)
            {
              'provider': AdProvider.appLovin.name,
              'impressions': 1,
              'revenueMicros': 1,
              'timestampMs': now,
            },
        ],
        anchor: now,
      );
      CohortOptimizer.debugNowMs = () => now;

      expect(await optimizer.recommendedProviderForNextInit(), isNull);
    },
  );

  test('CohortOptimizer drops signed negative legacy metrics', () async {
    final prefs = await AdPreferences.getInstance();
    final storage = _FakeSecureStorage();
    final optimizer = CohortOptimizer(prefs, storage: storage);
    final now = DateTime.now().millisecondsSinceEpoch;
    await _writeStateForTest(
      prefs,
      storage,
      records: [
        {
          'provider': AdProvider.admob.name,
          'impressions': -1,
          'revenueMicros': 100,
          'timestampMs': now,
        },
        {
          'provider': AdProvider.appLovin.name,
          'impressions': 1,
          'revenueMicros': -100,
          'timestampMs': now,
        },
        {
          'provider': AdProvider.admob.name,
          'impressions': 1,
          'revenueMicros': 100,
          'timestampMs': now,
        },
      ],
      anchor: now,
    );

    final records = await optimizer.loadVerifiedRecords();
    expect(records, hasLength(1));
    expect(records.single.provider, AdProvider.admob);
    expect(records.single.impressions, 1);
  });

  test(
    'CohortOptimizer returns null when sessions count is below threshold',
    () async {
      final prefs = await AdPreferences.getInstance();
      final storage = _FakeSecureStorage();
      final optimizer = CohortOptimizer(
        prefs,
        storage: storage,
        minSessionsPerProvider: 3,
      );

      // Only 2 sessions for AdMob, 0 for AppLovin
      await optimizer.recordSession(
        provider: AdProvider.admob,
        impressions: 10,
        revenueMicros: 50000,
      );
      await optimizer.recordSession(
        provider: AdProvider.admob,
        impressions: 10,
        revenueMicros: 50000,
      );

      final recommendation = await optimizer.recommendedProviderForNextInit();
      expect(recommendation, isNull);
    },
  );

  test('CohortOptimizer recommends provider with higher average eCPM', () async {
    final prefs = await AdPreferences.getInstance();
    final storage = _FakeSecureStorage();
    final optimizer = CohortOptimizer(
      prefs,
      storage: storage,
      minSessionsPerProvider: 2,
    );

    // AdMob: 2 sessions, total 20 impressions, 20_000 micros => eCPM = 1000
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

    // AppLovin: 2 sessions, total 20 impressions, 60_000 micros => eCPM = 3000
    await optimizer.recordSession(
      provider: AdProvider.appLovin,
      impressions: 10,
      revenueMicros: 30000,
    );
    await optimizer.recordSession(
      provider: AdProvider.appLovin,
      impressions: 10,
      revenueMicros: 30000,
    );

    final recommendation = await optimizer.recommendedProviderForNextInit();
    expect(recommendation, equals(AdProvider.appLovin));
  });

  test(
    'CohortOptimizer retains signed records inside the 90-day window',
    () async {
      final prefs = await AdPreferences.getInstance();
      final storage = _FakeSecureStorage();
      final now = DateTime.now();
      final optimizer = CohortOptimizer(
        prefs,
        storage: storage,
        minSessionsPerProvider: 1,
      );
      final payload = jsonEncode([
        {
          'provider': AdProvider.admob.name,
          'impressions': 1,
          'revenueMicros': 100,
          'timestampMs': now
              .subtract(const Duration(days: 91))
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
        {
          'provider': AdProvider.admob.name,
          'impressions': 10,
          'revenueMicros': 100000,
          'timestampMs': now.millisecondsSinceEpoch,
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
          'provider': AdProvider.appLovin.name,
          'impressions': 1,
          'revenueMicros': 1000,
          'timestampMs': now.millisecondsSinceEpoch,
        },
      ]);
      final signed = await signJsonPayload(payload, secureStorage: storage);
      await prefs.setCohortOptimizerRecordsRaw(signed.toJsonString());
      await optimizer.recordSession(
        provider: AdProvider.appLovin,
        impressions: 1,
        revenueMicros: 1000,
      );

      final records = await optimizer.loadVerifiedRecords();
      expect(records.map((record) => record.impressions), [2, 10, 1, 1]);
      expect(
        records.map((record) => record.timestampMs).first,
        greaterThanOrEqualTo(
          now.subtract(const Duration(days: 90)).millisecondsSinceEpoch,
        ),
      );
      expect(
        records.map((record) => record.timestampMs).last,
        greaterThanOrEqualTo(now.millisecondsSinceEpoch),
      );
      expect(
        await optimizer.recommendedProviderForNextInit(),
        AdProvider.admob,
      );

      final raw = prefs.getCohortOptimizerRecordsRaw();
      expect(raw, isNotNull);
      expect(await verifySignedJsonPayload(raw!), isTrue);
    },
  );

  test(
    'CohortOptimizer recommendation ignores stale and future records',
    () async {
      final prefs = await AdPreferences.getInstance();
      final storage = _FakeSecureStorage();
      final optimizer = CohortOptimizer(prefs, storage: storage);
      final now = DateTime.now();
      final signed = await signJsonPayload(
        jsonEncode([
          {
            'provider': AdProvider.admob.name,
            'impressions': 100,
            'revenueMicros': 100000,
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
        ]),
        secureStorage: storage,
      );
      await prefs.setCohortOptimizerRecordsRaw(signed.toJsonString());

      expect(await optimizer.recommendedProviderForNextInit(), isNull);
    },
  );

  test('CohortOptimizer prunes stale rows when clock is plausible', () async {
    final prefs = await AdPreferences.getInstance();
    final storage = _FakeSecureStorage();
    final optimizer = CohortOptimizer(prefs, storage: storage);
    final now = DateTime.now();
    final signed = await signJsonPayload(
      jsonEncode([
        {
          'provider': AdProvider.admob.name,
          'impressions': 100,
          'revenueMicros': 100000,
          'timestampMs': now
              .subtract(const Duration(days: 91))
              .millisecondsSinceEpoch,
        },
        {
          'provider': AdProvider.appLovin.name,
          'impressions': 1,
          'revenueMicros': 100,
          'timestampMs': now
              .subtract(const Duration(days: 1))
              .millisecondsSinceEpoch,
        },
      ]),
      secureStorage: storage,
    );
    await prefs.setCohortOptimizerRecordsRaw(signed.toJsonString());

    await optimizer.recordSession(
      provider: AdProvider.admob,
      impressions: 1,
      revenueMicros: 100,
    );

    final records = await optimizer.loadVerifiedRecords();
    expect(records, hasLength(2));
    expect(records.map((record) => record.impressions), [1, 1]);
    expect(
      await verifySignedJsonPayload(prefs.getCohortOptimizerRecordsRaw()!),
      isTrue,
    );
  });

  test(
    'CohortOptimizer keeps legacy clock anchor across multiple writes',
    () async {
      final prefs = await AdPreferences.getInstance();
      final storage = _FakeSecureStorage();
      final optimizer = CohortOptimizer(prefs, storage: storage);
      final now = DateTime.now();
      final staleTimestamp = now
          .subtract(const Duration(days: 91))
          .millisecondsSinceEpoch;
      final futureTimestamp = now
          .add(const Duration(days: 91))
          .millisecondsSinceEpoch;
      final signed = await signJsonPayload(
        jsonEncode([
          {
            'provider': AdProvider.admob.name,
            'impressions': 100,
            'revenueMicros': 100000,
            'timestampMs': staleTimestamp,
          },
          {
            'provider': AdProvider.appLovin.name,
            'impressions': 100,
            'revenueMicros': 100000,
            'timestampMs': futureTimestamp,
          },
        ]),
        secureStorage: storage,
      );
      await prefs.setCohortOptimizerRecordsRaw(signed.toJsonString());

      await optimizer.recordSession(
        provider: AdProvider.admob,
        impressions: 1,
        revenueMicros: 100,
      );
      await optimizer.recordSession(
        provider: AdProvider.admob,
        impressions: 2,
        revenueMicros: 200,
      );

      final records = await optimizer.loadVerifiedRecords();
      expect(
        records.map((record) => record.timestampMs),
        contains(staleTimestamp),
      );
      expect(
        records.map((record) => record.timestampMs),
        contains(futureTimestamp),
      );
      final raw = prefs.getCohortOptimizerRecordsRaw()!;
      expect(await verifySignedJsonPayload(raw), isTrue);
      final anchorValue = await _readAnchor(prefs);
      expect(anchorValue, futureTimestamp);
    },
  );

  test(
    'CohortOptimizer advances anchor after more than 7 days offline',
    () async {
      final prefs = await AdPreferences.getInstance();
      final storage = _FakeSecureStorage();
      final optimizer = CohortOptimizer(prefs, storage: storage);
      final now = DateTime.now();
      final anchor = now
          .subtract(const Duration(days: 8))
          .millisecondsSinceEpoch;
      final staleTimestamp = now
          .subtract(const Duration(days: 100))
          .millisecondsSinceEpoch;
      await _writeStateForTest(
        prefs,
        storage,
        records: [
          {
            'provider': AdProvider.admob.name,
            'impressions': 10,
            'revenueMicros': 1000,
            'timestampMs': staleTimestamp,
          },
        ],
        anchor: anchor,
      );

      await optimizer.recordSession(
        provider: AdProvider.appLovin,
        impressions: 1,
        revenueMicros: 100,
      );

      final records = await optimizer.loadVerifiedRecords();
      expect(records, hasLength(1));
      expect(records.single.provider, AdProvider.appLovin);
      expect(records.single.timestampMs, greaterThanOrEqualTo(anchor));
      expect(
        records.map((r) => r.timestampMs),
        isNot(contains(staleTimestamp)),
      );
      final raw = prefs.getCohortOptimizerRecordsRaw()!;
      final anchorValue = await _readAnchor(prefs);
      expect(anchorValue, greaterThanOrEqualTo(anchor));
      expect(await verifySignedJsonPayload(raw), isTrue);
    },
  );

  test(
    'CohortOptimizer preserves anchor on clock rollback over 7 days',
    () async {
      final prefs = await AdPreferences.getInstance();
      final storage = _FakeSecureStorage();
      final optimizer = CohortOptimizer(prefs, storage: storage);
      final now = DateTime.now();
      final anchor = now.add(const Duration(days: 8)).millisecondsSinceEpoch;
      await _writeStateForTest(
        prefs,
        storage,
        records: [
          {
            'provider': AdProvider.admob.name,
            'impressions': 10,
            'revenueMicros': 1000,
            'timestampMs': anchor,
          },
        ],
        anchor: anchor,
      );

      await optimizer.recordSession(
        provider: AdProvider.appLovin,
        impressions: 1,
        revenueMicros: 100,
      );

      final records = await optimizer.loadVerifiedRecords();
      expect(records, hasLength(2));
      expect(records.first.timestampMs, anchor);
      final raw = prefs.getCohortOptimizerRecordsRaw()!;
      final anchorValue = await _readAnchor(prefs);
      expect(anchorValue, anchor);
      expect(await verifySignedJsonPayload(raw), isTrue);
    },
  );

  test(
    'CohortOptimizer boundary: exactly 7 days rollback still prunes, 7 days plus 1ms skips pruning',
    () async {
      final prefs = await AdPreferences.getInstance();
      final storage = _FakeSecureStorage();
      final optimizer = CohortOptimizer(prefs, storage: storage);
      final now = DateTime.now().millisecondsSinceEpoch;
      final sevenDaysMs = const Duration(days: 7).inMilliseconds;
      final staleRecord = now - const Duration(days: 91).inMilliseconds;

      // Exactly 7 days of rollback is accepted and prunes stale rows.
      final anchorExact = now + sevenDaysMs;
      CohortOptimizer.debugNowMs = () => now;
      await _writeStateForTest(
        prefs,
        storage,
        records: [
          {
            'provider': AdProvider.admob.name,
            'impressions': 10,
            'revenueMicros': 1000,
            'timestampMs': staleRecord,
          },
        ],
        anchor: anchorExact,
      );
      await optimizer.recordSession(
        provider: AdProvider.appLovin,
        impressions: 1,
        revenueMicros: 100,
      );
      var records = await optimizer.loadVerifiedRecords();
      // Stale record was pruned exactly at the 7-day rollback boundary.
      expect(records, hasLength(1));
      expect(records.first.provider, AdProvider.appLovin);

      // 7 days + 1ms of rollback preserves stale rows and the anchor.
      final anchorBeyond = now + sevenDaysMs + 1;
      await _writeStateForTest(
        prefs,
        storage,
        records: [
          {
            'provider': AdProvider.admob.name,
            'impressions': 10,
            'revenueMicros': 1000,
            'timestampMs': staleRecord,
          },
          {
            'provider': AdProvider.admob.name,
            'impressions': 20,
            'revenueMicros': 2000,
            'timestampMs': now + const Duration(days: 1).inMilliseconds,
          },
        ],
        anchor: anchorBeyond,
      );
      await optimizer.recordSession(
        provider: AdProvider.appLovin,
        impressions: 1,
        revenueMicros: 100,
      );
      records = await optimizer.loadVerifiedRecords();
      // Stale and future rows remain because isRollback is true.
      expect(records, hasLength(3));
      expect(records.map((r) => r.timestampMs), contains(staleRecord));
      expect(
        records.map((r) => r.timestampMs),
        contains(now + const Duration(days: 1).inMilliseconds),
      );
    },
  );

  test(
    'CohortOptimizer recommendation window boundary: strictly [now-90d, now]',
    () async {
      final prefs = await AdPreferences.getInstance();
      final storage = _FakeSecureStorage();
      final optimizer = CohortOptimizer(
        prefs,
        storage: storage,
        minSessionsPerProvider: 1,
      );
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      CohortOptimizer.debugNowMs = () => nowMs;
      final exactCutoff = nowMs - const Duration(days: 90).inMilliseconds;
      final justBeforeCutoff = exactCutoff - 1;
      final justAfterNow = nowMs + 1;

      await _writeStateForTest(
        prefs,
        storage,
        records: [
          {
            'provider': AdProvider.admob.name,
            'impressions': 10,
            'revenueMicros': 10000,
            'timestampMs': justBeforeCutoff, // Outside: cutoff - 1ms
          },
          {
            'provider': AdProvider.admob.name,
            'impressions': 10,
            'revenueMicros': 10000,
            'timestampMs': exactCutoff, // Inside: exact 90-day cutoff
          },
          {
            'provider': AdProvider.appLovin.name,
            'impressions': 10,
            'revenueMicros': 5000,
            'timestampMs': nowMs, // Inside: exact now
          },
          {
            'provider': AdProvider.appLovin.name,
            'impressions': 10,
            'revenueMicros': 50000,
            'timestampMs': justAfterNow, // Outside: now + 1ms
          },
        ],
        anchor: nowMs,
      );

      // Only admob at exactCutoff (eCPM=1000) and appLovin at nowMs (eCPM=500) count.
      // Out-of-bounds records are excluded.
      final recommendation = await optimizer.recommendedProviderForNextInit();
      expect(recommendation, AdProvider.admob);
    },
  );

  test(
    'CohortOptimizer repairs an anchor older than records after downgrade writes',
    () async {
      final prefs = await AdPreferences.getInstance();
      final storage = _FakeSecureStorage();
      final optimizer = CohortOptimizer(prefs, storage: storage);
      final now = DateTime.now().millisecondsSinceEpoch;
      final oldAnchor = now - const Duration(days: 10).inMilliseconds;
      final newerLegacyRecord = now - const Duration(days: 2).inMilliseconds;
      await _writeStateForTest(
        prefs,
        storage,
        records: [
          {
            'provider': AdProvider.admob.name,
            'impressions': 1,
            'revenueMicros': 100,
            'timestampMs': newerLegacyRecord,
          },
        ],
        anchor: oldAnchor,
      );
      CohortOptimizer.debugNowMs = () => now;

      await optimizer.recordSession(
        provider: AdProvider.appLovin,
        impressions: 1,
        revenueMicros: 100,
      );

      expect(await _readAnchor(prefs), now);
      expect(await optimizer.loadVerifiedRecords(), hasLength(2));
    },
  );

  test(
    'CohortOptimizer keeps a legacy list payload for downgrade compatibility',
    () async {
      final prefs = await AdPreferences.getInstance();
      final storage = _FakeSecureStorage();
      final optimizer = CohortOptimizer(prefs, storage: storage);

      await optimizer.recordSession(
        provider: AdProvider.admob,
        impressions: 5,
        revenueMicros: 500,
      );
      final rawBefore = prefs.getCohortOptimizerRecordsRaw()!;
      final bundleBefore = jsonDecode(rawBefore) as Map<String, dynamic>;
      expect(jsonDecode(bundleBefore['payloadJson'] as String), isA<List>());

      // Simulate an older SDK's read/append/write behavior against the stable key.
      final oldPayload =
          jsonDecode(bundleBefore['payloadJson'] as String) as List;
      oldPayload.add({
        'provider': AdProvider.appLovin.name,
        'impressions': 1,
        'revenueMicros': 100,
        'timestampMs': DateTime.now().millisecondsSinceEpoch,
      });
      final legacyWrite = await signJsonPayload(
        jsonEncode(oldPayload),
        secureStorage: storage,
      );
      await prefs.setCohortOptimizerRecordsRaw(legacyWrite.toJsonString());

      final upgradedOptimizer = CohortOptimizer(prefs, storage: storage);
      expect(await upgradedOptimizer.loadVerifiedRecords(), hasLength(2));
      await upgradedOptimizer.recordSession(
        provider: AdProvider.admob,
        impressions: 2,
        revenueMicros: 200,
      );
      expect(await upgradedOptimizer.loadVerifiedRecords(), hasLength(3));
      expect(await _readAnchor(prefs), isNotNull);
    },
  );

  test('CohortOptimizer does not overwrite an unknown signed schema', () async {
    final prefs = await AdPreferences.getInstance();
    final storage = _FakeSecureStorage();
    final optimizer = CohortOptimizer(prefs, storage: storage);
    final signed = await signJsonPayload(
      jsonEncode({'schemaVersion': 2, 'records': []}),
      secureStorage: storage,
    );
    final previousRaw = signed.toJsonString();
    await prefs.setCohortOptimizerRecordsRaw(previousRaw);

    await optimizer.recordSession(
      provider: AdProvider.admob,
      impressions: 1,
      revenueMicros: 100,
    );

    expect(prefs.getCohortOptimizerRecordsRaw(), previousRaw);
  });

  test(
    'CohortOptimizer drops malformed rows but keeps valid ones and keeps writing',
    () async {
      final prefs = await AdPreferences.getInstance();
      final storage = _FakeSecureStorage();
      final optimizer = CohortOptimizer(prefs, storage: storage);
      final now = DateTime.now().millisecondsSinceEpoch;
      final signed = await signJsonPayload(
        jsonEncode([
          {
            'provider': AdProvider.admob.name,
            'impressions': 5,
            'revenueMicros': 500,
            'timestampMs': now,
          },
          {
            'provider': AdProvider.admob.name,
            'impressions': 'not-an-int',
            'revenueMicros': 500,
            'timestampMs': now,
          },
          {
            'provider': AdProvider.admob.name,
            'revenueMicros': 500,
            'timestampMs': now,
          },
          {
            'provider': AdProvider.admob.name,
            'impressions': 3,
            'revenueMicros': 300,
          },
          'not-a-map',
          {
            'provider': 'unknownNetwork',
            'impressions': 7,
            'revenueMicros': 700,
            'timestampMs': now,
          },
        ]),
        secureStorage: storage,
      );
      await prefs.setCohortOptimizerRecordsRaw(signed.toJsonString());

      await optimizer.recordSession(
        provider: AdProvider.appLovin,
        impressions: 1,
        revenueMicros: 100,
      );

      final records = await optimizer.loadVerifiedRecords();
      expect(records.map((r) => r.impressions), [5, 1]);
      expect(records.map((r) => r.provider), [
        AdProvider.admob,
        AdProvider.appLovin,
      ]);
      expect(
        await verifySignedJsonPayload(prefs.getCohortOptimizerRecordsRaw()!),
        isTrue,
      );
    },
  );

  test(
    'CohortOptimizer preserves the trusted anchor when wall clock rolls back within 7 days',
    () async {
      final prefs = await AdPreferences.getInstance();
      final storage = _FakeSecureStorage();
      final optimizer = CohortOptimizer(prefs, storage: storage);
      final now = DateTime.now();
      final anchor = now.add(const Duration(days: 1)).millisecondsSinceEpoch;
      await _writeStateForTest(prefs, storage, records: [], anchor: anchor);

      await optimizer.recordSession(
        provider: AdProvider.admob,
        impressions: 1,
        revenueMicros: 100,
      );

      final anchorValue = await _readAnchor(prefs);
      expect(anchorValue, anchor);
    },
  );

  test('CohortOptimizer serializes concurrent record writes', () async {
    final prefs = await AdPreferences.getInstance();
    final optimizer = CohortOptimizer(prefs, storage: _FakeSecureStorage());

    await Future.wait([
      for (var i = 0; i < 5; i++)
        optimizer.recordSession(
          provider: i.isEven ? AdProvider.admob : AdProvider.appLovin,
          impressions: i + 1,
          revenueMicros: (i + 1) * 100,
        ),
    ]);

    final records = await optimizer.loadVerifiedRecords();
    expect(records, hasLength(5));
    expect(records.map((record) => record.impressions).toSet(), {
      1,
      2,
      3,
      4,
      5,
    });
  });

  test('CohortOptimizer caps retained history at 100 records', () async {
    final prefs = await AdPreferences.getInstance();
    final storage = _FakeSecureStorage();
    final optimizer = CohortOptimizer(prefs, storage: storage);
    final now = DateTime.now();
    final signed = await signJsonPayload(
      jsonEncode([
        for (var i = 0; i < 101; i++)
          {
            'provider': AdProvider.admob.name,
            'impressions': i,
            'revenueMicros': i * 100,
            'timestampMs': now.millisecondsSinceEpoch,
          },
      ]),
      secureStorage: storage,
    );
    await prefs.setCohortOptimizerRecordsRaw(signed.toJsonString());

    await optimizer.recordSession(
      provider: AdProvider.admob,
      impressions: 101,
      revenueMicros: 10100,
    );

    final records = await optimizer.loadVerifiedRecords();
    expect(records, hasLength(100));
    expect(records.first.impressions, 2);
    expect(records.last.impressions, 101);
    expect(
      await verifySignedJsonPayload(prefs.getCohortOptimizerRecordsRaw()!),
      isTrue,
    );
  });

  test(
    'CohortOptimizer positional cap may evict the lower-volume provider',
    () async {
      final prefs = await AdPreferences.getInstance();
      final storage = _FakeSecureStorage();
      final optimizer = CohortOptimizer(
        prefs,
        storage: storage,
        minSessionsPerProvider: 3,
      );
      for (var i = 0; i < 3; i++) {
        await optimizer.recordSession(
          provider: AdProvider.appLovin,
          impressions: 1,
          revenueMicros: 100,
        );
      }
      for (var i = 0; i < 100; i++) {
        await optimizer.recordSession(
          provider: AdProvider.admob,
          impressions: 1,
          revenueMicros: 100,
        );
      }

      final records = await optimizer.loadVerifiedRecords();
      expect(records, hasLength(100));
      expect(
        records.every((record) => record.provider == AdProvider.admob),
        isTrue,
      );
      expect(await optimizer.recommendedProviderForNextInit(), isNull);
    },
  );

  test('CohortOptimizer preserves anchor when records key is absent', () async {
    final prefs = await AdPreferences.getInstance();
    final storage = _FakeSecureStorage();
    final optimizer = CohortOptimizer(prefs, storage: storage);
    final wallNow = DateTime.now().millisecondsSinceEpoch;
    final anchor = wallNow + const Duration(days: 8).inMilliseconds;
    final signedAnchor = await signJsonPayload(
      jsonEncode(anchor),
      secureStorage: storage,
    );
    await prefs.setCohortOptimizerClockAnchorRaw(signedAnchor.toJsonString());
    CohortOptimizer.debugNowMs = () => wallNow;

    await optimizer.recordSession(
      provider: AdProvider.admob,
      impressions: 1,
      revenueMicros: 100,
    );

    expect(await _readAnchor(prefs), anchor);
    expect(await optimizer.loadVerifiedRecords(), hasLength(1));
  });

  test(
    'CohortOptimizer preserves anchor when records signature is invalid',
    () async {
      final prefs = await AdPreferences.getInstance();
      final storage = _FakeSecureStorage();
      final optimizer = CohortOptimizer(prefs, storage: storage);
      final wallNow = DateTime.now().millisecondsSinceEpoch;
      final anchor = wallNow + const Duration(days: 8).inMilliseconds;
      final signedAnchor = await signJsonPayload(
        jsonEncode(anchor),
        secureStorage: storage,
      );
      final tamperedRecords = await signJsonPayload(
        jsonEncode([
          {
            'provider': AdProvider.admob.name,
            'impressions': 1,
            'revenueMicros': 100,
            'timestampMs': wallNow,
          },
        ]),
        secureStorage: storage,
      );
      final bundle =
          jsonDecode(tamperedRecords.toJsonString()) as Map<String, dynamic>;
      bundle['signatureBase64'] = 'broken';
      await prefs.setCohortOptimizerRecordsRaw(jsonEncode(bundle));
      await prefs.setCohortOptimizerClockAnchorRaw(signedAnchor.toJsonString());
      CohortOptimizer.debugNowMs = () => wallNow;

      await optimizer.recordSession(
        provider: AdProvider.appLovin,
        impressions: 1,
        revenueMicros: 50,
      );

      expect(await _readAnchor(prefs), anchor);
      expect(await optimizer.loadVerifiedRecords(), hasLength(1));
    },
  );

  test(
    'CohortOptimizer does not advance anchor when record write returns false',
    () async {
      final prefs = await AdPreferences.getInstance();
      final storage = _FakeSecureStorage();
      final optimizer = CohortOptimizer(prefs, storage: storage);
      final now = DateTime.now().millisecondsSinceEpoch;
      await _writeStateForTest(
        prefs,
        storage,
        records: [
          {
            'provider': AdProvider.admob.name,
            'impressions': 1,
            'revenueMicros': 100,
            'timestampMs': now,
          },
        ],
        anchor: now,
      );
      final previousRecords = prefs.getCohortOptimizerRecordsRaw();
      final previousAnchor = prefs.getCohortOptimizerClockAnchorRaw();
      AdPreferences.debugCohortRecordsWriteResult = false;

      await expectLater(
        optimizer.recordSession(
          provider: AdProvider.appLovin,
          impressions: 1,
          revenueMicros: 100,
        ),
        throwsStateError,
      );

      expect(prefs.getCohortOptimizerRecordsRaw(), previousRecords);
      expect(prefs.getCohortOptimizerClockAnchorRaw(), previousAnchor);
    },
  );

  test(
    'CohortOptimizer rolls records back when anchor write returns false',
    () async {
      final prefs = await AdPreferences.getInstance();
      final storage = _FakeSecureStorage();
      final optimizer = CohortOptimizer(prefs, storage: storage);
      final now = DateTime.now().millisecondsSinceEpoch;
      await _writeStateForTest(
        prefs,
        storage,
        records: [
          {
            'provider': AdProvider.admob.name,
            'impressions': 1,
            'revenueMicros': 100,
            'timestampMs': now,
          },
        ],
        anchor: now,
      );
      final previousRecords = prefs.getCohortOptimizerRecordsRaw();
      final previousAnchor = prefs.getCohortOptimizerClockAnchorRaw();
      AdPreferences.debugCohortAnchorWriteResult = false;

      await expectLater(
        optimizer.recordSession(
          provider: AdProvider.appLovin,
          impressions: 1,
          revenueMicros: 100,
        ),
        throwsStateError,
      );

      expect(prefs.getCohortOptimizerRecordsRaw(), previousRecords);
      expect(prefs.getCohortOptimizerClockAnchorRaw(), previousAnchor);
      expect(await optimizer.loadVerifiedRecords(), hasLength(1));
    },
  );

  test(
    'CohortOptimizer reports anchor and restore failures together',
    () async {
      final prefs = await AdPreferences.getInstance();
      final optimizer = CohortOptimizer(prefs, storage: _FakeSecureStorage());
      await optimizer.recordSession(
        provider: AdProvider.admob,
        impressions: 1,
        revenueMicros: 100,
      );
      AdPreferences.debugCohortAnchorWriteResult = false;
      AdPreferences.debugCohortRestoreWriteResult = false;

      await expectLater(
        optimizer.recordSession(
          provider: AdProvider.appLovin,
          impressions: 1,
          revenueMicros: 100,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('Clock anchor write failed'),
              contains('records restore returned false'),
            ),
          ),
        ),
      );
    },
  );

  test(
    'CohortOptimizer removes first records when anchor write fails',
    () async {
      final prefs = await AdPreferences.getInstance();
      final optimizer = CohortOptimizer(prefs, storage: _FakeSecureStorage());
      AdPreferences.debugCohortAnchorWriteResult = false;

      await expectLater(
        optimizer.recordSession(
          provider: AdProvider.admob,
          impressions: 1,
          revenueMicros: 100,
        ),
        throwsStateError,
      );

      expect(prefs.getCohortOptimizerRecordsRaw(), isNull);
      expect(prefs.getCohortOptimizerClockAnchorRaw(), isNull);
    },
  );

  test(
    'CohortOptimizer leaves previous signed records when persistence fails',
    () async {
      final prefs = await AdPreferences.getInstance();
      final storage = _FakeSecureStorage();
      final optimizer = CohortOptimizer(prefs, storage: storage);
      await optimizer.recordSession(
        provider: AdProvider.admob,
        impressions: 10,
        revenueMicros: 1000,
      );
      final previousRaw = prefs.getCohortOptimizerRecordsRaw();
      expect(previousRaw, isNotNull);

      AdPreferences.debugBeforeCohortWrite = () async {
        throw StateError('simulated persistence failure');
      };
      await expectLater(
        optimizer.recordSession(
          provider: AdProvider.appLovin,
          impressions: 1,
          revenueMicros: 5000,
        ),
        throwsStateError,
      );

      expect(prefs.getCohortOptimizerRecordsRaw(), previousRaw);
      expect(await optimizer.loadVerifiedRecords(), hasLength(1));
    },
  );

  test(
    'CohortOptimizer persistence failure seam is ignored in release mode',
    () async {
      final prefs = await AdPreferences.getInstance();
      final storage = _FakeSecureStorage();
      final optimizer = CohortOptimizer(prefs, storage: storage);
      var hookCalls = 0;
      AdPreferences.debugBeforeCohortWrite = () async {
        hookCalls++;
        throw StateError('should not run in simulated release mode');
      };
      AdPreferences.debugSimulateReleaseModeForTestSeams = true;
      addTearDown(() {
        AdPreferences.debugSimulateReleaseModeForTestSeams = false;
      });

      await optimizer.recordSession(
        provider: AdProvider.admob,
        impressions: 1,
        revenueMicros: 100,
      );

      expect(hookCalls, 0);
      expect(await optimizer.loadVerifiedRecords(), hasLength(1));
    },
  );

  test(
    'CohortOptimizer ignores clock seam in simulated release mode',
    () async {
      final prefs = await AdPreferences.getInstance();
      final optimizer = CohortOptimizer(prefs, storage: _FakeSecureStorage());
      CohortOptimizer.debugNowMs = () => 1;
      CohortOptimizer.debugSimulateReleaseMode = true;

      await optimizer.recordSession(
        provider: AdProvider.admob,
        impressions: 1,
        revenueMicros: 100,
      );

      final records = await optimizer.loadVerifiedRecords();
      expect(records.single.timestampMs, greaterThan(1));
    },
  );

  test(
    'CohortOptimizer ignores tampered records and falls back to empty',
    () async {
      final prefs = await AdPreferences.getInstance();
      final storage = _FakeSecureStorage();
      final optimizer = CohortOptimizer(
        prefs,
        storage: storage,
        minSessionsPerProvider: 2,
      );

      await optimizer.recordSession(
        provider: AdProvider.admob,
        impressions: 10,
        revenueMicros: 10000,
      );

      // Tamper with payload in SharedPreferences directly
      final raw = prefs.getCohortOptimizerRecordsRaw();
      expect(raw, isNotNull);
      final bundle = jsonDecode(raw!) as Map<String, dynamic>;
      bundle['payloadJson'] =
          '[{"provider":"admob","impressions":9999,"revenueMicros":9999999,"timestampMs":0}]';
      await prefs.setCohortOptimizerRecordsRaw(jsonEncode(bundle));

      // Tampered payload fails Ed25519 verification
      final records = await optimizer.loadVerifiedRecords();
      expect(records, isEmpty);

      final recommendation = await optimizer.recommendedProviderForNextInit();
      expect(recommendation, isNull);
    },
  );
}
