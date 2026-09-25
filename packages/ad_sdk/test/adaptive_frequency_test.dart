// Unit tests for T26 Phase 1 (adaptive-frequency instrumentation).
//
// AdSafetyConfig.recordAppWentBackground()/canShowAppOpenOnResume() must
// record AdaptiveFrequencySignals at the two proxy points the task spec
// calls for, without altering any existing cap/show decision.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/adaptive/adaptive_frequency.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> initSafety() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await AdPreferences.getInstance();
    await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
    AdSafetyConfig
        .resetForReinit(); // also clears AdaptiveFrequencySignals + sink
  }

  group('AdaptiveFrequencySignals — Phase 1 instrumentation', () {
    test('recordAppWentBackground with no prior ad shown records nothing',
        () async {
      await initSafety();
      AdSafetyConfig.recordAppWentBackground();
      expect(AdaptiveFrequencySignals.entries, isEmpty);
    });

    test(
        'recordAppWentBackground after a fullscreen ad records ad_to_background',
        () async {
      await initSafety();
      AdSafetyConfig.recordFullscreenAdShown();
      AdSafetyConfig.recordAppWentBackground();

      expect(AdaptiveFrequencySignals.entries, hasLength(1));
      final signal = AdaptiveFrequencySignals.entries.single;
      expect(signal.kind, 'ad_to_background');
      expect(signal.gapMs, greaterThanOrEqualTo(0));
    });

    test(
        'recordAppWentBackground does not record ad_to_background once the '
        'fullscreen-ad gap exceeds the freshness window', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await AdPreferences.getInstance();
      // Negative window: any real (>=0ms) gap always exceeds it, so this
      // deterministically exercises the "stale" branch without waiting out
      // the real 5-minute production window.
      await AdSafetyConfig.init(
        prefs,
        params: AdSafetyParams.debug.copyWith(adToBackgroundSignalWindowMs: -1),
      );
      AdSafetyConfig.resetForReinit();

      AdSafetyConfig.recordFullscreenAdShown();
      AdSafetyConfig.recordAppWentBackground();

      expect(AdaptiveFrequencySignals.entries, isEmpty);
    });

    test('canShowAppOpenOnResume with no prior background records nothing',
        () async {
      await initSafety();
      AdSafetyConfig.canShowAppOpenOnResume();
      expect(AdaptiveFrequencySignals.entries, isEmpty);
    });

    test(
        'canShowAppOpenOnResume after a background records background_to_resume',
        () async {
      await initSafety();
      AdSafetyConfig.recordAppWentBackground();
      AdSafetyConfig.canShowAppOpenOnResume();

      expect(AdaptiveFrequencySignals.entries, hasLength(1));
      final signal = AdaptiveFrequencySignals.entries.single;
      expect(signal.kind, 'background_to_resume');
      expect(signal.gapMs, greaterThanOrEqualTo(0));
    });

    test(
        'canShowAppOpenOnResume called twice without an intervening '
        'recordAppWentBackground only records background_to_resume once',
        () async {
      await initSafety();
      AdSafetyConfig.recordAppWentBackground();
      AdSafetyConfig.canShowAppOpenOnResume();
      AdSafetyConfig.canShowAppOpenOnResume();

      expect(AdaptiveFrequencySignals.entries, hasLength(1));
      expect(
          AdaptiveFrequencySignals.entries.single.kind, 'background_to_resume');
    });

    test('sink receives every recorded signal in order', () async {
      await initSafety();
      final captured = <AdaptiveFrequencySignal>[];
      AdaptiveFrequencySignals.setSink(captured.add);

      AdSafetyConfig.recordFullscreenAdShown();
      AdSafetyConfig.recordAppWentBackground();
      AdSafetyConfig.canShowAppOpenOnResume();

      expect(captured, hasLength(2));
      expect(captured[0].kind, 'ad_to_background');
      expect(captured[1].kind, 'background_to_resume');
    });

    test('does not alter the canShowAppOpenOnResume gating decision', () async {
      await initSafety();
      AdSafetyConfig.recordAppWentBackground();
      final withoutSink = AdSafetyConfig.canShowAppOpenOnResume();

      await initSafety();
      AdSafetyConfig.recordAppWentBackground();
      AdaptiveFrequencySignals.setSink((_) {});
      final withSink = AdSafetyConfig.canShowAppOpenOnResume();

      expect(withSink.canShow, withoutSink.canShow);
    });

    test('resetForReinit clears buffered signals and the sink', () async {
      await initSafety();
      AdSafetyConfig.recordFullscreenAdShown();
      AdSafetyConfig.recordAppWentBackground();
      expect(AdaptiveFrequencySignals.entries, isNotEmpty);

      AdSafetyConfig.resetForReinit();
      expect(AdaptiveFrequencySignals.entries, isEmpty);
    });

    // B: coverage — AdaptiveFrequencySignals.record() overflow trim and sink.
    test('overflow: entries capped at 500 when record() exceeds maxEntries',
        () async {
      await initSafety();
      // Drive record() directly to trigger the removeRange trim path.
      for (var i = 0; i < 502; i++) {
        AdaptiveFrequencySignals.record('ad_to_background', i, 0);
      }
      expect(AdaptiveFrequencySignals.entries.length, 500);
    });

    test('setSink: sink receives signal forwarded by record()', () async {
      await initSafety();
      final received = <AdaptiveFrequencySignal>[];
      AdaptiveFrequencySignals.setSink(received.add);
      AdaptiveFrequencySignals.record('background_to_resume', 1000, 5000);
      expect(received, hasLength(1));
      expect(received.first.kind, 'background_to_resume');
      expect(received.first.gapMs, 5000);
    });

    test('AdaptiveFrequencySignal.toJson contains all fields', () {
      final s =
          AdaptiveFrequencySignal(kind: 'ad_to_background', timestampMs: 42, gapMs: 7);
      final j = s.toJson();
      expect(j['kind'], 'ad_to_background');
      expect(j['timestampMs'], 42);
      expect(j['gapMs'], 7);
    });
  });
}
