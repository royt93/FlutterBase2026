// T293 points 3 and 4 — invalid-traffic history that has to survive a process
// restart. A restart is simulated by `resetForReinit()` (what destroy() runs)
// followed by a fresh `AdSafetyConfig.init`, with the store held in memory.
//
// Point 3: `_lastViolationTimestamp` was never persisted, so the 24 h halving
// the code promises never ran across restarts and the escalation count only
// ever grew.
// Point 4: the active pause lived only in RAM, so force-stop + relaunch (or a
// destroy() + initialize()) cleared an invalid-traffic pause.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/core/safety_state_store.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MemoryStore extends SafetyStateStore {
  _MemoryStore() : super();
  String? raw;
  bool failReads = false;
  bool failWrites = false;

  @override
  Future<String?> readRaw() async {
    if (failReads) throw Exception('keystore read failed');
    return raw;
  }

  @override
  Future<void> writeRaw(String json) async {
    if (failWrites) throw Exception('keystore write failed');
    raw = json;
  }

  @override
  Future<void> deleteRaw() async => raw = null;
}

class _GatedStore extends SafetyStateStore {
  _GatedStore(this._gate);
  final Future<void> _gate;
  String? raw;
  @override
  Future<String?> readRaw() async => raw;
  @override
  Future<void> writeRaw(String json) async {
    await _gate;
    raw = json;
  }

  @override
  Future<void> deleteRaw() async => raw = null;
}

class _HangingReadStore extends SafetyStateStore {
  @override
  Future<String?> readRaw() => Completer<String?>().future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AdPreferences prefs;
  late _MemoryStore store;

  Future<void> restart() async {
    AdSafetyConfig.resetForReinit(); // destroy()
    await AdSafetyConfig.init(prefs,
        params: AdSafetyParams.debug, safetyStateStore: store);
  }

  void tripPause() {
    for (var i = 0; i <= AdSafetyParams.debug.maxClicksPerMinute; i++) {
      AdSafetyConfig.recordAdClick();
    }
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AdPreferences.resetForTest();
    prefs = await AdPreferences.getInstance();
    store = _MemoryStore();
    await AdSafetyConfig.init(prefs,
        params: AdSafetyParams.debug, safetyStateStore: store);
    AdSafetyConfig.resetForReinit();
  });

  test('point 3: the violation history decays after a restart', () async {
    tripPause();
    final tripped = AdSafetyConfig.getStatusSnapshot().suspiciousViolationCount;
    expect(tripped, greaterThan(0), reason: 'precondition: a violation landed');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(store.raw, isNotNull, reason: 'the violation time must be stored');

    // Seven days later (no violation since), in a new process.
    store.raw = store.raw!.replaceFirstMapped(
      RegExp(r'"lastViolationAtMs":\d+'),
      (_) => '"lastViolationAtMs":'
          '${DateTime.now().subtract(const Duration(days: 7)).millisecondsSinceEpoch}',
    );
    await restart();

    expect(AdSafetyConfig.getStatusSnapshot().suspiciousViolationCount,
        lessThan(tripped),
        reason: 'seven quiet days must have halved the count several times '
            'over, not left it at the value it had a week ago');
  });

  test('point 4: an active pause survives a restart', () async {
    tripPause();
    expect(AdSafetyConfig.isInvalidTrafficPauseActive, isTrue,
        reason: 'precondition');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await restart();

    expect(AdSafetyConfig.isInvalidTrafficPauseActive, isTrue,
        reason: 'force-stop + relaunch must not clear an invalid-traffic '
            'pause: it protects the AdMob account, not the user pacing');
  });

  test('point 4: a stored pause is capped at 24 h from now', () async {
    store.raw = '{"violationCount":3,"lastViolationAtMs":'
        '${DateTime.now().millisecondsSinceEpoch},"pauseUntilMs":'
        '${DateTime.now().add(const Duration(days: 400)).millisecondsSinceEpoch}}';
    await restart();

    expect(AdSafetyConfig.isInvalidTrafficPauseActive, isTrue);
    final status = AdSafetyConfig.getStatusSnapshot();
    expect(status.isSuspended, isTrue);
    // A clock that jumped far ahead must not park the SDK for a year.
    AdSafetyConfig.debugExpireSuspiciousPause();
    expect(AdSafetyConfig.isInvalidTrafficPauseActive, isFalse);
  });

  test('a failing keystore is fail-open: no state, no throw', () async {
    store.failReads = true;
    store.failWrites = true;
    await restart();
    tripPause(); // must not throw even though every write fails
    expect(AdSafetyConfig.isInvalidTrafficPauseActive, isTrue,
        reason: 'the in-memory pause still works when persistence fails');
  });

  test('a corrupt stored record is ignored', () async {
    store.raw = 'not json at all';
    await restart();
    expect(AdSafetyConfig.isInvalidTrafficPauseActive, isFalse);
  });

  test('the host-facing session reset keeps the stored pause', () async {
    tripPause();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    AdSafetyConfig.resetSessionCounters();
    expect(store.raw, isNotNull,
        reason: 'a host clearing session counters must not erase the pause');
  });

  // The record is anti-abuse data guarding the AdMob account, so it follows the
  // entitlement data (and the iOS first-install flag): the DEFAULT erasure scope
  // keeps it, or a host "clear my data" button would also clear an
  // invalid-traffic pause (the point-4 hole). Only the explicit
  // allIncludingEntitlements scope erases it.
  group('clearSdkData', () {
    Future<void> trip() async {
      AdSafetyConfig.resetForReinit();
      await AdSafetyConfig.init(prefs,
          params: AdSafetyParams.debug, safetyStateStore: store);
      tripPause();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(store.raw, isNotNull, reason: 'precondition: a record is stored');
    }

    test('the default scope keeps the stored pause', () async {
      await trip();
      await AdManager().clearSdkData();
      expect(store.raw, isNotNull);
    });

    test('allIncludingEntitlements erases it', () async {
      await trip();
      await AdManager().clearSdkData(
        scope: SdkDataErasureScope.allIncludingEntitlements,
        confirmedEntitlementErasure: true,
      );
      expect(store.raw, isNull,
          reason: 'an explicit full erasure must not leave the record behind '
              '(iOS Keychain survives uninstall)');
    });
  });

  // Review of the first version.
  test('erase cannot be undone by a save that was already queued', () async {
    final gate = Completer<void>();
    final slow = _GatedStore(gate.future);
    // A save is in flight (its write is parked), then a full erasure arrives.
    final saving = slow.save(lastViolationAtMs: 1, pauseUntilMs: 2);
    final erasing = slow.erase();
    gate.complete();
    await Future.wait([saving, erasing]);
    expect(slow.raw, isNull,
        reason: 'the erase was issued after the save, so the record must not '
            'reappear when the parked write finally lands');
  });

  test('a release start-up does not hang on a Keystore that never answers',
      () async {
    final stuck = _HangingReadStore();
    await AdSafetyConfig.init(prefs,
            params: AdSafetyParams.debug,
            isRelease: true,
            safetyStateStore: stuck)
        .timeout(const Duration(seconds: 6));
  });

  test('a full erasure also clears the in-memory pause', () async {
    tripPause();
    expect(AdSafetyConfig.isInvalidTrafficPauseActive, isTrue);
    await AdManager().clearSdkData(
      scope: SdkDataErasureScope.allIncludingEntitlements,
      confirmedEntitlementErasure: true,
    );
    expect(AdSafetyConfig.isInvalidTrafficPauseActive, isFalse,
        reason: 'otherwise the next violation rewrites the erased record');
  });
}
