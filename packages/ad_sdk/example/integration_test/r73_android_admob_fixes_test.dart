// Real native loads; callback/timer seams drive errors that cannot be forced reliably.

import 'dart:async';

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/adapters/admob_adapter.dart';
import 'package:applovin_admob_sdk/src/core/iab_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:google_mobile_ads/src/ad_instance_manager.dart'
    show AdMessageCodec;
import 'package:integration_test/integration_test.dart';

Future<void> _waitForInit(WidgetTester tester) async {
  for (var i = 0; i < 180; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (AdManager().isInitialised) return;
  }
  fail('SDK must finish initialising on device');
}

class _DeadTimer implements Timer {
  @override
  void cancel() {}
  @override
  bool get isActive => false;
  @override
  int get tick => 0;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('setDoNotSell re-applies AdMob config WITH the test devices', (
    tester,
  ) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);
    await AdManager().vip?.revokeAll();

    // The Google Mobile Ads plugin cannot read its RequestConfiguration back on
    // Android, so the proof is the SDK's own record of what it just sent to the
    // native SDK, captured through the app's real log sink.
    int lastAppliedTestDevices() {
      final applied = RegExp(r'testDevices=(\d+)');
      for (final e in app.LogBuffer.instance.snapshot().reversed) {
        if (!e.message.contains('AdMob RequestConfiguration applied')) continue;
        return int.parse(applied.firstMatch(e.message)!.group(1)!);
      }
      return -1;
    }

    // Establish the baseline from a re-apply that is known to be complete.
    await AdManager().consentManager!.applyToProviders(
      config: AdManager().config,
    );
    final baseline = lastAppliedTestDevices();
    expect(
      baseline,
      greaterThan(0),
      reason: 'precondition: the QA fleet is applied natively',
    );

    await AdManager().setDoNotSell(true);
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      lastAppliedTestDevices(),
      baseline,
      reason: 'THE finding — a CCPA toggle used to send an EMPTY list',
    );

    await AdManager().setDoNotSell(false);
    await tester.pump(const Duration(milliseconds: 500));
    expect(lastAppliedTestDevices(), baseline);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'direct ConsentManager.set without config keeps AdMob test devices on native Android',
    (tester) async {
      app.main();
      await tester.pump();
      await _waitForInit(tester);
      await AdManager().vip?.revokeAll();

      int lastAppliedTestDevices() {
        final applied = RegExp(r'testDevices=(\d+)');
        for (final e in app.LogBuffer.instance.snapshot().reversed) {
          if (!e.message.contains('AdMob RequestConfiguration applied'))
            continue;
          return int.parse(applied.firstMatch(e.message)!.group(1)!);
        }
        return -1;
      }

      await AdManager().consentManager!.applyToProviders(
        config: AdManager().config,
      );
      final baseline = lastAppliedTestDevices();
      expect(baseline, greaterThan(0));

      final current = AdManager().consentManager!.current;
      await AdManager().consentManager!.set(current.copyWith(doNotSell: true));
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        lastAppliedTestDevices(),
        baseline,
        reason:
            'R75-02 fix: direct ConsentManager.set without config retains test devices',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('CCPA preserves TFUA in requests forwarded to native Android', (
    tester,
  ) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);
    final manager = AdManager();
    final originalConfig = manager.config!;
    final originalConsent = manager.consentManager!.current;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = 'plugins.flutter.io/google_mobile_ads';
    final codec = StandardMethodCodec(AdMessageCodec());
    final updates = <Map<dynamic, dynamic>>[];
    // Inspect outgoing payloads, but execute every call on the real plugin.
    messenger.setMockMessageHandler(channel, (message) async {
      final call = codec.decodeMethodCall(message!);
      final response = await messenger.delegate.send(channel, message);
      if (call.method == 'MobileAds#updateRequestConfiguration') {
        codec.decodeEnvelope(response!);
        updates.add(Map<dynamic, dynamic>.from(call.arguments as Map));
      }
      return response;
    });
    addTearDown(() async {
      messenger.setMockMessageHandler(channel, null);
      manager.debugConfig = originalConfig;
      await manager.consentManager!.set(
        originalConsent,
        config: originalConfig,
      );
    });

    for (final underAge in [true, false]) {
      final config = AdConfig(
        provider: originalConfig.provider,
        admob: originalConfig.admob,
        umpTagForUnderAgeOfConsent: underAge,
      );
      manager.debugConfig = config;
      await manager.consentManager!.applyToProviders(config: config);
      final expectedDevices = config.admob!.effectiveTestDeviceIds;
      for (final optOut in [true, false]) {
        updates.clear();
        await manager.setDoNotSell(optOut);
        expect(updates, isNotEmpty);
        for (final update in updates) {
          expect(
            update['tagForUnderAgeOfConsent'],
            underAge
                ? TagForUnderAgeOfConsent.yes
                : TagForUnderAgeOfConsent.unspecified,
          );
          expect(update['testDeviceIds'], containsAll(expectedDevices));
        }
      }
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('a VIP window that ended during sleep ends on resume', (
    tester,
  ) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);
    final vip = AdManager().vip!;
    await vip.revokeAll();

    // Timers that never fire — what a suspended device's timers look like.
    await runZoned(
      () => vip.addVip(
        key: 'R73_SLEEP',
        duration: const Duration(milliseconds: 400),
      ),
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, d, f) => _DeadTimer(),
      ),
    );
    expect(AdManager().isVIPMember(), isTrue, reason: 'sanity');
    await tester.pump(const Duration(milliseconds: 800));
    expect(
      AdManager().isVIPMember(),
      isTrue,
      reason: 'sanity — expired, but nothing has noticed yet',
    );

    WidgetsBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(AdManager().isVIPMember(), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'real VIP expiry waits for resume consent before native ad loads',
    (tester) async {
      app.main();
      await tester.pump();
      await _waitForInit(tester);
      final manager = AdManager();
      final vip = manager.vip!;
      final adapter = manager.adapter as AdMobAdapter;
      await vip.revokeAll();
      markCustomOverlayOnScreen(true);
      addTearDown(() => markCustomOverlayOnScreen(false));
      await manager.loadInterstitial();
      for (var i = 0; i < 120; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (![
          adapter.appOpenSlot,
          adapter.interstitialSlot,
          adapter.rewardedSlot,
          adapter.rewardedInterstitialSlot,
        ].any((slot) => slot.isLoading)) {
          break;
        }
      }
      expect(
        adapter.interstitialSlot.isReady,
        isTrue,
        reason: 'initial native interstitial must have filled',
      );
      await adapter.discardCachedFullscreenAds();
      expect(adapter.interstitialSlot.isIdle, isTrue);
      await vip.addVip(key: 'R73_GATE', duration: const Duration(seconds: 2));
      final entered = Completer<void>();
      final releaseRead = Completer<void>();
      final snapshot = SharedPreferencesAsync();
      IabStorage.debugOpenOverride = () async {
        if (!entered.isCompleted) entered.complete();
        await releaseRead.future;
        return snapshot;
      };
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = 'plugins.flutter.io/google_mobile_ads';
      final codec = StandardMethodCodec(AdMessageCodec());
      final loads = <String>[];
      messenger.setMockMessageHandler(channel, (message) async {
        final call = codec.decodeMethodCall(message!);
        if (call.method.startsWith('load') && call.method.endsWith('Ad')) {
          loads.add(call.method);
        }
        return messenger.delegate.send(channel, message);
      });
      addTearDown(() async {
        IabStorage.debugOpenOverride = null;
        if (!releaseRead.isCompleted) releaseRead.complete();
        messenger.setMockMessageHandler(channel, null);
        await vip.revokeVip('R73_GATE');
      });
      manager.didChangeAppLifecycleState(AppLifecycleState.resumed);
      for (var i = 0; i < 20 && !entered.isCompleted; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(
        entered.isCompleted,
        isTrue,
        reason: 'consent check must be pending',
      );
      await tester.pump(const Duration(seconds: 3));
      expect(vip.isActive, isFalse, reason: 'the real expiry timer must fire');
      expect(manager.canRequestAds, isFalse);
      expect(manager.canRequestAdsListenable.value, isFalse);
      expect(
        loads,
        isEmpty,
        reason: 'no native requests under unconfirmed consent',
      );
      releaseRead.complete();
      await tester.pump(const Duration(milliseconds: 500));
      expect(manager.canRequestAds, isTrue);
      expect(
        loads,
        isNotEmpty,
        reason: 'VIP-held fullscreen slots must refill',
      );
      expect(
        adapter.interstitialSlot.isLoading || adapter.interstitialSlot.isReady,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a failed fullscreen show reloads at once on the real adapter', (
    tester,
  ) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);
    await AdManager().vip?.revokeAll();
    await tester.pump(const Duration(milliseconds: 300));

    final adapter = AdManager().adapter as AdMobAdapter;
    await AdManager().loadInterstitial();
    for (var i = 0; i < 60 && !adapter.interstitialSlot.isReady; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(
      adapter.interstitialSlot.isReady,
      isTrue,
      reason: 'precondition: the initial request must finish successfully',
    );
    // Resetting a slot does not dispose its cached ad; use the adapter's API.
    await adapter.discardCachedFullscreenAds();
    expect(adapter.interstitialSlot.isIdle, isTrue);
    adapter.debugSimulateInterstitialShowAndDismiss((_) {}, dismissed: false);
    expect(adapter.interstitialSlot.isCooldown, isTrue, reason: 'sanity');

    await AdManager().loadInterstitial();
    expect(
      adapter.interstitialSlot.isLoading || adapter.interstitialSlot.isReady,
      isTrue,
      reason: 'the refill must start without waiting out backoff',
    );
    for (var i = 0; i < 60 && !adapter.interstitialSlot.isReady; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(
      adapter.interstitialSlot.isReady,
      isTrue,
      reason:
          'THE finding — the refill used to be refused for the backoff '
          'window and the slot stayed empty',
    );
    expect(tester.takeException(), isNull);
  });

  for (final mrec in [false, true]) {
    testWidgets(
      'refresh no-fill preserves a real ${mrec ? "MREC" : "banner"}',
      (tester) async {
        app.main();
        await tester.pump();
        await _waitForInit(tester);
        await AdManager().vip?.revokeAll();
        final tile = find.text(mrec ? 'MREC ad' : 'Banner ad');
        for (var i = 0; i < 40 && tile.evaluate().isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 500));
        }
        expect(tile, findsOneWidget);
        await tester.tap(tile);
        final widgets = find.byType(mrec ? MrecAdWidget : BannerAdWidget);
        for (var i = 0; i < 40 && widgets.evaluate().isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        final key = tester.stateList(widgets).first;
        final adapter = AdManager().adapter as AdMobAdapter;
        final slot = mrec ? adapter.mrecSlot(key) : adapter.bannerSlot(key);
        final listenables = mrec ? adapter.mrec(key) : adapter.banner(key);
        for (var i = 0; i < 120 && !slot.isReady; i++) {
          await tester.pump(const Duration(milliseconds: 500));
        }
        expect(
          slot.isReady,
          isTrue,
          reason: 'a real ad must fill before refresh',
        );
        await tester.pump();
        AdWidget view() {
          final container =
              (mrec
                      ? adapter.buildAdmobMrecView(key)
                      : adapter.buildAdmobBannerView(key))
                  as SizedBox;
          return container.child! as AdWidget;
        }

        final ad = view().ad as BannerAd;
        final listener = mrec
            ? adapter.debugMrecListenerFor(key)!
            : adapter.debugBannerListenerFor(key)!;
        listener.onAdFailedToLoad!(
          ad,
          LoadAdError(3, 'test', 'refresh no fill', null),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(slot.isReady, isTrue);
        expect(listenables.isLoaded.value, isTrue);
        expect(listenables.hasError.value, isFalse);
        expect(listenables.needsRecovery, isFalse);
        expect(view().ad, same(ad), reason: 'the native ad must remain cached');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'banner is requested again after a real network loss',
    (tester) async {
      app.main();
      await tester.pump();
      await _waitForInit(tester);
      await AdManager().vip?.revokeAll();
      await tester.pump(const Duration(milliseconds: 300));

      // 1. Really cut the network BEFORE opening the page.
      debugPrint('R73_NET_CUT_NOW');
      for (var i = 0; i < 240 && AdManager().isConnected; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(AdManager().isConnected, isFalse, reason: 'network must be cut');

      // 2. Offline, both the widget and the adapter refuse to even ask, so the
      //    failure would never reach the adapter. Make the SDK believe it is
      //    online (the plugin event is the only thing faked) so the request is
      //    really sent and really fails at the native layer.
      AdManager().debugConnectivityReady = false; // isConnected -> last-known
      AdManager().debugConnectivityChanged(true);
      final tile = find.text('Banner ad');
      for (var i = 0; i < 40 && tester.any(tile) == false; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      await tester.tap(tile);
      for (
        var i = 0;
        i < 40 && tester.any(find.byType(BannerAdWidget)) == false;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final adapter = AdManager().adapter!;
      final key = tester.stateList(find.byType(BannerAdWidget)).first;

      for (var i = 0; i < 160; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        if (adapter.banner(key).needsRecovery) break;
      }
      final failedInFlight = adapter.banner(key).needsRecovery;
      debugPrint('R73_NET_FAILED_IN_FLIGHT=$failedInFlight');
      expect(
        failedInFlight,
        isTrue,
        reason:
            'precondition: the request must fail natively with no '
            'network, otherwise this run proves nothing about recovery',
      );
      expect(adapter.bannerSlot(key).isReady, isFalse);

      // 3. Tell the SDK the truth again, then bring the network back: the real
      //    offline->online transition is what must trigger the recovery.
      AdManager().debugConnectivityChanged(false);
      // Hand isConnected back to the real plugin; its offline->online event is
      // what must now drive the recovery.
      AdManager().debugConnectivityReady = true;
      debugPrint('R73_NET_OFFLINE_VERIFIED: restore network now');
      for (var i = 0; i < 240 && !AdManager().isConnected; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(
        AdManager().isConnected,
        isTrue,
        reason: 'the real connectivity plugin must report the network back',
      );
      for (var i = 0; i < 120; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (adapter.bannerSlot(key).isReady) break;
      }
      expect(
        adapter.bannerSlot(key).isReady,
        isTrue,
        reason:
            'the banner must recover on its own after the network is '
            'back, without an app resume',
      );
      debugPrint('R73_NET_RECONNECT_VERIFIED');
    },
    skip: !const bool.fromEnvironment('RUN_REAL_NETWORK_TEST'),
  );
}
