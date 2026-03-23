import 'package:ad_sdk/ad_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // ─────────────────────────────────────────────────
  // SimpleEventBus
  // ─────────────────────────────────────────────────
  group('SimpleEventBus', () {
    late SimpleEventBus bus;

    setUp(() {
      // Reset singleton listeners between tests by removing all
      bus = SimpleEventBus();
    });

    test('listener receives fired event', () {
      BoolEvent? received;
      void listener(BoolEvent e) => received = e;

      bus.listen(listener);
      bus.fire(const BoolEvent(true));
      bus.remove(listener);

      expect(received?.value, isTrue);
    });

    test('listener not called after remove()', () {
      int callCount = 0;
      void listener(BoolEvent e) => callCount++;

      bus.listen(listener);
      bus.remove(listener);
      bus.fire(const BoolEvent(true));

      expect(callCount, 0);
    });

    test('multiple listeners all receive event', () {
      final received = <bool>[];
      void l1(BoolEvent e) => received.add(e.value);
      void l2(BoolEvent e) => received.add(e.value);

      bus.listen(l1);
      bus.listen(l2);
      bus.fire(const BoolEvent(false));
      bus.remove(l1);
      bus.remove(l2);

      expect(received, [false, false]);
    });

    test('remove only removes the target listener', () {
      int l1Count = 0;
      int l2Count = 0;
      void l1(BoolEvent e) => l1Count++;
      void l2(BoolEvent e) => l2Count++;

      bus.listen(l1);
      bus.listen(l2);
      bus.remove(l1);
      bus.fire(const BoolEvent(true));
      bus.remove(l2);

      expect(l1Count, 0);
      expect(l2Count, 1);
    });

    test('fire with false value delivers correct payload', () {
      BoolEvent? received;
      void listener(BoolEvent e) => received = e;

      bus.listen(listener);
      bus.fire(const BoolEvent(false));
      bus.remove(listener);

      expect(received?.value, isFalse);
    });

    test('double remove is idempotent (no exception)', () {
      void listener(BoolEvent e) {}
      bus.listen(listener);
      bus.remove(listener);
      expect(() => bus.remove(listener), returnsNormally);
    });

    test('listener removed inside fire callback does not cause error', () {
      void Function(BoolEvent)? selfRemovingListener;
      selfRemovingListener = (e) {
        bus.remove(selfRemovingListener!);
      };
      bus.listen(selfRemovingListener);
      expect(() => bus.fire(const BoolEvent(true)), returnsNormally);
    });
  });

  // ─────────────────────────────────────────────────
  // SafeLogger
  // ─────────────────────────────────────────────────
  group('SafeLogger', () {
    test('d() does not throw', () {
      expect(() => SafeLogger.d('TestTag', 'debug message'), returnsNormally);
    });

    test('w() does not throw', () {
      expect(() => SafeLogger.w('TestTag', 'warning message'), returnsNormally);
    });

    test('e() does not throw', () {
      expect(
        () => SafeLogger.e('TestTag', 'error message'),
        returnsNormally,
      );
    });

    test('e() with message only does not throw', () {
      expect(
        () => SafeLogger.e('TestTag', 'error no exception'),
        returnsNormally,
      );
    });

    test('extremely long message does not throw', () {
      final longMsg = 'x' * 10000;
      expect(() => SafeLogger.d('Tag', longMsg), returnsNormally);
    });

    test('empty tag does not throw', () {
      expect(() => SafeLogger.d('', 'message'), returnsNormally);
    });
  });

  // ─────────────────────────────────────────────────
  // AdConfig
  // ─────────────────────────────────────────────────
  group('AdConfig', () {
    test('isAdMob returns true when provider is admob', () {
      const config = AdConfig(
        provider: AdProvider.admob,
        admob: AdMobConfig(
          bannerId: 'b',
          interstitialId: 'i',
          appOpenId: 'o',
          rewardedId: 'r',
        ),
      );
      expect(config.isAdMob, isTrue);
    });

    test('isAdMob returns false when provider is appLovin', () {
      const config = AdConfig(
        provider: AdProvider.appLovin,
        appLovin: AppLovinConfig(
          sdkKey: 'key',
          bannerId: 'b',
          interstitialId: 'i',
          appOpenId: 'o',
          rewardedId: 'r',
        ),
      );
      expect(config.isAdMob, isFalse);
    });

    test('vipDeviceGaids defaults to empty list', () {
      const config = AdConfig(
        provider: AdProvider.appLovin,
        appLovin: AppLovinConfig(
          sdkKey: 'k',
          bannerId: 'b',
          interstitialId: 'i',
          appOpenId: 'o',
          rewardedId: 'r',
        ),
      );
      expect(config.vipDeviceGaids, isEmpty);
    });

    test('vipDeviceGaids is populated correctly', () {
      const gaids = ['gaid-1', 'gaid-2'];
      const config = AdConfig(
        provider: AdProvider.appLovin,
        appLovin: AppLovinConfig(
          sdkKey: 'k',
          bannerId: 'b',
          interstitialId: 'i',
          appOpenId: 'o',
          rewardedId: 'r',
        ),
        vipDeviceGaids: gaids,
      );
      expect(config.vipDeviceGaids, equals(gaids));
    });

    test('loadingBufferMs defaults to 1000', () {
      const config = AdConfig(
        provider: AdProvider.appLovin,
        appLovin: AppLovinConfig(
          sdkKey: 'k',
          bannerId: 'b',
          interstitialId: 'i',
          appOpenId: 'o',
          rewardedId: 'r',
        ),
      );
      expect(config.loadingBufferMs, 1000);
    });

    test('custom loadingBufferMs is preserved', () {
      const config = AdConfig(
        provider: AdProvider.appLovin,
        appLovin: AppLovinConfig(
          sdkKey: 'k',
          bannerId: 'b',
          interstitialId: 'i',
          appOpenId: 'o',
          rewardedId: 'r',
        ),
        loadingBufferMs: 500,
      );
      expect(config.loadingBufferMs, 500);
    });

    test('AppLovinConfig stores all fields correctly', () {
      const cfg = AppLovinConfig(
        sdkKey: 'sdk-key',
        bannerId: 'banner-id',
        interstitialId: 'inter-id',
        appOpenId: 'open-id',
        rewardedId: 'reward-id',
      );
      expect(cfg.sdkKey, 'sdk-key');
      expect(cfg.bannerId, 'banner-id');
      expect(cfg.interstitialId, 'inter-id');
      expect(cfg.appOpenId, 'open-id');
      expect(cfg.rewardedId, 'reward-id');
    });

    test('AdMobConfig stores all fields correctly', () {
      const cfg = AdMobConfig(
        bannerId: 'b',
        interstitialId: 'i',
        appOpenId: 'o',
        rewardedId: 'r',
        testDeviceIds: ['device-1'],
      );
      expect(cfg.bannerId, 'b');
      expect(cfg.testDeviceIds, ['device-1']);
    });
  });

  // ─────────────────────────────────────────────────
  // BoolEvent
  // ─────────────────────────────────────────────────
  group('BoolEvent', () {
    test('value true', () => expect(const BoolEvent(true).value, isTrue));
    test('value false', () => expect(const BoolEvent(false).value, isFalse));
  });
}
