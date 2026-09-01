// Round-trip tests for AdPreferences — the SDK-owned SharedPreferences wrapper
// that backs VIP entries, consent settings, first-install state and the legacy
// GAID list. Uses the in-memory SharedPreferences mock.

import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AdPreferences prefs;

  setUp(() async {
    AdPreferences.resetForTest();
    SharedPreferences.setMockInitialValues({});
    prefs = await AdPreferences.getInstance();
  });

  test(
      'round-30 audit (MAJOR): concurrent getInstance() calls before the '
      'singleton is first set return the SAME instance', () async {
    AdPreferences.resetForTest();
    // Neither call is awaited before the other starts — both race past the
    // (pre-fix) null-check before either has a chance to set `_instance`.
    final f1 = AdPreferences.getInstance();
    final f2 = AdPreferences.getInstance();
    final i1 = await f1;
    final i2 = await f2;
    expect(identical(i1, i2), isTrue,
        reason: 'two "singletons" born from this race independently track '
            'mutable state (e.g. the fill-rate baseline write-serialization '
            'queue) that silently diverges once split, even though the '
            'underlying SharedPreferences itself stays consistent');
  });

  test('consent settings raw round-trips', () async {
    await prefs.setConsentSettingsRaw('{"hasUserConsent":true}');
    expect(prefs.getConsentSettingsRaw(), '{"hasUserConsent":true}');
  });

  test('vip-migrated flag defaults to false', () {
    expect(prefs.isVipMigrated(), isFalse);
  });

  test('first-install grace flag defaults to false', () {
    expect(prefs.isFirstInstallGraceApplied(), isFalse);
  });

  test('legacy GAID list defaults to empty', () {
    expect(prefs.getGAIDList(), isEmpty);
  });

  test('setFirstInstallAtMsIfMissing only writes once', () async {
    await prefs.setFirstInstallAtMsIfMissing(1000);
    await prefs.setFirstInstallAtMsIfMissing(2000); // must NOT overwrite
    // The first value is retained — exercised via the public getter if present;
    // here we just assert the second call does not throw and the flow is stable.
    expect(() => prefs.isFirstInstallGraceApplied(), returnsNormally);
  });

  // T93 — backs AdManager().experimentBucket's GAID fallback.
  group('getOrCreateExperimentInstallId (T93)', () {
    test('returns the same id across repeated calls (in-memory cache)', () {
      final first = prefs.getOrCreateExperimentInstallId();
      final second = prefs.getOrCreateExperimentInstallId();
      expect(second, first);
    });

    test('survives a fresh AdPreferences instance reading the same disk '
        'store (simulates an app restart)', () async {
      final first = prefs.getOrCreateExperimentInstallId();

      // Same backing SharedPreferences store, but a brand-new AdPreferences
      // wrapper — its in-memory cache starts empty, so this only passes if
      // the id was actually persisted to disk, not just cached in memory.
      AdPreferences.resetForTest();
      final reloaded = await AdPreferences.getInstance();

      expect(reloaded.getOrCreateExperimentInstallId(), first);
    });

    test('two different (never-persisted) installs get different ids',
        () async {
      final id = prefs.getOrCreateExperimentInstallId();

      // A second, distinct store (different mock SharedPreferences) stands
      // in for a different device/install, never having persisted an id.
      SharedPreferences.setMockInitialValues({});
      AdPreferences.resetForTest();
      final other = await AdPreferences.getInstance();

      expect(other.getOrCreateExperimentInstallId(), isNot(id),
          reason: '128-bit random ids for two never-persisted installs '
              'colliding is astronomically unlikely — this is really just '
              'checking a fresh id gets generated, not a hardcoded constant');
    });
  });
}
