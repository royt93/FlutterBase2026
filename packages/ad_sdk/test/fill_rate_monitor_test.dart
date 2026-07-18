// Behavioral tests for the opt-in fill-rate monitor, driven purely through
// AdManager().debugEmit(AdLoadEvent(...)) — no adapter/native plugin needed
// since FillRateMonitor only ever listens on AdManager().events.
//
// Covered:
// 1. fillRate() computation + rolling-window truncation.
// 2. Alert fires exactly once when the trailing rate first drops below
//    threshold within a full window — not before the window fills, not
//    repeated while the drop persists.
// 3. Alert fires again after a recovery then a second drop.
// 4. Each AdSlotType is tracked independently.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

AdLoadEvent _load(AdSlotType type, bool success) => AdLoadEvent(
      providerTag: 'fake',
      type: type,
      placement: AdPlacement.unspecified,
      success: success,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FillRateMonitor monitor;

  group('fillRate()', () {
    tearDown(() => monitor.dispose());

    test('returns 1.0 with no load events observed', () {
      monitor = FillRateMonitor();
      expect(monitor.fillRate(AdSlotType.interstitial), 1.0);
    });

    test('computes success fraction from a mixed sequence', () async {
      monitor = FillRateMonitor(rollingWindowSize: 4);
      for (final ok in [true, true, false, false]) {
        AdManager().debugEmit(_load(AdSlotType.interstitial, ok));
      }
      await Future<void>.delayed(Duration.zero);
      expect(monitor.fillRate(AdSlotType.interstitial), 0.5);
    });

    test('rolling window truncates to the last N results', () async {
      monitor = FillRateMonitor(rollingWindowSize: 2);
      AdManager().debugEmit(_load(AdSlotType.interstitial, false));
      AdManager().debugEmit(_load(AdSlotType.interstitial, true));
      AdManager().debugEmit(_load(AdSlotType.interstitial, true));
      await Future<void>.delayed(Duration.zero);
      expect(monitor.fillRate(AdSlotType.interstitial), 1.0,
          reason: 'oldest (failed) sample evicted');
    });

    test('tracks each AdSlotType independently', () async {
      monitor = FillRateMonitor(rollingWindowSize: 2);
      AdManager().debugEmit(_load(AdSlotType.interstitial, false));
      AdManager().debugEmit(_load(AdSlotType.interstitial, false));
      AdManager().debugEmit(_load(AdSlotType.rewarded, true));
      AdManager().debugEmit(_load(AdSlotType.rewarded, true));
      await Future<void>.delayed(Duration.zero);
      expect(monitor.fillRate(AdSlotType.interstitial), 0.0);
      expect(monitor.fillRate(AdSlotType.rewarded), 1.0);
    });
  });

  group('alerts', () {
    tearDown(() => monitor.dispose());

    test('does not fire before the window is full', () async {
      monitor = FillRateMonitor(rollingWindowSize: 4);
      final alerts = <FillRateAlert>[];
      final sub = monitor.alerts.listen(alerts.add);

      for (var i = 0; i < 3; i++) {
        AdManager().debugEmit(_load(AdSlotType.interstitial, false));
      }
      await Future<void>.delayed(Duration.zero);
      expect(alerts, isEmpty);
      await sub.cancel();
    });

    test('fires exactly once when the trailing rate drops below threshold',
        () async {
      monitor =
          FillRateMonitor(lowFillRateThreshold: 0.3, rollingWindowSize: 4);
      final alerts = <FillRateAlert>[];
      final sub = monitor.alerts.listen(alerts.add);

      // Fill the window at 0% — well below the 30% threshold.
      for (var i = 0; i < 4; i++) {
        AdManager().debugEmit(_load(AdSlotType.interstitial, false));
      }
      await Future<void>.delayed(Duration.zero);
      expect(alerts, hasLength(1));
      expect(alerts.single.type, AdSlotType.interstitial);
      expect(alerts.single.fillRate, 0.0);
      expect(alerts.single.threshold, 0.3);

      // Further failures keep the rate below threshold — must not re-alert.
      AdManager().debugEmit(_load(AdSlotType.interstitial, false));
      AdManager().debugEmit(_load(AdSlotType.interstitial, false));
      await Future<void>.delayed(Duration.zero);
      expect(alerts, hasLength(1), reason: 'no spam while the drop persists');

      await sub.cancel();
    });

    test('fires again after the rate recovers then drops a second time',
        () async {
      monitor =
          FillRateMonitor(lowFillRateThreshold: 0.5, rollingWindowSize: 2);
      final alerts = <FillRateAlert>[];
      final sub = monitor.alerts.listen(alerts.add);

      // Drop below threshold: window [false, false] → rate 0.0 < 0.5.
      AdManager().debugEmit(_load(AdSlotType.rewarded, false));
      AdManager().debugEmit(_load(AdSlotType.rewarded, false));
      await Future<void>.delayed(Duration.zero);
      expect(alerts, hasLength(1));

      // Recover: window [true, true] → rate 1.0 ≥ 0.5.
      AdManager().debugEmit(_load(AdSlotType.rewarded, true));
      AdManager().debugEmit(_load(AdSlotType.rewarded, true));
      await Future<void>.delayed(Duration.zero);
      expect(alerts, hasLength(1), reason: 'recovery emits no alert');

      // Drop a second time — should alert again since the last state was
      // "recovered", not "still alerted".
      AdManager().debugEmit(_load(AdSlotType.rewarded, false));
      AdManager().debugEmit(_load(AdSlotType.rewarded, false));
      await Future<void>.delayed(Duration.zero);
      expect(alerts, hasLength(2), reason: 'second dip re-alerts');

      await sub.cancel();
    });
  });

  group('AdManager().enableFillRateMonitor / disableFillRateMonitor', () {
    tearDown(() {
      AdManager().disableFillRateMonitor();
    });

    test('fillRateMonitor getter is null by default', () {
      expect(AdManager().fillRateMonitor, isNull);
    });

    test('enableFillRateMonitor registers the instance', () {
      final m = FillRateMonitor();
      AdManager().enableFillRateMonitor(m);
      expect(AdManager().fillRateMonitor, same(m));
    });
  });
}
