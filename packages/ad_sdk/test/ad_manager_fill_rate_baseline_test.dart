// Tests for AdManager.enableFillRateBaselineMonitor/disableFillRateBaselineMonitor
// — the AdManager-level wiring around FillRateBaselineMonitor (T97), whose
// own class logic is covered by test/fill_rate_baseline_monitor_test.dart.
// This file covers the async-construction race a code-review audit found
// (2026-08-16): enableFillRateBaselineMonitor awaits AdPreferences.getInstance()
// before constructing its monitor, so two overlapping calls could otherwise
// leak the loser's instance (never disposed) instead of just replacing it.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    AdPreferences.resetForTest();
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    AdManager().disableFillRateBaselineMonitor();
  });

  test('enables a single reachable monitor', () async {
    await AdManager().enableFillRateBaselineMonitor();
    expect(AdManager().fillRateBaselineMonitor, isNotNull);
  });

  test(
      'two concurrent enable calls do not leak the loser — only one live '
      'instance ever processes a subsequent event', () async {
    final f1 = AdManager().enableFillRateBaselineMonitor();
    final f2 = AdManager().enableFillRateBaselineMonitor();
    await Future.wait([f1, f2]);

    expect(AdManager().fillRateBaselineMonitor, isNotNull);

    final prefs = await AdPreferences.getInstance();
    int attemptsFor(AdSlotType type) {
      final history = prefs.getFillRateBaselineHistory();
      final today = DateTime.now().toIso8601String().substring(0, 10);
      return history[today]?[type.name]?['attempts'] ?? 0;
    }

    final before = attemptsFor(AdSlotType.interstitial);

    AdManager().debugEmit(const AdLoadEvent(
      providerTag: '[race-test]',
      type: AdSlotType.interstitial,
      placement: AdPlacement.unspecified,
      success: true,
    ));
    await Future<void>.delayed(Duration.zero);

    final after = attemptsFor(AdSlotType.interstitial);
    expect(after - before, 1,
        reason: 'exactly one live monitor must have persisted this event — '
            'an orphaned, un-disposed loser from the race would double it');
  });

  test('disableFillRateBaselineMonitor also prevents an in-flight enable '
      'call from resurrecting a monitor', () async {
    final enableFuture = AdManager().enableFillRateBaselineMonitor();
    AdManager().disableFillRateBaselineMonitor();
    await enableFuture;

    expect(AdManager().fillRateBaselineMonitor, isNull,
        reason: 'disable() must win over an enable() call already in '
            'flight when it started first');
  });
}
