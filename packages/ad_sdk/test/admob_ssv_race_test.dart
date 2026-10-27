import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/adapters/admob_adapter.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart' as gma;
import 'package:google_mobile_ads/src/ad_instance_manager.dart'
    show AdMessageCodec, instanceManager;
import 'package:shared_preferences/shared_preferences.dart';

const config = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'b',
    interstitialId: 'i',
    appOpenId: 'ao',
    rewardedId: 'r',
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final manager = AdManager();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final channel = MethodChannel(
    'plugins.flutter.io/google_mobile_ads',
    StandardMethodCodec(AdMessageCodec()),
  );
  final calls = <MethodCall>[];
  late Completer<void> ssv;
  late AdMobAdapter adapter;
  bool disposed = false;

  Future<void> event(
    int id,
    String name, [
    Map<String, dynamic> extra = const {},
  ]) async {
    await messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(
        MethodCall('onAdEvent', <dynamic, dynamic>{
          'adId': id,
          'eventName': name,
          ...extra,
        }),
      ),
      (_) {},
    );
  }

  List<int?> ids(String method) => calls
      .where((c) => c.method == method)
      .map((c) => c.arguments['adId'] as int?)
      .toList();

  Future<int> load() async {
    ssv =
        Completer<
          void
        >(); // Keep completion callbacks inside test's fake-async zone.
    await adapter.loadRewarded();
    final id = ids('loadRewardedAd').last!;
    await event(id, 'onAdLoaded', {'responseInfo': null});
    expect(adapter.rewardedSlot.isReady, isTrue);
    return id;
  }

  Future<void> finish(int id) async {
    await event(id, 'onAdShowedFullScreenContent');
    await event(id, 'onRewardedAdUserEarnedReward', {
      'rewardItem': gma.RewardItem(2, 'coins'),
    });
    await event(id, 'onRewardedAdUserEarnedReward', {
      'rewardItem': gma.RewardItem(2, 'coins'),
    });
    await event(id, 'onAdDismissedFullScreenContent');
  }

  setUp(() async {
    calls.clear();
    ssv = Completer<void>();
    disposed = false;
    SharedPreferences.setMockInitialValues({});
    AdPreferences.resetForTest();
    final prefs = await AdPreferences.getInstance();
    await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
    AdSafetyConfig.resetForReinit();
    Future<dynamic> handler(MethodCall call) async {
      calls.add(call);
      if (call.method == 'MobileAds#initialize') {
        return gma.InitializationStatus(const {});
      }
      if (call.method == 'setServerSideVerificationOptions') {
        await ssv.future;
        return null;
      }
      return null;
    }

    messenger.setMockMethodCallHandler(channel, handler);
    adapter = AdMobAdapter(); // RealGmaBridge; real plugin and _RewardedWrap.
    expect(await adapter.initialize(config), isTrue);
    adapter.canReload = () => false;
    manager.debugSetAdapter(adapter);
    manager.debugCanRequestAds = true;
    manager.debugConfig = config;
    manager.didChangeAppLifecycleState(AppLifecycleState.resumed);
    manager.debugResetGuardState();
  });

  tearDown(() async {
    manager.debugSetAdapter(null);
    manager.debugCanRequestAds = true;
    manager.debugConfig = null;
    if (!disposed) await adapter.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  testWidgets('exact SSV identifiers, one native show, earned callback once', (
    tester,
  ) async {
    final id = await load();
    final results = <RewardResult>[];
    final pending = adapter.showRewarded(
      onDone: results.add,
      ssvUserId: 'user-42',
      ssvCustomData: 'order=7&nonce=%2B',
    );
    await tester.pump();
    expect(ids('showAdWithoutView'), isEmpty);
    final request = calls.singleWhere(
      (c) => c.method == 'setServerSideVerificationOptions',
    );
    expect(request.arguments['adId'], id);
    final options =
        request.arguments['serverSideVerificationOptions']
            as gma.ServerSideVerificationOptions;
    expect(options.userId, 'user-42');
    expect(options.customData, 'order=7&nonce=%2B');
    ssv.complete();
    await tester.pump();
    await pending;
    expect(ids('showAdWithoutView'), [id]);
    await finish(id);
    expect(results, hasLength(1));
    expect(results.single.earned, isTrue);
    expect(results.single.shown, isTrue);
    expect(results.single.pendingServerConfirmation, isTrue);
    expect(adapter.rewardedSlot.value, AdSlotState.idle);
  });

  for (final scenario in ['ump-gate', 'paused', 'hidden']) {
    testWidgets(
      '$scenario while SSV options are pending blocks the native show',
      (tester) async {
        final id = await load();
        final earned = <bool>[];
        final pending = manager.showRewardedAd(
          onEarnedReward: earned.add,
          ssvUserId: 'u',
        );
        await tester.pump();
        expect(ids('setServerSideVerificationOptions'), [id]);
        expect(adapter.rewardedSlot.isShowing, isTrue);
        if (scenario == 'ump-gate') {
          manager.debugCanRequestAds = false;
          expect(manager.canRequestAds, isFalse);
        } else {
          manager.didChangeAppLifecycleState(
            scenario == 'paused'
                ? AppLifecycleState.paused
                : AppLifecycleState.hidden,
          );
        }
        ssv.complete();
        await tester.pump();
        await pending;
        expect(
          ids('showAdWithoutView'),
          isEmpty,
          reason: '$scenario changed while the SSV Future was pending',
        );
        expect(earned, [false]);
        expect(ids('disposeAd'), contains(id));
        await tester.pump(const Duration(seconds: 31)); // reload watchdog
      },
    );
  }

  testWidgets('a failing SSV setup in a live cycle still ends as skipped', (
    tester,
  ) async {
    final id = await load();
    final results = <RewardResult>[];
    final pending = adapter.showRewarded(onDone: results.add, ssvUserId: 'u');
    await tester.pump();
    ssv.completeError(PlatformException(code: 'SSV_FAILED'));
    await tester.pump();
    await pending;
    expect(ids('showAdWithoutView'), isEmpty);
    expect(results.single.earned, isFalse);
    expect(ids('disposeAd'), contains(id));
    expect(adapter.rewardedSlot.isShowing, isFalse);
  });

  testWidgets(
    'personalization withdrawal alone does not block an in-flight show',
    (tester) async {
      final id = await load();
      final results = <RewardResult>[];
      final pending = adapter.showRewarded(
        onDone: results.add,
        ssvCustomData: 'd',
      );
      await tester.pump();
      adapter.applyConsent(const AdConsent(hasUserConsent: false));
      await adapter.discardCachedFullscreenAds();
      expect(manager.canRequestAds, isTrue);
      ssv.complete();
      await tester.pump();
      await pending;
      expect(ids('showAdWithoutView'), [id]);
      await finish(id);
      expect(results, hasLength(1));
    },
  );

  testWidgets('adapter destroy during pending SSV never reaches native show', (
    tester,
  ) async {
    final id = await load();
    final earned = <bool>[];
    final pending = manager.showRewardedAd(
      onEarnedReward: earned.add,
      ssvUserId: 'u',
    );
    await tester.pump();
    await adapter.dispose();
    disposed = true;
    expect(ids('disposeAd'), contains(id));
    expect(instanceManager.adFor(id), isNull);
    expect(earned, [false]);
    ssv.complete();
    await tester.pump();
    await pending;
    expect(ids('showAdWithoutView'), isEmpty);
    expect(earned, [false]);
  });

  testWidgets('duplicate show while SSV pending is refused', (tester) async {
    final id = await load();
    final first = <bool>[];
    final second = <bool>[];
    final direct = <RewardResult>[];
    final pending = manager.showRewardedAd(
      onEarnedReward: first.add,
      ssvUserId: 'u',
    );
    await tester.pump();
    await manager.showRewardedAd(
      onEarnedReward: second.add,
      ssvUserId: 'other',
    );
    await adapter.showRewarded(onDone: direct.add, ssvUserId: 'third');
    expect(second, [false]);
    expect(direct.single.earned, isFalse);
    expect(ids('setServerSideVerificationOptions'), [id]);
    ssv.complete();
    await tester.pump();
    await pending;
    expect(ids('showAdWithoutView'), [id]);
    await finish(id);
    expect(first, [true]);
  });

  for (final rejects in [false, true]) {
    testWidgets(
      'watchdog replacement cycle survives old SSV ${rejects ? 'reject' : 'resolve'}',
      (tester) async {
        final oldId = await load();
        final oldSsv = ssv;
        final oldResults = <RewardResult>[];
        final oldPending = adapter.showRewarded(
          onDone: oldResults.add,
          ssvUserId: 'old',
        );
        await tester.pump();
        expect(ids('setServerSideVerificationOptions'), [oldId]);
        await tester.pump(AdSlot.showConfirmTimeout);
        expect(oldResults, hasLength(1));
        expect(oldResults.single.earned, isFalse);
        expect(ids('disposeAd'), contains(oldId));
        adapter.rewardedSlot.lastErrorAt = null;
        final newId = await load();
        final newResults = <RewardResult>[];
        await adapter.showRewarded(
          onDone: newResults.add,
        ); // New cycle has no SSV.
        await event(newId, 'onAdShowedFullScreenContent');
        expect(adapter.rewardedSlot.isShowing, isTrue);
        expect(adapter.rewardedSlot.displayConfirmed, isTrue);
        if (rejects) {
          oldSsv.completeError(
            PlatformException(code: 'SSV_FAILED', message: 'delayed rejection'),
          );
        } else {
          oldSsv.complete();
        }
        await tester.pump();
        await oldPending;
        final afterOld = adapter.rewardedSlot.value;
        expect(ids('showAdWithoutView'), [newId]);
        expect(
          newResults,
          isEmpty,
          reason: 'old result must not steal new callback',
        );
        await finish(newId);
        expect(oldResults, hasLength(1));
        expect(newResults, hasLength(1));
        expect(newResults.single.earned, isTrue);
        expect(
          afterOld,
          AdSlotState.showing,
          reason: 'old SSV catch must not mutate displayed replacement cycle',
        );
      },
    );
  }
}
