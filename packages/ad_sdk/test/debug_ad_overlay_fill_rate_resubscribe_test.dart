// Round-38 audit regression (claude CLI independent review, MINOR): the
// debug overlay's `_FillRateRegressionRows` used a bare `_sub != null` guard
// to decide whether to (re)subscribe to `AdManager().fillRateBaselineMonitor`
// — meant "subscribe once, ever". A `destroy()`+`initialize()` cycle disposes
// the old monitor (closing its alert stream) and hands the overlay a new
// one, but the guard left `_sub` latched onto the dead stream forever, so a
// regression on the NEW monitor never triggered a rebuild. Unlike its
// sibling `_SlotRows`, this widget also never listened to `initRevision` at
// all, so nothing forced it to reconsider the subscription regardless.
//
// Seeding pattern mirrors test/fill_rate_baseline_monitor_test.dart.

import 'dart:convert';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _historyKey = 'ad_sdk_fill_rate_baseline_history_v1';

// T165 fix: history is keyed by UTC day (AdPreferences._todayUtcClamped) —
// a local-time date here drifts a day off during the daily window where
// local and UTC calendar dates differ (e.g. any UTC+ timezone shortly
// after local midnight).
String _daysAgo(int n) => DateTime.now()
    .toUtc()
    .subtract(Duration(days: n))
    .toIso8601String()
    .substring(0, 10);

Future<void> _seedPastDay(
  AdSlotType type, {
  required int daysAgo,
  required int attempts,
  required int successes,
}) async {
  final raw = await SharedPreferences.getInstance();
  final existing = raw.getString(_historyKey);
  final history = existing == null
      ? <String, dynamic>{}
      : jsonDecode(existing) as Map<String, dynamic>;
  final date = _daysAgo(daysAgo);
  final perType = (history[date] as Map<String, dynamic>?) ?? {};
  perType[type.name] = {
    'attempts': attempts,
    'successes': successes,
    'revenueMicros': 0,
    'revenueCount': 0,
  };
  history[date] = perType;
  await raw.setString(_historyKey, jsonEncode(history));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget harness() {
    return MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            const Text('host content'),
            const DebugAdOverlay(),
          ],
        ),
      ),
    );
  }

  setUp(() async {
    AdPreferences.resetForTest();
    SharedPreferences.setMockInitialValues({});
    await _seedPastDay(AdSlotType.interstitial,
        daysAgo: 1, attempts: 10, successes: 10);
    await _seedPastDay(AdSlotType.rewarded,
        daysAgo: 1, attempts: 10, successes: 10);
  });

  tearDown(() async {
    DebugAdOverlay.globallyVisible.value = true;
    await AdManager().destroy();
  });

  testWidgets(
      'round-38 audit (MINOR): a regression on a freshly re-enabled monitor '
      '(after destroy()+initialize()) is still surfaced, not silently '
      'swallowed by a subscription still latched onto the disposed one',
      (tester) async {
    await AdManager().enableFillRateBaselineMonitor(minSamples: 3);

    await tester.pumpWidget(harness());
    await tester.pump();
    await tester.tap(find.text('🐛 Ad'));
    await tester.pump();

    // Regress the OLD monitor (monitor A) on `interstitial` — proves the
    // panel can show an alert at all, before the destroy()/re-enable cycle.
    for (var i = 0; i < 5; i++) {
      AdManager().debugEmit(const AdLoadEvent(
        providerTag: '[test]',
        type: AdSlotType.interstitial,
        placement: AdPlacement.unspecified,
        success: false,
      ));
    }
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.textContaining('interstitial'), findsOneWidget,
        reason: 'sanity: the panel does show a live regression from the '
            'monitor active at mount time');

    // Simulate the real-world destroy()+initialize() cycle: the old monitor
    // is disposed and, immediately after, a brand new one takes its place —
    // same ordering a host's splash-screen re-init would produce.
    await AdManager().destroy();
    await AdManager().enableFillRateBaselineMonitor(minSamples: 3);
    await tester.pump();

    // Regress the NEW monitor (monitor B) on a DIFFERENT slot type, so this
    // can only be showing up via the new monitor's own stream/state, not any
    // leftover state from monitor A.
    for (var i = 0; i < 5; i++) {
      AdManager().debugEmit(const AdLoadEvent(
        providerTag: '[test]',
        type: AdSlotType.rewarded,
        placement: AdPlacement.unspecified,
        success: false,
      ));
    }
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump(const Duration(milliseconds: 10));

    expect(find.textContaining('rewarded'), findsOneWidget,
        reason: 'the overlay must resubscribe to the NEW monitor after a '
            'destroy()+initialize() cycle — before the fix, `_sub` stayed '
            'latched onto monitor A\'s disposed stream forever and this '
            'regression on monitor B never surfaced');
  });
}
