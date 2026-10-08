// Round-73 audit — VipManager's expiry is a Dart Timer. A Timer does not
// advance while the device is suspended, so a VIP window that ended during
// sleep stayed "active" (ads suppressed) until the timer finally fired,
// roughly the sleep duration late. Resume must re-evaluate expiry.
//
// The timer is simulated as suspended with a dead Timer from a custom zone,
// so no production test seam is needed.

import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_admob_sdk/src/vip/_vip_entries_store.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeStore extends VipEntriesStore {
  _FakeStore(super.prefs);
  String? _raw;
  @override
  Future<String?> getRaw() async => _raw;
  @override
  Future<void> setRaw(String json) async => _raw = json;
}

/// A timer that never fires — what a suspended device's timer looks like.
class _DeadTimer implements Timer {
  @override
  void cancel() {}
  @override
  bool get isActive => false;
  @override
  int get tick => 0;
}

Future<T> _withSuspendedTimers<T>(Future<T> Function() body) => runZoned(
      body,
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, f) => _DeadTimer(),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AdPreferences prefs;
  late _FakeStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AdPreferences.resetForTest();
    prefs = await AdPreferences.getInstance();
    store = _FakeStore(prefs);
  });

  Future<VipManager> grant(Duration d, {String key = 'K'}) async {
    final mgr = VipManager(prefs, vipEntriesStore: store);
    await mgr.load();
    addTearDown(mgr.dispose);
    await _withSuspendedTimers(() => mgr.addVip(key: key, duration: d));
    return mgr;
  }

  // ── unit ──────────────────────────────────────────────────────────────────
  group('VipManager.resyncSessionClock re-evaluates expiry', () {
    test('control: without a resume, a suspended timer leaves VIP active',
        () async {
      final mgr = await grant(const Duration(milliseconds: 150));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(mgr.isActive, isTrue,
          reason: 'sanity — this IS the bug window: expired but still active');
    });

    test('resume after the window ended flips VIP to inactive', () async {
      final mgr = await grant(const Duration(milliseconds: 150));
      await Future<void>.delayed(const Duration(milliseconds: 300));

      mgr.resyncSessionClock();

      expect(mgr.isActive, isFalse);
      expect(mgr.activeListenable.value, isFalse);
    });

    test('resume while the window is still running keeps VIP active',
        () async {
      final mgr = await grant(const Duration(hours: 1));
      mgr.resyncSessionClock();
      expect(mgr.isActive, isTrue);
    });

    test('with two entries only the expired one is dropped', () async {
      final mgr = await grant(const Duration(milliseconds: 150), key: 'SHORT');
      await _withSuspendedTimers(
          () => mgr.addVip(key: 'LONG', duration: const Duration(hours: 1)));
      await Future<void>.delayed(const Duration(milliseconds: 300));

      mgr.resyncSessionClock();

      expect(mgr.isActive, isTrue);
      expect(mgr.entries.map((e) => e.key), ['LONG']);
    });

    test('resume with no entries and after dispose does not throw', () async {
      final mgr = VipManager(prefs, vipEntriesStore: store);
      await mgr.load();
      mgr.resyncSessionClock();
      mgr.dispose();
      mgr.resyncSessionClock();
    });

    test('a listener is told when expiry is noticed on resume', () async {
      final mgr = await grant(const Duration(milliseconds: 150));
      final seen = <bool>[];
      mgr.activeListenable.addListener(() => seen.add(mgr.isActive));
      await Future<void>.delayed(const Duration(milliseconds: 300));

      mgr.resyncSessionClock();

      expect(seen, [false]);
    });
  });

  // ── manager wiring: a real lifecycle event reaches it ────────────────────
  group('AdManager lifecycle resume', () {
    test('didChangeAppLifecycleState(resumed) ends an expired VIP', () async {
      final mgr = await grant(const Duration(milliseconds: 150));
      AdManager().debugVipManager = mgr;
      AdManager().debugConfig = const AdConfig(
        provider: AdProvider.admob,
        admob: AdMobConfig(bannerId: 'b', interstitialId: 'i', appOpenId: 'a'),
      ); // isInitialised needs config AND adapter, else the handler returns
      AdManager().debugSetAdapter(FakeAdProviderAdapter());
      addTearDown(() {
        AdManager().debugVipManager = null;
        AdManager().debugSetAdapter(null);
        AdManager().debugConfig = null;
      });
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(AdManager().isVIPMember(), isTrue, reason: 'sanity — stale');

      AdManager().didChangeAppLifecycleState(AppLifecycleState.resumed);

      expect(AdManager().isVIPMember(), isFalse);
    });
  });
}
