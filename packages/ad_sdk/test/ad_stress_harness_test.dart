// T212 fix — the previous AdStressHarness was a standalone simulation over
// a bare List<int> with no connection to AdManager/AdEvent/a real adapter
// at all (caught by an independent audit). This tests the rewritten,
// genuinely SDK-touching version.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/ad_stress_harness.dart';

const _alChannel = MethodChannel('applovin_max');
const _gmaChannel = MethodChannel('plugins.flutter.io/google_mobile_ads');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const harness = AdStressHarness();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(_alChannel, (call) async => null);
    messenger.setMockMethodCallHandler(_gmaChannel, (call) async => null);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_alChannel, null);
    messenger.setMockMethodCallHandler(_gmaChannel, null);
  });

  test(
      'a 10k-event burst is fully delivered through the real event stream',
      () async {
    final report = await harness.run(events: 10000, reinitializations: 0);
    expect(report.eventsGenerated, 10000);
    expect(report.eventsDelivered, 10000,
        reason: 'T212 — nothing may be silently dropped from a rapid, '
            'no-await-between-emits burst on the real broadcast stream');
    expect(report.withinBound, isTrue);
  });

  test('reinit churn (real initialize()-then-destroy()) never leaks a '
      'fullscreen slot listener', () async {
    final report = await harness.run(events: 0, reinitializations: 20);
    expect(report.reinitializations, 20);
    expect(report.leakedFullscreenListenersAfterReinit, 0,
        reason: 'T212 — every real initialize()-then-destroy() cycle must '
            'genuinely detach the old adapter\'s fullscreen slot '
            'listeners, not just report success while leaking them');
    expect(report.withinBound, isTrue);
  });

  test('zero events and zero reinits is deterministic (no crash)', () async {
    final report = await harness.run(events: 0, reinitializations: 0);
    expect(report.eventsGenerated, 0);
    expect(report.eventsDelivered, 0);
    expect(report.reinitializations, 0);
    expect(report.leakedFullscreenListenersAfterReinit, 0);
    expect(report.withinBound, isTrue);
  });

  test('negative parameters fail fast', () async {
    await expectLater(
        AdStressHarness().run(events: -1), throwsArgumentError);
    await expectLater(
        AdStressHarness().run(reinitializations: -1), throwsArgumentError);
  });
}
