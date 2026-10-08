// Round-73 audit — widget layer. A mounted BannerAdWidget on the REAL AdMob
// adapter (fake GMA bridge) must:
//   1. keep its placement when a refresh no-fill arrives while an ad is live;
//   2. request again when the network returns after a first-load failure;
//   3. not request while the load gate is closed (VIP / consent), even on
//      reconnect.
// The native AdWidget platform view is not creatable under `flutter test`, so
// the assertions are on the widget's own state and the adapter's requests.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/adapters/admob_adapter.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
// ignore: implementation_imports
import 'package:google_mobile_ads/src/ad_instance_manager.dart'
    show AdMessageCodec;
import 'package:shared_preferences/shared_preferences.dart';

import 'admob_behavioral_test.dart' show FakeGmaBridge;

const _config = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'b',
    interstitialId: 'i',
    appOpenId: 'ao',
    mrecId: 'm',
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final channel = MethodChannel(
    'plugins.flutter.io/google_mobile_ads',
    StandardMethodCodec(AdMessageCodec()),
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  BannerAd dummy() => BannerAd(
        adUnitId: 'b',
        size: AdSize.banner,
        request: const AdRequest(),
        listener: const BannerAdListener(),
      );
  LoadAdError err() => LoadAdError(2, 'domain', 'network error', null);

  late AdMobAdapter adapter;

  Widget host() => MaterialApp(
        navigatorObservers: [adRouteObserver],
        home: const Scaffold(body: Center(child: BannerAdWidget())),
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AdPreferences.resetForTest();
    final prefs = await AdPreferences.getInstance();
    await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
    AdSafetyConfig.resetForReinit();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getAnchoredAdaptiveBannerAdSize') return AdSize.banner;
      return null;
    });
    adapter = AdMobAdapter(bridge: FakeGmaBridge());
    expect(await adapter.initialize(_config), isTrue);
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _config;
    AdManager().debugVipManager = null;
    AdManager().debugCanRequestAds = true;
    AdManager().debugResetBannerCooldown();
    AdManager().debugReconnectDebounce = const Duration(milliseconds: 10);
  });

  tearDown(() async {
    AdManager().debugSetAdapter(null);
    AdManager().debugConfig = null;
    AdManager().debugCanRequestAds = true;
    await adapter.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  // The adapter keys banners by the widget's State object.
  Object stateOf(WidgetTester t, [int index = 0]) =>
      t.stateList(find.byType(BannerAdWidget)).elementAt(index);

  testWidgets('mounting requests exactly one banner', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(BannerAdWidget), findsOneWidget);
    expect(adapter.bannerSlot(stateOf(tester)).isLoading, isTrue);
  });

  testWidgets('a refresh no-fill keeps the mounted placement intact',
      (tester) async {
    await tester.pumpWidget(host());
    await tester.pump(const Duration(milliseconds: 100));
    final key = stateOf(tester);
    adapter.debugBannerListenerFor(key)!.onAdLoaded!(dummy());
    await tester.pump();
    expect(adapter.banner(key).isLoaded.value, isTrue, reason: 'sanity');

    adapter.debugBannerListenerFor(key)!.onAdFailedToLoad!(dummy(), err());
    await tester.pump();

    expect(adapter.banner(key).isLoaded.value, isTrue);
    expect(adapter.banner(key).hasError.value, isFalse,
        reason: 'the widget must not collapse to its error/house-ad state');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a first-load failure shows the error state, then reconnect '
      'requests again', (tester) async {
    AdManager().debugConnectivityChanged(true);
    await tester.pumpWidget(host());
    await tester.pump(const Duration(milliseconds: 100));
    final key = stateOf(tester);
    final first = adapter.debugBannerListenerFor(key);
    first!.onAdFailedToLoad!(dummy(), err());
    await tester.pump();
    expect(adapter.banner(key).hasError.value, isTrue, reason: 'sanity');

    AdManager().debugConnectivityChanged(false);
    AdManager().debugConnectivityChanged(true);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(adapter.debugBannerListenerFor(key), isNot(same(first)),
        reason: 'a fresh request must have been made after the reconnect');
    expect(adapter.bannerSlot(key).isLoading, isTrue);
    expect(adapter.banner(key).hasError.value, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reconnect does not request while the load gate is closed',
      (tester) async {
    AdManager().debugConnectivityChanged(true);
    await tester.pumpWidget(host());
    await tester.pump(const Duration(milliseconds: 100));
    final key = stateOf(tester);
    final first = adapter.debugBannerListenerFor(key);
    first!.onAdFailedToLoad!(dummy(), err());
    await tester.pump();

    AdManager().debugCanRequestAds = false;
    adapter.canReload = () => false;
    AdManager().debugConnectivityChanged(false);
    AdManager().debugConnectivityChanged(true);
    await tester.pump(const Duration(milliseconds: 200));

    final after = adapter.debugBannerListenerFor(key);
    expect(after == null || identical(after, first), isTrue,
        reason: 'no NEW request listener may appear while the gate is closed');
    expect(adapter.bannerSlot(key).isLoading, isFalse,
        reason: 'a closed consent/VIP gate must still block the request');
  });

  testWidgets('two mounted banners recover independently', (tester) async {
    AdManager().debugConnectivityChanged(true);
    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [adRouteObserver],
      home: const Scaffold(
          body: Column(children: [BannerAdWidget(), BannerAdWidget()])),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    final keys = [stateOf(tester, 0), stateOf(tester, 1)];
    final before = {for (final k in keys) k: adapter.debugBannerListenerFor(k)};
    adapter.debugBannerListenerFor(keys[0])!.onAdFailedToLoad!(dummy(), err());
    adapter.debugBannerListenerFor(keys[1])!.onAdLoaded!(dummy());
    await tester.pump();

    AdManager().debugConnectivityChanged(false);
    AdManager().debugConnectivityChanged(true);
    await tester.pump(const Duration(milliseconds: 200));

    expect(adapter.debugBannerListenerFor(keys[0]),
        isNot(same(before[keys[0]])),
        reason: 'the failed one is requested again');
    expect(adapter.debugBannerListenerFor(keys[1]), same(before[keys[1]]),
        reason: 'the healthy one is left alone');
  });
}
