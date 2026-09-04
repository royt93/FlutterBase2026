// T123 — JourneyPrefetcher unit tests. Uses FakeAdProviderAdapter (T118) so
// notifySignal()'s calls into AdManager().loadX() actually move a slot
// through its real state machine, not just a mock expectation.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeAdProviderAdapter adapter;
  late JourneyPrefetcher prefetcher;

  setUp(() {
    adapter = FakeAdProviderAdapter();
    AdManager().debugSetAdapter(adapter);
    prefetcher = JourneyPrefetcher();
  });

  tearDown(() {
    prefetcher.dispose();
    AdManager().debugSetAdapter(null);
  });

  test('first signal for a (signal, type) pair preloads immediately',
      () async {
    expect(adapter.interstitialSlot.isIdle, isTrue);

    prefetcher.notifySignal('levelStarted', AdSlotType.interstitial);
    await Future<void>.delayed(Duration.zero);
    expect(adapter.interstitialSlot.isReady, isTrue);
  });

  test('averageTimeToShow is null until a matching AdShowEvent lands', () {
    expect(
      prefetcher.averageTimeToShow('levelStarted', AdSlotType.interstitial),
      isNull,
    );
  });

  test('records rolling time-to-show from signal to a matching show event',
      () async {
    prefetcher.notifySignal('levelStarted', AdSlotType.interstitial);
    await Future<void>.delayed(const Duration(milliseconds: 5));

    AdManager().debugEmit(const AdShowEvent(
      providerTag: '[Fake]',
      type: AdSlotType.interstitial,
      placement: AdPlacement.unspecified,
      success: true,
    ));
    await Future<void>.delayed(Duration.zero);

    final avg =
        prefetcher.averageTimeToShow('levelStarted', AdSlotType.interstitial);
    expect(avg, isNotNull);
    expect(avg!.inMilliseconds, greaterThanOrEqualTo(0));
  });

  test(
      'a failed AdShowEvent does not record a time-to-show sample (was '
      'never actually shown)', () async {
    prefetcher.notifySignal('levelStarted', AdSlotType.interstitial);
    AdManager().debugEmit(const AdShowEvent(
      providerTag: '[Fake]',
      type: AdSlotType.interstitial,
      placement: AdPlacement.unspecified,
      success: false,
    ));
    await Future<void>.delayed(Duration.zero);

    expect(
      prefetcher.averageTimeToShow('levelStarted', AdSlotType.interstitial),
      isNull,
    );
  });

  test(
      'once the rolling average exceeds maxHoldDuration, later signals stop '
      'preloading eagerly', () async {
    final shortHold = JourneyPrefetcher(
      maxHoldDuration: const Duration(milliseconds: 1),
    );
    addTearDown(shortHold.dispose);

    shortHold.notifySignal('screenEntered', AdSlotType.rewarded);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    AdManager().debugEmit(const AdShowEvent(
      providerTag: '[Fake]',
      type: AdSlotType.rewarded,
      placement: AdPlacement.unspecified,
      success: true,
    ));
    await Future<void>.delayed(Duration.zero);

    expect(
      shortHold.averageTimeToShow('screenEntered', AdSlotType.rewarded),
      isNotNull,
      reason: 'sanity: a sample must have been recorded',
    );

    // Reset the slot back to idle so a second preload would be observable.
    await AdManager().destroy();
    adapter = FakeAdProviderAdapter();
    AdManager().debugSetAdapter(adapter);

    shortHold.notifySignal('screenEntered', AdSlotType.rewarded);
    expect(adapter.rewardedSlot.isIdle, isTrue,
        reason: 'rolling average already exceeds the 1ms maxHoldDuration — '
            'this signal fires too far ahead of the actual show to be '
            'worth preloading for');
  });

  test(
      'two different signals pending for the same type do not both get '
      'credited by one show event', () async {
    // Both journey signals precede the same ad type without an intervening
    // show — a real scenario (e.g. a level-complete screen that also counts
    // as "screen entered"). Only ONE show event follows, so it can only be
    // attributed to whichever signal actually preceded it, not both.
    prefetcher.notifySignal('levelStarted', AdSlotType.interstitial);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    prefetcher.notifySignal('screenEntered', AdSlotType.interstitial);
    await Future<void>.delayed(const Duration(milliseconds: 5));

    AdManager().debugEmit(const AdShowEvent(
      providerTag: '[Fake]',
      type: AdSlotType.interstitial,
      placement: AdPlacement.unspecified,
      success: true,
    ));
    await Future<void>.delayed(Duration.zero);

    final levelStartedAvg =
        prefetcher.averageTimeToShow('levelStarted', AdSlotType.interstitial);
    final screenEnteredAvg = prefetcher.averageTimeToShow(
        'screenEntered', AdSlotType.interstitial);
    final bothCredited = levelStartedAvg != null && screenEnteredAvg != null;
    expect(bothCredited, isFalse,
        reason: 'a single show event must not be recorded as a sample for '
            'two different, unrelated journey signals — that conflates '
            'timing data between signals that have nothing to do with '
            'each other');
  });

  test(
      'a genuine timestamp tie between two signals still credits the one '
      'that actually fired LAST, not whichever happens to iterate first',
      () async {
    // DateTime.now() resolution can genuinely tie two back-to-back calls on
    // some platforms/VMs — this pins that exact case with an injected clock
    // instead of hoping for a real tie to happen (or not) in CI.
    final frozenNow = DateTime(2026, 1, 1, 12, 0, 0);
    final tiedPrefetcher = JourneyPrefetcher(debugClock: () => frozenNow);
    addTearDown(tiedPrefetcher.dispose);

    tiedPrefetcher.notifySignal('levelStarted', AdSlotType.interstitial);
    tiedPrefetcher.notifySignal('screenEntered', AdSlotType.interstitial);
    await Future<void>.delayed(Duration.zero);

    AdManager().debugEmit(const AdShowEvent(
      providerTag: '[Fake]',
      type: AdSlotType.interstitial,
      placement: AdPlacement.unspecified,
      success: true,
    ));
    await Future<void>.delayed(Duration.zero);

    expect(
      tiedPrefetcher.averageTimeToShow(
          'screenEntered', AdSlotType.interstitial),
      isNotNull,
      reason: '"screenEntered" was the one actually called last (even '
          'though both share the exact same timestamp) — it must be the '
          'one credited, by call order, not by map iteration order',
    );
    expect(
      tiedPrefetcher.averageTimeToShow(
          'levelStarted', AdSlotType.interstitial),
      isNull,
      reason: 'the earlier-called signal must stay pending, not be '
          'incorrectly credited instead',
    );
  });

  test('dispose() stops recording new time-to-show samples', () async {
    prefetcher.notifySignal('levelStarted', AdSlotType.interstitial);
    prefetcher.dispose();

    AdManager().debugEmit(const AdShowEvent(
      providerTag: '[Fake]',
      type: AdSlotType.interstitial,
      placement: AdPlacement.unspecified,
      success: true,
    ));
    await Future<void>.delayed(Duration.zero);

    expect(
      prefetcher.averageTimeToShow('levelStarted', AdSlotType.interstitial),
      isNull,
    );
  });
}
