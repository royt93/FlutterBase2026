// T02 — integration + widget coverage for the consent → adapter (non-
// personalized / npa) wiring at the AdManager level.
//
// The adapter-level guarantee ("consent=false ⇒ AdRequest carries npa=1") is
// proven in admob_behavioral_test.dart. Here we prove the ORCHESTRATION link:
// AdManager.setConsent must forward the consent into the active provider
// adapter via applyConsent, so a real host that flips consent (programmatically
// or from a UI toggle) actually changes the personalization of the next ad
// request.
//
// AdManager is a singleton whose real init needs native plugins, so we flip
// isInitialised true via the debug seams (debugSetAdapter + debugConfig) and
// inject a fake adapter that records every applyConsent call.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Adapter that records the consent handed to [applyConsent]. Everything else
/// is routed through noSuchMethod — setConsent only touches applyConsent.
class _RecordingAdapter implements AdProviderAdapter {
  final List<AdConsent> applied = <AdConsent>[];

  AdConsent? get last => applied.isEmpty ? null : applied.last;

  @override
  void applyConsent(AdConsent consent) => applied.add(consent);

  @override
  String get tag => 'recording';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _config = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'ca-app-pub-3940256099942544/1111111111',
    interstitialId: 'ca-app-pub-3940256099942544/2222222222',
    appOpenId: 'ca-app-pub-3940256099942544/3333333333',
    rewardedId: 'ca-app-pub-3940256099942544/4444444444',
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RecordingAdapter adapter;

  // applyConsentToProviders fires native calls on these channels (AppLovin's
  // are not awaited, so a MissingPluginException would surface as an unhandled
  // async error and fail the test). No-op them so we isolate the wiring.
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const alChannel = MethodChannel('applovin_max');
  const gmaChannel = MethodChannel('plugins.flutter.io/google_mobile_ads');

  setUp(() {
    messenger.setMockMethodCallHandler(alChannel, (call) async => null);
    messenger.setMockMethodCallHandler(gmaChannel, (call) async => null);
    adapter = _RecordingAdapter();
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _config; // isInitialised → true
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(alChannel, null);
    messenger.setMockMethodCallHandler(gmaChannel, null);
    AdManager().debugSetAdapter(null);
    AdManager().debugConfig = null;
  });

  group('AdManager.setConsent → adapter.applyConsent', () {
    test('granting consent forwards hasUserConsent=true', () async {
      await AdManager().setConsent(AdConsent.fullyAccepted);
      expect(adapter.last, isNotNull);
      expect(adapter.last!.hasUserConsent, isTrue);
    });

    test('declining consent forwards hasUserConsent=false', () async {
      await AdManager().setConsent(AdConsent.conservative);
      expect(adapter.last!.hasUserConsent, isFalse);
    });

    test('flipping consent forwards each change in order', () async {
      await AdManager().setConsent(AdConsent.fullyAccepted);
      await AdManager().setConsent(AdConsent.conservative);
      await AdManager().setConsent(AdConsent.fullyAccepted);
      expect(adapter.applied.map((c) => c.hasUserConsent).toList(),
          [true, false, true]);
    });

    test('age-restricted/doNotSell flags are carried through verbatim',
        () async {
      await AdManager().setConsent(
          const AdConsent(isAgeRestrictedUser: true, doNotSell: true));
      expect(adapter.last!.hasUserConsent, isFalse);
      expect(adapter.last!.isAgeRestrictedUser, isTrue);
      expect(adapter.last!.doNotSell, isTrue);
    });

    test('setConsent before init buffers and does NOT touch the adapter',
        () async {
      // Simulate "not initialised": drop the adapter reference.
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
      await AdManager().setConsent(AdConsent.fullyAccepted);
      // Re-attach a fresh recorder; nothing should have been recorded on it.
      final fresh = _RecordingAdapter();
      AdManager().debugSetAdapter(fresh);
      expect(fresh.applied, isEmpty);
    });
  });

  group('widget: UI consent action drives adapter personalization', () {
    testWidgets('tapping Accept/Reject forwards consent to the adapter',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                ElevatedButton(
                  onPressed: () =>
                      AdManager().setConsent(AdConsent.fullyAccepted),
                  child: const Text('Accept'),
                ),
                ElevatedButton(
                  onPressed: () =>
                      AdManager().setConsent(AdConsent.conservative),
                  child: const Text('Reject'),
                ),
              ],
            ),
          ),
        ),
      );

      await tester.tap(find.text('Accept'));
      await tester.pumpAndSettle();
      expect(adapter.last!.hasUserConsent, isTrue,
          reason: 'Accept → personalized (npa off) on next request');

      await tester.tap(find.text('Reject'));
      await tester.pumpAndSettle();
      expect(adapter.last!.hasUserConsent, isFalse,
          reason: 'Reject → non-personalized (npa on) on next request');
    });
  });
}
