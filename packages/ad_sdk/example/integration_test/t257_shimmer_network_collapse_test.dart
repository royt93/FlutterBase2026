import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/widget/shimmer_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Test adapter that arms a real 30s AdSlot watchdog on banner loading and
/// hangs until the watchdog fires naturally.
class _WatchdogTimeoutLoadingAdapter extends FakeAdProviderAdapter {
  final Completer<void> _hangCompleter = Completer<void>();
  BannerListenables? activeBannerListenables;
  bool watchdogFired = false;

  @override
  Future<void> loadBannerIfNeeded(Object key, double widthPx) async {
    final slot = bannerSlot(key);
    final l = banner(key);
    activeBannerListenables = l;
    if (!slot.beginLoad()) return;

    // Arm the genuine 30s watchdog used by production adapters
    slot.armLoadWatchdog(
      'banner',
      const Duration(seconds: 30),
      onTimeout: () {
        watchdogFired = true;
        l.markError();
        if (!_hangCompleter.isCompleted) {
          _hangCompleter.complete();
        }
      },
    );

    await _hangCompleter.future;
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'T257 on-device: real watchdog collapses banner; screenshot captured for visual inspection',
    (tester) async {
      final adapter = _WatchdogTimeoutLoadingAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = const AdConfig(
        provider: AdProvider.admob,
        admob: AdMobConfig(
          bannerId: 'test-banner',
          interstitialId: 'test-interstitial',
          appOpenId: 'test-appopen',
          rewardedId: 'test-rewarded',
        ),
      );
      AdManager().debugCanRequestAds = true;
      AdManager().debugResetBannerCooldown();

      addTearDown(() {
        AdManager().debugSetAdapter(null);
        AdManager().debugConfig = null;
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          navigatorObservers: [adRouteObserver],
          home: const Scaffold(body: Center(child: BannerAdWidget())),
        ),
      );

      // Let first layout complete and BannerAdWidget start the held load.
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        adapter.activeBannerListenables,
        isNotNull,
        reason: 'loadBannerIfNeeded must have been invoked on the adapter',
      );

      // 1. Assert ShimmerView is mounted and animating
      final shimmerFinder = find.byType(ShimmerView);
      expect(
        shimmerFinder,
        findsWidgets,
        reason: 'ShimmerView must be mounted while ad is in loading state',
      );
      expect(
        tester.getSize(find.byType(BannerAdWidget)).height,
        greaterThan(0),
        reason: 'loading placeholder must occupy visible banner area',
      );

      // 2. Capture on-device screenshot: must succeed and produce non-empty PNG
      await binding.convertFlutterSurfaceToImage();
      await tester.pump();
      final bytes = await binding.takeScreenshot('t257_shimmer_pixel7pro');
      expect(
        bytes,
        isNotEmpty,
        reason: 'takeScreenshot must produce non-empty image data on device',
      );
      debugPrint(
        'T257_VISUAL_SCREENSHOT: captured ${bytes.length} bytes on device ✅',
      );

      // 3. Wait out the genuine 30s watchdog deadline (31s with pump intervals)
      debugPrint('T257_WATCHDOG: waiting for real 30s watchdog timeout...');
      final deadline = DateTime.now().add(const Duration(seconds: 31));
      while (DateTime.now().isBefore(deadline) && !adapter.watchdogFired) {
        await tester.pump(const Duration(milliseconds: 500));
      }

      expect(
        adapter.watchdogFired,
        isTrue,
        reason: '30s watchdog must fire naturally on timeout',
      );
      debugPrint('T257_WATCHDOG: real 30s watchdog fired naturally ✅');

      // 4. Assert ShimmerView is immediately removed from widget tree
      await tester.pump();
      expect(
        shimmerFinder,
        findsNothing,
        reason:
            'ShimmerView must be removed once watchdog fires and marks error',
      );

      // 5. Settle animation and assert banner height collapses to 0
      await tester.pumpAndSettle();
      final size = tester.getSize(find.byType(BannerAdWidget));
      expect(
        size.height,
        0,
        reason: 'BannerAdWidget must collapse height to 0 on watchdog timeout',
      );
      expect(tester.takeException(), isNull);
      debugPrint(
        'T257_WATCHDOG: Clean collapse to 0 height verified on Pixel 7 Pro ✅',
      );
    },
  );
}
