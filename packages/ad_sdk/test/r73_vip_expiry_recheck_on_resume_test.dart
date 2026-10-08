// Round-73 audit — VipManager's expiry is a Dart Timer. A Timer does not
// advance while the device is suspended, so a VIP window that ended during
// sleep stayed "active" (ads suppressed) until the timer finally fired,
// roughly the sleep duration late. Expiry is re-evaluated on resume.
//
// Regression follow-up:
//   1. Cancelling old timer before rescheduling (no orphaned timers).
//   2. Re-evaluating VIP expiry AFTER resume consent re-check completes,
//      so an expired VIP does not fire ad preloads under stale consent.

import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/core/iab_storage.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_admob_sdk/src/vip/_vip_entries_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mobile_ads/src/ump/user_messaging_codec.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class _FakeStore extends VipEntriesStore {
  _FakeStore(super.prefs);
  String? _raw;
  @override
  Future<String?> getRaw() async => _raw;
  @override
  Future<void> setRaw(String json) async => _raw = json;
}

class _DeadTimer implements Timer {
  @override
  void cancel() {}
  @override
  bool get isActive => false;
  @override
  int get tick => 0;
}

class _TrackingTimer implements Timer {
  _TrackingTimer(this.onCancel);
  final void Function() onCancel;
  bool _active = true;
  @override
  void cancel() {
    if (_active) {
      _active = false;
      onCancel();
    }
  }

  @override
  bool get isActive => _active;
  @override
  int get tick => 0;
}

Future<T> _withSuspendedTimers<T>(Future<T> Function() body) => runZoned(
      body,
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, f) => _DeadTimer(),
      ),
    );

class _RecordingAdapter implements AdProviderAdapter {
  final List<String> calls = [];
  final List<AdConsent> applied = [];

  @override
  final AdSlot appOpenSlot = AdSlot(type: AdSlotType.appOpen);
  @override
  final AdSlot interstitialSlot = AdSlot(type: AdSlotType.interstitial);
  @override
  final AdSlot rewardedSlot = AdSlot(type: AdSlotType.rewarded);
  @override
  final AdSlot rewardedInterstitialSlot =
      AdSlot(type: AdSlotType.rewardedInterstitial);

  @override
  String get tag => 'recording';

  @override
  void applyConsent(AdConsent consent) {
    applied.add(consent);
    calls.add('applyConsent');
  }

  @override
  Future<void> loadAppOpen({void Function(bool)? onAdLoaded}) async {
    calls.add('loadAppOpen');
  }

  @override
  Future<void> loadInterstitial() async {
    calls.add('loadInterstitial');
  }

  @override
  Future<void> loadRewarded() async {
    calls.add('loadRewarded');
  }

  @override
  Future<void> loadRewardedInterstitial() async {
    calls.add('loadRewardedInterstitial');
  }

  @override
  Future<void> preloadBanner(Object key) async {
    calls.add('preloadBanner');
  }

  @override
  Future<void> preloadMrec(Object key) async {
    calls.add('preloadMrec');
  }

  @override
  void onAppResumed() {
    calls.add('onAppResumed');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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

  // ── unit: VipManager.recheckExpiry ────────────────────────────────────────
  group('VipManager.recheckExpiry re-evaluates expiry', () {
    test('control: without recheck, a suspended timer leaves VIP active',
        () async {
      final mgr = await grant(const Duration(milliseconds: 150));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(mgr.isActive, isTrue,
          reason: 'sanity — this IS the bug window: expired but still active');
    });

    test('recheckExpiry after the window ended flips VIP to inactive',
        () async {
      final mgr = await grant(const Duration(milliseconds: 150));
      await Future<void>.delayed(const Duration(milliseconds: 300));

      mgr.recheckExpiry();

      expect(mgr.isActive, isFalse);
      expect(mgr.activeListenable.value, isFalse);
    });

    test('resyncSessionClock only re-anchors clock, does not recheck expiry early',
        () async {
      final mgr = await grant(const Duration(milliseconds: 150));
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // resyncSessionClock alone must NOT change active state synchronously
      // because lifecycle needs consent to be rechecked first.
      mgr.resyncSessionClock();

      expect(mgr.isActive, isTrue,
          reason: 'resyncSessionClock alone must not prematurely trigger expiry');
    });

    test('recheckExpiry while the window is still running keeps VIP active',
        () async {
      final mgr = await grant(const Duration(hours: 1));
      mgr.recheckExpiry();
      expect(mgr.isActive, isTrue);
    });

    test('with two entries only the expired one is dropped', () async {
      final mgr = await grant(const Duration(milliseconds: 150), key: 'SHORT');
      await _withSuspendedTimers(
          () => mgr.addVip(key: 'LONG', duration: const Duration(hours: 1)));
      await Future<void>.delayed(const Duration(milliseconds: 300));

      mgr.recheckExpiry();

      expect(mgr.isActive, isTrue);
      expect(mgr.entries.map((e) => e.key), ['LONG']);
    });

    test('recheckExpiry with no entries and after dispose does not throw',
        () async {
      final mgr = VipManager(prefs, vipEntriesStore: store);
      await mgr.load();
      mgr.recheckExpiry();
      mgr.dispose();
      mgr.recheckExpiry();
    });

    test('a listener is told when expiry is noticed on recheck', () async {
      final mgr = await grant(const Duration(milliseconds: 150));
      final seen = <bool>[];
      mgr.activeListenable.addListener(() => seen.add(mgr.isActive));
      await Future<void>.delayed(const Duration(milliseconds: 300));

      mgr.recheckExpiry();

      expect(seen, [false]);
    });
  });

  // ── regression 1: timer cancellation / no orphan timers ───────────────────
  group('Regression 1: timer cancellation prevents orphan timers', () {
    test(
        'calling recheckExpiry cancels the old active timer before scheduling a new one',
        () async {
      int timerCreations = 0;
      int timerCancellations = 0;

      await runZoned(() async {
        final mgr = VipManager(prefs, vipEntriesStore: store);
        await mgr.load();
        addTearDown(mgr.dispose);

        // Add 1 hour VIP -> schedules 1 timer
        await mgr.addVip(key: 'HOUR', duration: const Duration(hours: 1));
        final initialCreations = timerCreations;
        expect(initialCreations, greaterThan(0),
            reason: 'initial timer scheduled');

        // Recheck expiry 4 times (simulating 4 app resumes while VIP is still active)
        for (var i = 0; i < 4; i++) {
          mgr.recheckExpiry();
        }

        // Each recheckExpiry must cancel the previous running timer
        expect(timerCancellations, greaterThanOrEqualTo(4),
            reason: 'each recheck must cancel the preceding timer');

        // Dispose must cancel the final active timer
        mgr.dispose();
        expect(mgr.isDisposed, isTrue);
      }, zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, f) {
          timerCreations++;
          return _TrackingTimer(() {
            timerCancellations++;
          });
        },
      ));
    });
  });

  // ── regression 2: consent re-check order on resume ────────────────────────
  group('Regression 2: consent recheck precedes VIP expiry ad preloads', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const alChannel = MethodChannel('applovin_max');
    const gmaChannel = MethodChannel('plugins.flutter.io/google_mobile_ads');
    final umpChannel = MethodChannel(
      'plugins.flutter.io/google_mobile_ads/ump',
      StandardMethodCodec(UserMessagingCodec()),
    );

    setUp(() {
      messenger.setMockMethodCallHandler(alChannel, (call) async => null);
      messenger.setMockMethodCallHandler(gmaChannel, (call) async => null);
      messenger.setMockMethodCallHandler(umpChannel, (call) {
        switch (call.method) {
          case 'ConsentInformation#canRequestAds':
            return Future.value(true);
          case 'ConsentInformation#getConsentStatus':
            return Future.value(3); // obtained
          case 'ConsentInformation#isConsentFormAvailable':
            return Future.value(false);
          default:
            return Future.value(null);
        }
      });
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(alChannel, null);
      messenger.setMockMethodCallHandler(gmaChannel, null);
      messenger.setMockMethodCallHandler(umpChannel, null);
    });

    test(
        'when VIP expires on resume, consent recheck runs BEFORE ad preloads',
        () async {
      IabStorage.debugResetForTest();
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': '1011000000', // initially allowed
      });
      await AdManager().requestUmpConsent();
      expect(AdManager().consent.hasUserConsent, isTrue,
          reason: 'sanity: initially consented');

      final adapter = _RecordingAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = const AdConfig(
        provider: AdProvider.admob,
        admob: AdMobConfig(bannerId: 'b', interstitialId: 'i', appOpenId: 'a'),
      );

      final mgr = await grant(const Duration(milliseconds: 150));
      AdManager().debugVipManager = mgr;
      addTearDown(() {
        AdManager().debugVipManager = null;
        AdManager().debugSetAdapter(null);
        AdManager().debugConfig = null;
      });

      // Initially active VIP
      expect(AdManager().isVIPMember(), isTrue);

      // Device clock advances past VIP expiry while backgrounded
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // User also withdrew consent while backgrounded
      IabStorage.debugResetForTest();
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData({
        'IABTCF_gdprApplies': 1,
        'IABTCF_PurposeConsents': '1010000000', // purpose 4 refused
      });

      adapter.calls.clear();

      // App resumes
      AdManager().didChangeAppLifecycleState(AppLifecycleState.resumed);

      // Wait for resume consent recheck & VIP expiry to complete
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (!AdManager().isVIPMember()) break;
      }

      expect(AdManager().isVIPMember(), isFalse,
          reason: 'VIP expiry must have settled');

      // The key assertion: applyConsent (with the new withdrawn consent)
      // must appear BEFORE any ad preloads!
      final applyIdx = adapter.calls.indexOf('applyConsent');
      expect(applyIdx, greaterThanOrEqualTo(0),
          reason: 'consent withdrawal must be applied');

      // Any ad preload triggered by VIP expiry (_onVipActiveChanged) must run
      // AFTER or with the newly applied consent, never before!
      for (final call in ['loadInterstitial', 'loadAppOpen', 'preloadBanner']) {
        final loadIdx = adapter.calls.indexOf(call);
        if (loadIdx >= 0) {
          expect(applyIdx, lessThan(loadIdx),
              reason: '$call was called at $loadIdx before applyConsent at $applyIdx');
        }
      }
    });

    test(
        'when resume consent recheck times out, VIP expiry does not fire ad loads',
        () async {
      final adapter = _RecordingAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = const AdConfig(
        provider: AdProvider.admob,
        admob: AdMobConfig(bannerId: 'b', interstitialId: 'i', appOpenId: 'a'),
      );

      final mgr = await grant(const Duration(milliseconds: 150));
      AdManager().debugVipManager = mgr;
      addTearDown(() {
        AdManager().debugVipManager = null;
        AdManager().debugSetAdapter(null);
        AdManager().debugConfig = null;
        AdManager.debugResumeConsentRecheckTimeout = null;
      });

      await Future<void>.delayed(const Duration(milliseconds: 300));

      // Wedge consent recheck with a fast timeout
      AdManager.debugResumeConsentRecheckTimeout =
          const Duration(milliseconds: 10);
      messenger.setMockMethodCallHandler(umpChannel, (call) async {
        if (call.method == 'ConsentInformation#getConsentStatus') {
          await Completer<void>().future; // hangs forever
        }
        return null;
      });

      adapter.calls.clear();

      AdManager().didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Because consent recheck timed out, no ad preloads should have fired
      expect(adapter.calls.where((c) => c.startsWith('load') || c.startsWith('preload')),
          isEmpty,
          reason: 'no ad preloads allowed when consent recheck fails');
    });
  });
}
