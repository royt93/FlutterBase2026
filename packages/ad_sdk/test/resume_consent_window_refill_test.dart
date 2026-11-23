// A fullscreen load skipped while the resume consent re-check holds the gate
// shut must be retried once the gate reopens. Without this the slot stays idle
// until the 5-minute poll: an interstitial closed just as the app resumes is
// not refilled, because its own reload runs inside that window.

import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/core/iab_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mobile_ads/src/ump/user_messaging_codec.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

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
          return Future.value(3);
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
    'a load skipped while the resume re-check holds the gate is retried',
    () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData({
            'IABTCF_gdprApplies': 1,
            'IABTCF_PurposeConsents': '1011000000',
          });
      IabStorage.debugResetForTest();
      await AdManager().requestUmpConsent();

      final entered = Completer<void>();
      final releaseRead = Completer<void>();
      final snapshot = SharedPreferencesAsync();
      final adapter = _RecordingAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = const AdConfig(
        provider: AdProvider.admob,
        admob: AdMobConfig(bannerId: 'b', interstitialId: 'i', appOpenId: 'a'),
        smartPreloadEnabled: false,
      );
      AdManager().debugCanRequestAds = true;
      AdManager().debugConnectivityReady = false;
      AdManager().debugConnectivityChanged(true);
      addTearDown(() {
        AdManager().debugSetAdapter(null);
        AdManager().debugConfig = null;
        IabStorage.debugOpenOverride = null;
        if (!releaseRead.isCompleted) releaseRead.complete();
      });

      IabStorage.debugOpenOverride = () async {
        if (!entered.isCompleted) entered.complete();
        await releaseRead.future;
        return snapshot;
      };
      adapter.calls.clear();

      AdManager().didChangeAppLifecycleState(AppLifecycleState.resumed);
      await entered.future.timeout(const Duration(seconds: 1));
      expect(
        AdManager().canRequestAds,
        isFalse,
        reason: 'precondition: the re-check holds the gate shut',
      );

      // The interstitial the user just closed asks to reload inside the window.
      await AdManager().loadInterstitial();
      expect(
        adapter.calls.contains('loadInterstitial'),
        isFalse,
        reason: 'precondition: skipped because the gate is closed',
      );

      releaseRead.complete();
      await pumpEventQueue(times: 40);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(
        AdManager().canRequestAds,
        isTrue,
        reason: 'the gate reopens once the re-check finishes',
      );
      expect(
        adapter.calls.contains('loadInterstitial'),
        isTrue,
        reason:
            'the skipped fullscreen load must be retried on reopen, not '
            'left idle until the 5-minute poll',
      );
    },
  );
}
