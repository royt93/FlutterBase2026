// Unit tests for AdPlacement — the analytics-tagging value object used on every
// show call and emitted in AdShowEvent / AdRevenueEvent.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AdPlacement presets', () {
    test('each preset carries its expected id', () {
      expect(AdPlacement.home.id, 'home');
      expect(AdPlacement.shop.id, 'shop');
      expect(AdPlacement.levelComplete.id, 'level_complete');
      expect(AdPlacement.gameOver.id, 'game_over');
      expect(AdPlacement.settings.id, 'settings');
      expect(AdPlacement.splash.id, 'splash');
      expect(AdPlacement.unspecified.id, 'unspecified');
    });
  });

  group('AdPlacement.custom', () {
    test('carries the given id', () {
      expect(const AdPlacement.custom('my_screen').id, 'my_screen');
    });
  });

  group('value equality', () {
    test('two placements with the same id are equal and hash the same', () {
      const a = AdPlacement.custom('home');
      expect(a, AdPlacement.home);
      expect(a.hashCode, AdPlacement.home.hashCode);
    });

    test('different ids are not equal', () {
      expect(AdPlacement.home, isNot(AdPlacement.shop));
    });

    test('usable as a Map/Set key', () {
      final seen = <AdPlacement>{};
      seen.add(AdPlacement.home);
      seen.add(const AdPlacement.custom('home'));
      expect(seen.length, 1, reason: 'equal placements collapse in a Set');
    });
  });

  test('toString includes the id', () {
    expect(AdPlacement.gameOver.toString(), 'AdPlacement(game_over)');
  });
}
