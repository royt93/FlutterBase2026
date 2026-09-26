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
  }) async =>
      _store[key];

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AdPreferences.resetForTest();
  });

  test('CohortOptimizer returns null when sessions count is below threshold', () async {
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
  });

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

  test('CohortOptimizer ignores tampered records and falls back to empty', () async {
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
  });
}
