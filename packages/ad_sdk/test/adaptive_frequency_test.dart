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
  });
}
