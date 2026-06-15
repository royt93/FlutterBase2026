// Unit tests for the AdEvent stream payloads + RewardResult. These are the
// public analytics surface (`AdManager().events`) a partner pipes into their
// LTV/attribution tooling, so the field plumbing must be exact.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AdLoadEvent', () {
    test('success load carries no error code', () {
      const e = AdLoadEvent(
        providerTag: '[AppLovin]',
        type: AdSlotType.banner,
        placement: AdPlacement.home,
        success: true,
      );
      expect(e.success, isTrue);
      expect(e.errorCode, isNull);
      expect(e.providerTag, '[AppLovin]');
      expect(e.type, AdSlotType.banner);
      expect(e.placement, AdPlacement.home);
      expect(e, isA<AdEvent>());
    });

    test('failed load carries the error code', () {
      const e = AdLoadEvent(
        providerTag: '[AdMob]',
        type: AdSlotType.interstitial,
        placement: AdPlacement.unspecified,
        success: false,
        errorCode: 3,
      );
      expect(e.success, isFalse);
      expect(e.errorCode, 3);
    });
  });

  test('AdShowEvent carries success + placement', () {
    const e = AdShowEvent(
      providerTag: '[AdMob]',
      type: AdSlotType.appOpen,
      placement: AdPlacement.splash,
      success: true,
    );
    expect(e.success, isTrue);
    expect(e.placement, AdPlacement.splash);
  });

  test('AdClickEvent carries provider + type + placement', () {
    const e = AdClickEvent(
      providerTag: '[AppLovin]',
      type: AdSlotType.rewarded,
      placement: AdPlacement.shop,
    );
    expect(e.type, AdSlotType.rewarded);
    expect(e.placement, AdPlacement.shop);
  });

  test('AdRevenueEvent carries micros + currency + optional network/precision', () {
    const e = AdRevenueEvent(
      providerTag: '[AppLovin]',
      type: AdSlotType.banner,
      placement: AdPlacement.home,
      valueMicros: 12345,
      currencyCode: 'USD',
      networkName: 'AppLovin',
      precision: 'exact',
    );
    expect(e.valueMicros, 12345);
    expect(e.currencyCode, 'USD');
    expect(e.networkName, 'AppLovin');
    expect(e.precision, 'exact');
  });

  group('RewardResult', () {
    test('skipped is earned=false with no label/amount', () {
      expect(RewardResult.skipped.earned, isFalse);
      expect(RewardResult.skipped.label, isNull);
      expect(RewardResult.skipped.amount, isNull);
    });

    test('earned carries label + amount', () {
      const r = RewardResult(earned: true, label: 'coins', amount: 10);
      expect(r.earned, isTrue);
      expect(r.label, 'coins');
      expect(r.amount, 10);
    });
  });
}
