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
import 'package:google_mobile_ads/src/ad_instance_manager.dart'
    show AdMessageCodec;
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

base class _GatedConsentStore extends InMemorySharedPreferencesAsync {
  _GatedConsentStore() : super.empty();
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<String?> getString(
    String key,
    SharedPreferencesOptions options,
  ) async {
    if (key == IabStorage.keyUsPrivacy) {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    }
    return super.getString(key, options);
  }
}

class _RecordingAdapter extends FakeAdProviderAdapter {
  final List<String> calls = [];
  final List<AdConsent> applied = [];

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
    test(
      'control: without recheck, a suspended timer leaves VIP active',
      () async {
        final mgr = await grant(const Duration(milliseconds: 150));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(
          mgr.isActive,
          isTrue,
          reason: 'sanity — this IS the bug window: expired but still active',
        );
      },
    );

    test(
      'recheckExpiry after the window ended flips VIP to inactive',
      () async {
        final mgr = await grant(const Duration(milliseconds: 150));
        await Future<void>.delayed(const Duration(milliseconds: 300));

        mgr.recheckExpiry();

        expect(mgr.isActive, isFalse);
        expect(mgr.activeListenable.value, isFalse);
      },
    );

    test(
      'resyncSessionClock only re-anchors clock, does not recheck expiry early',
      () async {
        final mgr = await grant(const Duration(milliseconds: 150));
        await Future<void>.delayed(const Duration(milliseconds: 300));

        // resyncSessionClock alone must NOT change active state synchronously
        // because lifecycle needs consent to be rechecked first.
        mgr.resyncSessionClock();

        expect(
          mgr.isActive,
          isTrue,
          reason:
              'resyncSessionClock alone must not prematurely trigger expiry',
        );
      },
    );

    test(
      'recheckExpiry while the window is still running keeps VIP active',
      () async {
        final mgr = await grant(const Duration(hours: 1));
        mgr.recheckExpiry();
        expect(mgr.isActive, isTrue);
      },
    );

    test('with two entries only the expired one is dropped', () async {
      final mgr = await grant(const Duration(milliseconds: 150), key: 'SHORT');
      await _withSuspendedTimers(
        () => mgr.addVip(key: 'LONG', duration: const Duration(hours: 1)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));

      mgr.recheckExpiry();

      expect(mgr.isActive, isTrue);
      expect(mgr.entries.map((e) => e.key), ['LONG']);
    });

    test(
      'recheckExpiry with no entries and after dispose does not throw',
      () async {
        final mgr = VipManager(prefs, vipEntriesStore: store);
        await mgr.load();
        mgr.recheckExpiry();
        mgr.dispose();
        mgr.recheckExpiry();
      },
    );

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
        final timers = <_TrackingTimer>[];

        await runZoned(
          () async {
            final mgr = VipManager(prefs, vipEntriesStore: store);
            await mgr.load();
            addTearDown(mgr.dispose);

            // Add 1 hour VIP -> schedules 1 timer
            await mgr.addVip(key: 'HOUR', duration: const Duration(hours: 1));
            final initialCreations = timerCreations;
            expect(
              initialCreations,
              greaterThan(0),
              reason: 'initial timer scheduled',
            );

            // Recheck expiry 4 times (simulating 4 app resumes while VIP is still active)
            for (var i = 0; i < 4; i++) {
              mgr.recheckExpiry();
              expect(timers.where((timer) => timer.isActive), hasLength(1));
            }

            // Each recheckExpiry must cancel the previous running timer
            expect(
              timerCancellations,
              greaterThanOrEqualTo(4),
              reason: 'each recheck must cancel the preceding timer',
            );

            // Dispose must cancel the final active timer
            mgr.dispose();
            expect(mgr.isDisposed, isTrue);
            expect(timers.where((timer) => timer.isActive), isEmpty);
            expect(timerCancellations, timerCreations);
          },
          zoneSpecification: ZoneSpecification(
            createTimer: (self, parent, zone, duration, f) {
              timerCreations++;
              final timer = _TrackingTimer(() {
                timerCancellations++;
              });
              timers.add(timer);
              return timer;
            },
          ),
        );
      },
    );
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
        expect(
          AdManager().consent.hasUserConsent,
          isTrue,
          reason: 'sanity: initially consented',
        );

        final adapter = _RecordingAdapter();
        AdManager().debugSetAdapter(adapter);
        AdManager().debugConfig = const AdConfig(
          provider: AdProvider.admob,
          admob: AdMobConfig(
            bannerId: 'b',
            interstitialId: 'i',
            appOpenId: 'a',
          ),
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

        expect(
          AdManager().isVIPMember(),
          isFalse,
          reason: 'VIP expiry must have settled',
        );

        // The key assertion: applyConsent (with the new withdrawn consent)
        // must appear BEFORE any ad preloads!
        final applyIdx = adapter.calls.indexOf('applyConsent');
        expect(
          applyIdx,
          greaterThanOrEqualTo(0),
          reason: 'consent withdrawal must be applied',
        );

        // Any ad preload triggered by VIP expiry (_onVipActiveChanged) must run
        // AFTER or with the newly applied consent, never before!
        for (final call in [
          'loadInterstitial',
          'loadAppOpen',
          'preloadBanner',
        ]) {
          final loadIdx = adapter.calls.indexOf(call);
          if (loadIdx >= 0) {
            expect(
              applyIdx,
              lessThan(loadIdx),
              reason:
                  '$call was called at $loadIdx before applyConsent at $applyIdx',
            );
          }
        }
      },
    );

    test(
      'when resume consent recheck times out, VIP expiry does not fire ad loads',
      () async {
        SharedPreferencesAsyncPlatform.instance =
            InMemorySharedPreferencesAsync.withData({});
        IabStorage.debugResetForTest();
        final entered = Completer<void>();
        final releaseRead = Completer<void>();
        final snapshot = SharedPreferencesAsync();
        final adapter = _RecordingAdapter();
        AdManager().debugSetAdapter(adapter);
        AdManager().debugConfig = const AdConfig(
          provider: AdProvider.admob,
          admob: AdMobConfig(
            bannerId: 'b',
            interstitialId: 'i',
            appOpenId: 'a',
          ),
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

        AdManager().debugCanRequestAds = true;
        AdManager.debugResumeConsentRecheckTimeout = const Duration(
          milliseconds: 10,
        );
        IabStorage.debugOpenOverride = () async {
          if (!entered.isCompleted) entered.complete();
          await releaseRead.future;
          return snapshot;
        };
        addTearDown(() {
          IabStorage.debugOpenOverride = null;
          if (!releaseRead.isCompleted) releaseRead.complete();
        });

        adapter.calls.clear();

        AdManager().didChangeAppLifecycleState(AppLifecycleState.resumed);
        await entered.future.timeout(const Duration(seconds: 1));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(AdManager().canRequestAds, isFalse);
        expect(AdManager().canRequestAdsListenable.value, isFalse);
        expect(
          mgr.isActive,
          isTrue,
          reason: 'resume expiry was skipped on timeout',
        );
        expect(
          adapter.calls.where(
            (c) => c.startsWith('load') || c.startsWith('preload'),
          ),
          isEmpty,
          reason: 'no ad preloads allowed when consent recheck fails',
        );
        releaseRead.complete();
        await pumpEventQueue(times: 30);
        expect(
          AdManager().canRequestAds,
          isFalse,
          reason: 'a late timed-out read must not reopen the gate',
        );
        IabStorage.debugOpenOverride = null;
        AdManager.debugResumeConsentRecheckTimeout = null;
        AdManager().didChangeAppLifecycleState(AppLifecycleState.resumed);
        await pumpEventQueue(times: 30);
        expect(AdManager().canRequestAds, isTrue);
        expect(AdManager().canRequestAdsListenable.value, isTrue);
        expect(mgr.isActive, isFalse);
      },
    );

    test('resume notifier reopens while a host native write is still pending', () async {
      final manager = AdManager();
      manager.debugSetAdapter(_RecordingAdapter());
      manager.debugConfig = const AdConfig(provider: AdProvider.admob,
          admob: AdMobConfig(bannerId: 'b', interstitialId: 'i', appOpenId: 'a'));
      SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.withData({});
      IabStorage.debugResetForTest();
      manager.debugCanRequestAds = true;
      await manager.setConsent(const AdConsent(hasUserConsent: true));
      final writeEntered = Completer<void>();
      final releaseWrite = Completer<void>();
      messenger.setMockMethodCallHandler(gmaChannel, (call) async {
        if (call.method == 'MobileAds#updateRequestConfiguration') {
          if (!writeEntered.isCompleted) writeEntered.complete();
          await releaseWrite.future;
        }
        return null;
      });
      final pending = manager.setConsent(const AdConsent(hasUserConsent: false));
      addTearDown(() async {
        if (!releaseWrite.isCompleted) releaseWrite.complete();
        await pending;
        await manager.destroy();
      });
      await writeEntered.future.timeout(const Duration(seconds: 1));
      manager.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(manager.canRequestAdsListenable.value, isFalse);
      await pumpEventQueue(times: 30);
      expect(manager.canRequestAds, isFalse, reason: 'native write is still pending');
      expect(manager.canRequestAdsListenable.value, isTrue,
          reason: 'notifier retains raw UMP and resume-lock semantics');
      releaseWrite.complete();
      await pending;
      expect(manager.canRequestAds, isTrue);
      expect(manager.canRequestAdsListenable.value, isTrue);
    });

    test(
      'older resume cannot reopen gate while a newer check is pending',
      () async {
        final adapter = _RecordingAdapter();
        AdManager().debugSetAdapter(adapter);
        AdManager().debugConfig = const AdConfig(
          provider: AdProvider.admob,
          admob: AdMobConfig(
            bannerId: 'b',
            interstitialId: 'i',
            appOpenId: 'a',
          ),
        );
        AdManager().debugCanRequestAds = true;
        final first = _GatedConsentStore();
        final second = _GatedConsentStore();
        addTearDown(() async {
          IabStorage.debugOpenOverride = null;
          if (!first.release.isCompleted) first.release.complete();
          if (!second.release.isCompleted) second.release.complete();
          await pumpEventQueue(times: 30);
          await AdManager().destroy();
        });
        SharedPreferencesAsyncPlatform.instance = first;
        final firstPrefs = SharedPreferencesAsync();
        IabStorage.debugOpenOverride = () async => firstPrefs;
        AdManager().didChangeAppLifecycleState(AppLifecycleState.resumed);
        await first.entered.future.timeout(const Duration(seconds: 1));
        SharedPreferencesAsyncPlatform.instance = second;
        final secondPrefs = SharedPreferencesAsync();
        IabStorage.debugOpenOverride = () async => secondPrefs;
        AdManager().didChangeAppLifecycleState(AppLifecycleState.resumed);
        await second.entered.future.timeout(const Duration(seconds: 1));
        first.release.complete();
        await pumpEventQueue(times: 30);
        expect(AdManager().canRequestAds, isFalse);
        expect(adapter.calls, isEmpty);
        second.release.complete();
        await pumpEventQueue(times: 30);
        expect(AdManager().canRequestAds, isTrue);
        expect(adapter.calls.where((c) => c == 'onAppResumed'), hasLength(1));
      },
    );

    test('destroyed session cannot reopen a new session resume gate', () async {
      final old = _RecordingAdapter();
      const config = AdConfig(
        provider: AdProvider.admob,
        admob: AdMobConfig(bannerId: 'b', interstitialId: 'i', appOpenId: 'a'),
      );
      AdManager().debugSetAdapter(old);
      AdManager().debugConfig = config;
      AdManager().debugCanRequestAds = true;
      final first = _GatedConsentStore();
      final second = _GatedConsentStore();
      addTearDown(() async {
        IabStorage.debugOpenOverride = null;
        if (!first.release.isCompleted) first.release.complete();
        if (!second.release.isCompleted) second.release.complete();
        await pumpEventQueue(times: 30);
        await AdManager().destroy();
      });
      SharedPreferencesAsyncPlatform.instance = first;
      final firstPrefs = SharedPreferencesAsync();
      IabStorage.debugOpenOverride = () async => firstPrefs;
      AdManager().didChangeAppLifecycleState(AppLifecycleState.resumed);
      await first.entered.future.timeout(const Duration(seconds: 1));
      await AdManager().destroy();
      final current = _RecordingAdapter();
      AdManager().debugSetAdapter(current);
      AdManager().debugConfig = config;
      AdManager().debugCanRequestAds = true;
      SharedPreferencesAsyncPlatform.instance = second;
      final secondPrefs = SharedPreferencesAsync();
      IabStorage.debugOpenOverride = () async => secondPrefs;
      AdManager().didChangeAppLifecycleState(AppLifecycleState.resumed);
      await second.entered.future.timeout(const Duration(seconds: 1));
      first.release.complete();
      await pumpEventQueue(times: 30);
      expect(AdManager().canRequestAds, isFalse);
      expect(current.calls, isEmpty);
      second.release.complete();
      await pumpEventQueue(times: 30);
      expect(AdManager().canRequestAds, isTrue);
      expect(current.calls.where((c) => c == 'onAppResumed'), hasLength(1));
    });
  });

  test(
    'real VIP timer cannot request ads during a blocked resume consent read',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final gma = MethodChannel(
        'plugins.flutter.io/google_mobile_ads',
        StandardMethodCodec(AdMessageCodec()),
      );
      final ump = MethodChannel(
        'plugins.flutter.io/google_mobile_ads/ump',
        StandardMethodCodec(UserMessagingCodec()),
      );
      const al = MethodChannel('applovin_max');
      final entered = Completer<void>();
      final releaseRead = Completer<void>();
      messenger.setMockMethodCallHandler(al, (_) async => null);
      messenger.setMockMethodCallHandler(gma, (_) async => null);
      messenger.setMockMethodCallHandler(ump, (call) async {
        switch (call.method) {
          case 'ConsentInformation#getConsentStatus':
            return 3;
          case 'ConsentInformation#canRequestAds':
            return true;
          case 'ConsentInformation#isConsentFormAvailable':
            return false;
          default:
            return null;
        }
      });
      addTearDown(() async {
        if (!releaseRead.isCompleted) releaseRead.complete();
        IabStorage.debugOpenOverride = null;
        AdManager.debugAdapterFactory = null;
        await AdManager().destroy();
        ConsentManager.resetForTest();
        messenger.setMockMethodCallHandler(al, null);
        messenger.setMockMethodCallHandler(gma, null);
        messenger.setMockMethodCallHandler(ump, null);
      });
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData({});
      IabStorage.debugResetForTest();
      final adapter = _RecordingAdapter();
      AdManager.debugAdapterFactory = (_) => adapter;
      await AdManager().initialize(
        config: const AdConfig(
          provider: AdProvider.admob,
          admob: AdMobConfig(
            bannerId: 'b',
            interstitialId: 'i',
            appOpenId: 'a',
          ),
          firstInstallVipGrace: FirstInstallVipGrace.disabled,
          safety: AdSafetyParams(dryRun: true),
        ),
        onComplete: (_, _) {},
      );
      expect(AdManager().isInitialised, isTrue);
      AdManager().debugStopConnectivityWatch();
      AdManager().debugConnectivityReady = false;
      AdManager().debugConnectivityChanged(true);
      expect(AdManager().canRequestAds, isTrue);
      expect(
        adapter.canReload(),
        isTrue,
        reason: 'online and consented before the new resume check',
      );
      final vip = AdManager().vip!;
      await vip.revokeAll();
      await vip.addVip(
        key: 'TIMER',
        duration: const Duration(milliseconds: 300),
      );
      final snapshot = SharedPreferencesAsync();
      IabStorage.debugOpenOverride = () async {
        if (!entered.isCompleted) entered.complete();
        await releaseRead.future;
        return snapshot;
      };
      adapter.calls.clear();
      AdManager().didChangeAppLifecycleState(AppLifecycleState.resumed);
      await entered.future.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(
        vip.isActive,
        isFalse,
        reason: 'real expiry timer must have fired',
      );
      final earlyRequests = adapter.calls
          .where((c) => c.startsWith('load') || c.startsWith('preload'))
          .toList();
      releaseRead.complete();
      await pumpEventQueue(times: 30);
      expect(
        earlyRequests,
        isEmpty,
        reason: 'VIP expiry must not request while consent is unconfirmed',
      );
      expect(adapter.calls, containsAll([
        'loadAppOpen', 'loadInterstitial', 'loadRewarded', 'loadRewardedInterstitial'
      ]), reason: 'fullscreen slots suppressed by expiry must refill after unlock');
    },
  );
}
