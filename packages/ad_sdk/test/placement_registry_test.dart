// T140 — PlacementRegistry/PlacementSpec unit tests. Pure Dart, no
// AdManager/AdSafetyConfig involvement — those integration points are
// covered separately in ad_safety_config_test.dart and
// ad_manager_core_test.dart.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a registered placementId resolves its PlacementSpec', () {
    const registry = PlacementRegistry({
      'level_complete': PlacementSpec(
        format: AdSlotType.interstitial,
        frequencyCapOverride: 3,
      ),
    });

    final spec = registry['level_complete'];
    expect(spec, isNotNull);
    expect(spec!.format, AdSlotType.interstitial);
    expect(spec.frequencyCapOverride, 3);
  });

  test('an unregistered placementId resolves to null', () {
    const registry = PlacementRegistry({
      'level_complete': PlacementSpec(format: AdSlotType.interstitial),
    });

    expect(registry['some_other_placement'], isNull);
  });

  test('an empty registry resolves every placementId to null', () {
    const registry = PlacementRegistry({});
    expect(registry['anything'], isNull);
  });

  test('PlacementSpec.frequencyCapOverride defaults to null (no override)',
      () {
    const spec = PlacementSpec(format: AdSlotType.rewarded);
    expect(spec.frequencyCapOverride, isNull);
  });
}
