import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

AdConfig _admobConfig() => const AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'ca-app-pub-3940256099942544/6300978111',
    interstitialId: 'ca-app-pub-3940256099942544/1033173712',
    appOpenId: 'ca-app-pub-3940256099942544/9257395921',
    rewardedId: 'ca-app-pub-3940256099942544/5224354917',
  ),
  autoRequestUmpConsent: false,
  safety: AdSafetyParams(dryRun: true),
  firstInstallVipGrace: FirstInstallVipGrace.disabled,
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    await AdManager().destroy();
  });

  testWidgets(
    'reconnect loads App Open first, then Interstitial, then Rewarded',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Text('home')));
      await tester.runAsync(() async {
        await AdManager().initialize(
          config: _admobConfig(),
          onComplete: (_, _) {},
        );
        AdManager().markSplashInactive();
        await Future<void>.delayed(const Duration(seconds: 6));

        final ad = AdManager().adapter!;
        final slots = {
          'appOpen': ad.appOpenSlot,
          'interstitial': ad.interstitialSlot,
          'rewarded': ad.rewardedSlot,
        };
        final clock = Stopwatch();
        final firstLoadingMs = <String, int>{};
        final listeners = <VoidCallback>[];
        slots.forEach((name, slot) {
          void onChange() {
            if (slot.isLoading && clock.isRunning) {
              firstLoadingMs.putIfAbsent(name, () => clock.elapsedMilliseconds);
            }
          }

          slot.state.addListener(onChange);
          listeners.add(() => slot.state.removeListener(onChange));
          slot.reset();
        });

        AdManager().debugConnectivityChanged(false);
        clock.start();
        AdManager().debugConnectivityChanged(true);
        await Future<void>.delayed(const Duration(seconds: 5));
        for (final remove in listeners) {
          remove();
        }
        // ignore: avoid_print
        print('T266 device first-loading offsets (ms): $firstLoadingMs');

        expect(firstLoadingMs.keys, containsAll(slots.keys));
        final appOpen = firstLoadingMs['appOpen']!;
        final interstitial = firstLoadingMs['interstitial']!;
        final rewarded = firstLoadingMs['rewarded']!;
        expect(appOpen, greaterThanOrEqualTo(800), reason: 'debounce floor');
        expect(
          appOpen,
          lessThanOrEqualTo(800 + 400 + 300),
          reason: 'jitter cap',
        );
        expect(interstitial - appOpen, greaterThanOrEqualTo(400));
        expect(rewarded - interstitial, greaterThanOrEqualTo(400));
      });
    },
  );
}
