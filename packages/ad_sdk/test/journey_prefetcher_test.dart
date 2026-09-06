// T123 — JourneyPrefetcher unit tests. Uses FakeAdProviderAdapter (T118) so
// notifySignal()'s calls into AdManager().loadX() actually move a slot
// through its real state machine, not just a mock expectation.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
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

  // T133 — a pending signal has no TTL: if the app is backgrounded for a
  // long stretch between notifySignal() and the next matching AdShowEvent
  // (which may be completely unrelated to the original journey step), the
  // huge elapsed gap was recorded as a normal time-to-show sample, wrongly
  // dragging the rolling average up and potentially disabling eager preload
  // for a signal that is actually fine.
  group('stale pending signal TTL (T133)', () {
    test(
        'a pending signal older than maxPendingSignalAge is treated as expired '
        '— no sample recorded, entry cleared', () async {
      var now = DateTime(2026, 1, 1, 12, 0, 0);
      final staleAwarePrefetcher = JourneyPrefetcher(
        maxHoldDuration: const Duration(minutes: 5),
        debugClock: () => now,
      );
      addTearDown(staleAwarePrefetcher.dispose);

      staleAwarePrefetcher.notifySignal(
          'levelStarted', AdSlotType.interstitial);

      // Simulate a long backgrounding — well past maxHoldDuration — before
      // an (unrelated) interstitial finally shows.
      now = now.add(const Duration(hours: 2));

      AdManager().debugEmit(const AdShowEvent(
        providerTag: '[Fake]',
        type: AdSlotType.interstitial,
        placement: AdPlacement.unspecified,
        success: true,
      ));
      await Future<void>.delayed(Duration.zero);

      expect(
        staleAwarePrefetcher.averageTimeToShow(
            'levelStarted', AdSlotType.interstitial),
        isNull,
        reason: 'a 2-hour-old pending signal must not be recorded as a '
            '2-hour time-to-show sample — it must be discarded as stale, '
            'not folded into the rolling average',
      );
    });

    test(
        'a pending signal younger than maxPendingSignalAge still records a '
        'normal sample (TTL must not fire on ordinary timing)', () async {
      var now = DateTime(2026, 1, 1, 12, 0, 0);
      final staleAwarePrefetcher = JourneyPrefetcher(
        maxHoldDuration: const Duration(minutes: 5),
        debugClock: () => now,
      );
      addTearDown(staleAwarePrefetcher.dispose);

      staleAwarePrefetcher.notifySignal(
          'levelStarted', AdSlotType.interstitial);
      now = now.add(const Duration(seconds: 30)); // well within 5 minutes

      AdManager().debugEmit(const AdShowEvent(
        providerTag: '[Fake]',
        type: AdSlotType.interstitial,
        placement: AdPlacement.unspecified,
        success: true,
      ));
      await Future<void>.delayed(Duration.zero);

      final avg = staleAwarePrefetcher.averageTimeToShow(
          'levelStarted', AdSlotType.interstitial);
      expect(avg, isNotNull);
      expect(avg!.inSeconds, 30);
    });

    test('an expired pending signal is cleared even though it is never '
        'sampled — a later notifySignal for the same key starts fresh, '
        'not blocked by the stale entry', () async {
      var now = DateTime(2026, 1, 1, 12, 0, 0);
      final staleAwarePrefetcher = JourneyPrefetcher(
        maxHoldDuration: const Duration(minutes: 5),
        debugClock: () => now,
      );
      addTearDown(staleAwarePrefetcher.dispose);

      staleAwarePrefetcher.notifySignal(
          'levelStarted', AdSlotType.interstitial);
      now = now.add(const Duration(hours: 2));
      AdManager().debugEmit(const AdShowEvent(
        providerTag: '[Fake]',
        type: AdSlotType.interstitial,
        placement: AdPlacement.unspecified,
        success: true,
      ));
      await Future<void>.delayed(Duration.zero);

      // A fresh signal + a prompt (non-stale) show afterwards.
      staleAwarePrefetcher.notifySignal(
          'levelStarted', AdSlotType.interstitial);
      now = now.add(const Duration(seconds: 5));
      AdManager().debugEmit(const AdShowEvent(
        providerTag: '[Fake]',
        type: AdSlotType.interstitial,
        placement: AdPlacement.unspecified,
        success: true,
      ));
      await Future<void>.delayed(Duration.zero);

      final avg = staleAwarePrefetcher.averageTimeToShow(
          'levelStarted', AdSlotType.interstitial);
      expect(avg, isNotNull);
      expect(avg!.inSeconds, 5,
          reason: 'only the fresh 5s sample should count — the earlier '
              'stale/expired entry must not have lingered to conflate '
              'averages once a new signal arrived');
    });
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

  // T139 — opt-in auto-mode: notifySignal() fired automatically from real
  // route pushes, using the route's own name, instead of requiring the
  // host to call notifySignal() by hand at every journey point.
  group('autoRouteSignal (T139)', () {
    test('autoRouteSignalType: null (the default) — routeObserver is null',
        () {
      final p = JourneyPrefetcher();
      expect(p.routeObserver, isNull);
      p.dispose();
    });

    test('autoRouteSignalType set — routeObserver is a real NavigatorObserver',
        () {
      final p =
          JourneyPrefetcher(autoRouteSignalType: AdSlotType.interstitial);
      expect(p.routeObserver, isA<NavigatorObserver>());
      p.dispose();
    });

    // `MaterialApp(home: ...)` assigns the initial route the name '/' —
    // which would ALSO auto-fire (correctly! any named route does, home
    // included) and confound these tests' own assertions about the
    // SECOND, explicitly-pushed route. `onGenerateRoute` sidesteps that by
    // building the initial route with no name of its own.
    Widget hostApp(NavigatorObserver observer) => MaterialApp(
          navigatorObservers: [observer],
          onGenerateRoute: (_) => MaterialPageRoute(
            settings: const RouteSettings(),
            builder: (_) => const Scaffold(body: Text('home')),
          ),
        );

    testWidgets(
        'pushing a NAMED route auto-fires notifySignal using the route '
        'name — triggers a real preload just like a manual call would',
        (tester) async {
      final autoPrefetcher =
          JourneyPrefetcher(autoRouteSignalType: AdSlotType.interstitial);
      addTearDown(autoPrefetcher.dispose);

      await tester.pumpWidget(hostApp(autoPrefetcher.routeObserver!));

      expect(adapter.interstitialSlot.isIdle, isTrue,
          reason: 'sanity: the unnamed initial route must not have fired '
              'anything on its own');

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.push(MaterialPageRoute(
        settings: const RouteSettings(name: 'level_complete'),
        builder: (_) => const Scaffold(body: Text('next')),
      ));
      await tester.pumpAndSettle();

      expect(adapter.interstitialSlot.isReady, isTrue,
          reason: 'the route push must have auto-fired notifySignal('
              '"level_complete", AdSlotType.interstitial) exactly like a '
              'manual call would');
    });

    testWidgets(
        'pushing an UNNAMED route does not throw and does not fire any '
        'signal (nothing to key it by)', (tester) async {
      final autoPrefetcher =
          JourneyPrefetcher(autoRouteSignalType: AdSlotType.interstitial);
      addTearDown(autoPrefetcher.dispose);

      await tester.pumpWidget(hostApp(autoPrefetcher.routeObserver!));

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.push(MaterialPageRoute(
        // No `settings.name` — the default.
        builder: (_) => const Scaffold(body: Text('next')),
      ));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(adapter.interstitialSlot.isIdle, isTrue,
          reason: 'an unnamed route has no signal value to key by — must '
              'be silently skipped, not crash or fall back to some other '
              'placeholder value');
    });

    testWidgets(
        'manual notifySignal() and auto-route-signal for the SAME route '
        'name are NOT deduped — the LATER (auto) call\'s timestamp is what '
        'actually gets used for the sample, proving it was really '
        'received rather than silently ignored', (tester) async {
      var now = DateTime(2026, 1, 1, 12, 0, 0);
      final autoPrefetcher = JourneyPrefetcher(
        autoRouteSignalType: AdSlotType.interstitial,
        debugClock: () => now,
      );
      addTearDown(autoPrefetcher.dispose);

      await tester.pumpWidget(hostApp(autoPrefetcher.routeObserver!));

      // Manual call at t0.
      autoPrefetcher.notifySignal('level_complete', AdSlotType.interstitial);

      // Auto call (via the route push) at t1 — a real, later, independent
      // signal for the exact same key.
      now = now.add(const Duration(seconds: 10));
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.push(MaterialPageRoute(
        settings: const RouteSettings(name: 'level_complete'),
        builder: (_) => const Scaffold(body: Text('next')),
      ));
      await tester.pumpAndSettle();

      // Matching show lands at t2 — 5s after the AUTO call, not 15s after
      // the manual one.
      now = now.add(const Duration(seconds: 5));
      AdManager().debugEmit(const AdShowEvent(
        providerTag: '[Fake]',
        type: AdSlotType.interstitial,
        placement: AdPlacement.unspecified,
        success: true,
      ));
      await tester.pump();

      final avg = autoPrefetcher.averageTimeToShow(
          'level_complete', AdSlotType.interstitial);
      expect(avg, isNotNull);
      expect(avg!.inSeconds, 5,
          reason: 'if the auto call had been silently deduped/ignored in '
              'favor of the earlier manual one, this would read 15s '
              '(measured from t0) instead of 5s (measured from t1) — a '
              'dedupe bug would make this test fail, not just avoid a '
              'crash');
    });
  });
}
