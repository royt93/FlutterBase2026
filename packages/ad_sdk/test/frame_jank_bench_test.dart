import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

const _config = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'ca-app-pub-3940256099942544/6300978111',
    interstitialId: 'ca-app-pub-3940256099942544/1033173712',
    appOpenId: 'ca-app-pub-3940256099942544/9257395921',
    rewardedId: 'ca-app-pub-3940256099942544/5224354917',
    mrecId: 'ca-app-pub-3940256099942544/2247696110',
  ),
);

void main() {
  testWidgets(
    'repeated ad container rebuilds render within reasonable frame thresholds',
    (tester) async {
      final adapter = FakeAdProviderAdapter();
      AdManager().debugConfig = _config;
      AdManager().debugSetAdapter(adapter);
      AdManager().debugCanRequestAds = true;
      addTearDown(() {
        AdManager().debugSetAdapter(null);
        AdManager().debugConfig = null;
      });

      final timings = <FrameTiming>[];
      void onTimings(List<FrameTiming> batch) => timings.addAll(batch);
      SchedulerBinding.instance.addTimingsCallback(onTimings);
      addTearDown(
        () => SchedulerBinding.instance.removeTimingsCallback(onTimings),
      );

      final navKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navKey,
          navigatorObservers: [AdScreenRouteLogger()],
          home: const Scaffold(body: Text('root')),
        ),
      );
      await tester.pumpAndSettle();

      // Thực hiện 20 lần chuyển đổi mở màn hình chứa banner và đóng
      for (var i = 0; i < 20; i++) {
        navKey.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: BannerAdWidget()),
          ),
        );
        await tester.pumpAndSettle();
        navKey.currentState!.pop();
        await tester.pumpAndSettle();
      }

      expect(find.text('root'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
