import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/adapters/admob_adapter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mobile_ads/src/ad_instance_manager.dart'
    show AdMessageCodec;
import 'package:integration_test/integration_test.dart';

const _config = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'ca-app-pub-3940256099942544/6300978111',
    interstitialId: 'ca-app-pub-3940256099942544/1033173712',
    appOpenId: 'ca-app-pub-3940256099942544/9257395921',
    rewardedId: 'ca-app-pub-3940256099942544/5224354917',
  ),
  autoRequestUmpConsent: false,
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('banner size lookup race respects timeout and consent gate',
      (tester) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channelName = 'plugins.flutter.io/google_mobile_ads';
    final codec = StandardMethodCodec(AdMessageCodec());
    final adaptiveReplies = <Completer<Object?>>[];
    final calls = <String>[];

    messenger.setMockMessageHandler(channelName, (message) async {
      final call = codec.decodeMethodCall(message!);
      calls.add(call.method);
      if (call.method == 'AdSize#getAnchoredAdaptiveBannerAdSize' &&
          adaptiveReplies.length < 2) {
        final reply = Completer<Object?>();
        adaptiveReplies.add(reply);
        return codec.encodeSuccessEnvelope(await reply.future);
      }
      return messenger.delegate.send(channelName, message);
    });
    addTearDown(() => messenger.setMockMessageHandler(channelName, null));

    final adapter = AdMobAdapter();
    addTearDown(() async {
      await adapter.dispose();
      messenger.setMockMessageHandler(channelName, null);
    });
    expect(await adapter.initialize(_config), isTrue);
    var gateOpen = true;
    adapter.canReload = () => gateOpen;

    final timedOutLoad = adapter.loadBannerIfNeeded('timeout', 360);
    for (var i = 0; i < 100 && adaptiveReplies.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(adaptiveReplies, hasLength(1));
    expect(adapter.bannerSlot('timeout').isLoading, isTrue);
    adapter.bannerSlot('timeout').debugFireLoadWatchdogNow();
    adaptiveReplies.single.complete(50);
    await timedOutLoad;
    expect(calls.where((method) => method == 'loadBannerAd'), isEmpty);
    expect(adapter.bannerSlot('timeout').value, AdSlotState.cooldown);

    final gatedLoad = adapter.loadBannerIfNeeded('gate', 360);
    for (var i = 0; i < 100 && adaptiveReplies.length < 2; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(adaptiveReplies, hasLength(2));
    gateOpen = false;
    adaptiveReplies.last.complete(50);
    await gatedLoad;
    expect(calls.where((method) => method == 'loadBannerAd'), isEmpty);
    expect(adapter.bannerSlot('gate').value, AdSlotState.cooldown);
    expect(adapter.banner('gate').needsRecovery, isTrue);

    gateOpen = true;
    adapter.recoverInlineAdsAfterReconnect();
    for (var i = 0; i < 150 &&
        calls.where((method) => method == 'loadBannerAd').length < 2; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(calls.where((method) => method == 'loadBannerAd'), hasLength(2),
        reason: 'reconnect recovery retries both slots carrying recovery debt');
    expect(tester.takeException(), isNull);
  });
}
