// T123 — JourneyPrefetcher unit tests. Uses FakeAdProviderAdapter (T118) so
// notifySignal()'s calls into AdManager().loadX() actually move a slot
// through its real state machine, not just a mock expectation.

import 'dart:convert';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeAdProviderAdapter adapter;
  late JourneyPrefetcher prefetcher;

  setUp(() async {
    // T183 — the default JourneyPrefetcher() now persists across sessions
    // (see the constructor's `persist` doc comment), which touches
    // AdPreferences/SharedPreferences internally.
    SharedPreferences.setMockInitialValues({});
    AdPreferences.resetForTest();
    adapter = FakeAdProviderAdapter();
    AdManager().debugSetAdapter(adapter);
    prefetcher = JourneyPrefetcher();
    // The event listener only attaches once hydration finishes (avoids a
    // real race where a live event could arrive before hydrate and get
    // clobbered by it) — every test here calls notifySignal() right after
    // construction, so it must wait for `ready` first or those calls would
    // have no subscriber yet to reach.
    await prefetcher.ready;
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
    await shortHold.ready;

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
    await tiedPrefetcher.ready;

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
      await staleAwarePrefetcher.ready;

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
      await staleAwarePrefetcher.ready;

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
      await staleAwarePrefetcher.ready;

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
        () async {
      final p = JourneyPrefetcher();
      await p.ready;
      expect(p.routeObserver, isNull);
      await p.dispose();
    });

    test('autoRouteSignalType set — routeObserver is a real NavigatorObserver',
        () async {
      final p =
          JourneyPrefetcher(autoRouteSignalType: AdSlotType.interstitial);
      await p.ready;
      expect(p.routeObserver, isA<NavigatorObserver>());
      await p.dispose();
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
      await autoPrefetcher.ready;

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
      await autoPrefetcher.ready;

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
      await autoPrefetcher.ready;

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

    // T198 — before this, the route observer only ever fired on didPush,
    // silently missing a journey signal on returning to a previous
    // screen (didPop) or on a route swap (didReplace).
    testWidgets(
        'popping back to a NAMED previous route auto-fires notifySignal '
        'using the REVEALED route\'s name — not the one being removed',
        (tester) async {
      final autoPrefetcher =
          JourneyPrefetcher(autoRouteSignalType: AdSlotType.interstitial);
      addTearDown(autoPrefetcher.dispose);
      await autoPrefetcher.ready;

      await tester.pumpWidget(MaterialApp(
        navigatorObservers: [autoPrefetcher.routeObserver!],
        onGenerateRoute: (_) => MaterialPageRoute(
          settings: const RouteSettings(name: 'home_screen'),
          builder: (_) => const Scaffold(body: Text('home')),
        ),
      ));
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.push(MaterialPageRoute(
        // Unnamed on purpose — the push itself must not be what fires
        // the signal this test asserts on; only the pop back to the
        // NAMED 'home_screen' route should.
        builder: (_) => const Scaffold(body: Text('detail')),
      ));
      await tester.pumpAndSettle();
      // Consume whatever the initial 'home_screen' push at app start
      // already fired, so only the POP's own signal is being measured.
      adapter.interstitialSlot.beginShow();
      adapter.interstitialSlot.markDismissed();
      expect(adapter.interstitialSlot.isIdle, isTrue);

      navigator.pop();
      await tester.pumpAndSettle();

      expect(adapter.interstitialSlot.isReady, isTrue,
          reason: 'popping back to "home_screen" must auto-fire '
              'notifySignal("home_screen", interstitial) — the REVEALED '
              'route, not the unnamed one being removed');
    });

    testWidgets(
        'popping to reveal an UNNAMED previous route does not throw and '
        'does not fire any signal', (tester) async {
      final autoPrefetcher =
          JourneyPrefetcher(autoRouteSignalType: AdSlotType.interstitial);
      addTearDown(autoPrefetcher.dispose);
      await autoPrefetcher.ready;

      await tester.pumpWidget(hostApp(autoPrefetcher.routeObserver!));
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.push(MaterialPageRoute(
        settings: const RouteSettings(name: 'level_complete'),
        builder: (_) => const Scaffold(body: Text('next')),
      ));
      await tester.pumpAndSettle();
      // Consume the push's own signal so only the pop is measured.
      adapter.interstitialSlot.beginShow();
      adapter.interstitialSlot.markDismissed();

      navigator.pop();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(adapter.interstitialSlot.isIdle, isTrue,
          reason: 'the revealed initial route is unnamed (see hostApp) — '
              'nothing to key a signal by');
    });

    testWidgets(
        'replacing the current route with a NAMED one auto-fires '
        'notifySignal for the NEW route, not the one being replaced',
        (tester) async {
      final autoPrefetcher =
          JourneyPrefetcher(autoRouteSignalType: AdSlotType.interstitial);
      addTearDown(autoPrefetcher.dispose);
      await autoPrefetcher.ready;

      await tester.pumpWidget(hostApp(autoPrefetcher.routeObserver!));
      expect(adapter.interstitialSlot.isIdle, isTrue,
          reason: 'sanity: the unnamed initial route fired nothing');

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.pushReplacement(MaterialPageRoute(
        settings: const RouteSettings(name: 'level_complete'),
        builder: (_) => const Scaffold(body: Text('replacement')),
      ));
      await tester.pumpAndSettle();

      expect(adapter.interstitialSlot.isReady, isTrue,
          reason: 'a route replacement must auto-fire notifySignal('
              '"level_complete", interstitial) for the NEW route');
    });
  });

  // T162 — the internal key is built as '$signal|${type.name}' (see _key);
  // a signal string that itself contains '|' (a route name like
  // '/store|deal', or any host-chosen signal string) used to break the
  // matching logic entirely, because it split the key on EVERY '|'
  // instead of only the last one.
  group('signal containing a literal "|" (T162)', () {
    test('still matches and records a normal rolling-average sample',
        () async {
      const signal = '/store|deal';
      prefetcher.notifySignal(signal, AdSlotType.interstitial);
      await Future<void>.delayed(const Duration(milliseconds: 5));

      AdManager().debugEmit(const AdShowEvent(
        providerTag: '[Fake]',
        type: AdSlotType.interstitial,
        placement: AdPlacement.unspecified,
        success: true,
      ));
      await Future<void>.delayed(Duration.zero);

      final avg = prefetcher.averageTimeToShow(signal, AdSlotType.interstitial);
      expect(avg, isNotNull,
          reason: 'T162 — a signal containing "|" must still match its own '
              'entry and record a sample, not be silently skipped forever');
      expect(avg!.inMilliseconds, greaterThanOrEqualTo(0));
    });

    test('does not cross-match a DIFFERENT signal that happens to share a '
        'prefix up to a "|"', () async {
      // '/store' (no pipe) and '/store|deal' (with one) must be tracked as
      // two entirely separate keys, not accidentally merged by a
      // last-index-of-'|' split that's too permissive.
      prefetcher.notifySignal('/store', AdSlotType.interstitial);
      prefetcher.notifySignal('/store|deal', AdSlotType.rewarded);
      await Future<void>.delayed(const Duration(milliseconds: 5));

      AdManager().debugEmit(const AdShowEvent(
        providerTag: '[Fake]',
        type: AdSlotType.rewarded,
        placement: AdPlacement.unspecified,
        success: true,
      ));
      await Future<void>.delayed(Duration.zero);

      expect(
          prefetcher.averageTimeToShow('/store|deal', AdSlotType.rewarded),
          isNotNull);
      expect(prefetcher.averageTimeToShow('/store', AdSlotType.interstitial),
          isNull,
          reason: 'the rewarded show must not have been credited to the '
              'unrelated, still-pending interstitial signal');
    });

    test('multiple "|" characters in the signal are all treated as part of '
        'the signal, not the type separator', () async {
      const signal = 'a|b|c|d';
      prefetcher.notifySignal(signal, AdSlotType.interstitial);
      await Future<void>.delayed(const Duration(milliseconds: 5));

      AdManager().debugEmit(const AdShowEvent(
        providerTag: '[Fake]',
        type: AdSlotType.interstitial,
        placement: AdPlacement.unspecified,
        success: true,
      ));
      await Future<void>.delayed(Duration.zero);

      expect(prefetcher.averageTimeToShow(signal, AdSlotType.interstitial),
          isNotNull);
    });
  });

  group('cross-session persistence (T183)', () {
    Future<void> recordSample(JourneyPrefetcher p, String signal) async {
      p.notifySignal(signal, AdSlotType.interstitial);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      AdManager().debugEmit(const AdShowEvent(
        providerTag: '[Fake]',
        type: AdSlotType.interstitial,
        placement: AdPlacement.unspecified,
        success: true,
      ));
      await Future<void>.delayed(Duration.zero);
    }

    test(
        'a sample recorded by one instance is visible to a brand-new '
        'instance backed by the same persisted store — cross-session '
        'accumulation, not lost on "restart"', () async {
      await recordSample(prefetcher, 'levelStarted');
      expect(
          prefetcher.averageTimeToShow('levelStarted', AdSlotType.interstitial),
          isNotNull,
          reason: 'sanity: session A itself recorded the sample');

      // dispose() awaits its own pending write — the exact mechanism this
      // relies on to guarantee session B actually sees it below.
      await prefetcher.dispose();

      // Session B: a brand-new instance (as a real cold start would
      // create) reading the SAME persisted SharedPreferences store.
      final sessionB = JourneyPrefetcher();
      addTearDown(sessionB.dispose);
      await sessionB.ready;

      expect(
        sessionB.averageTimeToShow('levelStarted', AdSlotType.interstitial),
        isNotNull,
        reason: 'session A\'s sample must have hydrated into session B — '
            'this is the entire point of T183',
      );
    });

    test(
        'hydrating a persisted history longer than this instance\'s '
        'rolling window trims it down, not scores on the full history',
        () async {
      // Write a persisted blob with more samples than _rollingWindowSize
      // (10) directly — bypassing a real instance, since one always trims
      // its OWN in-memory list as it goes (simulates a blob from a
      // differently-configured session, or corrupted/oversized some other
      // way).
      final prefs = await AdPreferences.getInstance();
      await prefs.setJourneyPrefetcherStateRaw(jsonEncode({
        'levelStarted|interstitial':
            List.filled(20, const Duration(hours: 1).inMilliseconds),
      }));

      final hydrated = JourneyPrefetcher();
      addTearDown(hydrated.dispose);
      await hydrated.ready;

      final avg =
          hydrated.averageTimeToShow('levelStarted', AdSlotType.interstitial);
      expect(avg, isNotNull);
      // 20 stale 1-hour samples, correctly trimmed to the newest 10 before
      // load — still 1 hour each (the fixture has no variation), so this
      // mainly proves load() didn't throw/skip on an over-length blob. The
      // real trim-correctness proof is the newer test right below.
      expect(avg!.inHours, 1);
    });

    test(
        'the OLDEST samples are the ones dropped on trim, not the newest',
        () async {
      final prefs = await AdPreferences.getInstance();
      // 15 old 1-hour samples followed by 1 recent 1-minute sample — only
      // the newest 10 should survive a rollingWindowSize=10 hydrate, and
      // the 1-minute one (added last) must be among them.
      await prefs.setJourneyPrefetcherStateRaw(jsonEncode({
        'levelStarted|interstitial': [
          ...List.filled(15, const Duration(hours: 1).inMilliseconds),
          const Duration(minutes: 1).inMilliseconds,
        ],
      }));

      final hydrated = JourneyPrefetcher();
      addTearDown(hydrated.dispose);
      await hydrated.ready;

      final avg =
          hydrated.averageTimeToShow('levelStarted', AdSlotType.interstitial);
      expect(avg, isNotNull);
      // Trimmed to the newest 10 (9 hour-long + the 1-minute one) averages
      // to exactly 54 minutes. If the OLDEST were kept instead (or nothing
      // were trimmed at all — 16 samples), the 1-minute entry would be
      // diluted much less precisely: 56 minutes (16, untrimmed) or exactly
      // 1 hour (10 oldest, no 1-minute sample survives at all). Asserting
      // the exact minute count — not just "below 1 hour" — is what
      // actually pins down WHICH end got trimmed, not merely that some
      // trimming happened.
      expect(avg!.inMinutes, 54,
          reason: 'newest-10 trim must keep the 1-minute sample (added '
              'last) and drop 6 of the 15 hour-long ones (added first) — '
              'a different trim direction or no trim at all would land on '
              'a different exact average');
    });

    test('malformed persisted JSON is a fail-safe empty start, not a throw',
        () async {
      final prefs = await AdPreferences.getInstance();
      await prefs.setJourneyPrefetcherStateRaw('{not valid json');

      expect(() async {
        final p = JourneyPrefetcher();
        await p.ready;
        expect(
            p.averageTimeToShow('levelStarted', AdSlotType.interstitial),
            isNull);
        await p.dispose();
      }, returnsNormally);
    });

    test('dispose() awaits the in-flight persisted write — the last '
        'event before disposing is not lost', () async {
      prefetcher.notifySignal('levelStarted', AdSlotType.interstitial);
      AdManager().debugEmit(const AdShowEvent(
        providerTag: '[Fake]',
        type: AdSlotType.interstitial,
        placement: AdPlacement.unspecified,
        success: true,
      ));
      // One microtask turn for the stream-delivery step only — no delay
      // for the persisted write itself: dispose() is the thing under test
      // that must wait for it.
      await Future<void>.delayed(Duration.zero);
      await prefetcher.dispose();

      final prefs = await AdPreferences.getInstance();
      final raw = prefs.getJourneyPrefetcherStateRaw();
      expect(raw, isNotNull);
      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      expect(decoded['levelStarted|interstitial'], hasLength(1),
          reason: 'the sample must have reached disk by the time '
              'dispose() returns');
    });

    test('persist: false never writes anything to disk', () async {
      final p = JourneyPrefetcher(persist: false);
      addTearDown(p.dispose);
      await p.ready;

      await recordSample(p, 'levelStarted');

      final prefs = await AdPreferences.getInstance();
      expect(prefs.getJourneyPrefetcherStateRaw(), isNull);
    });

    // Audit finding (self-review, no codex available this session) — T183
    // gave dispose() async persisted-write-flush semantics, but
    // AdManager._destroy() still called it as `_journeyPrefetcher?.dispose();`
    // without awaiting the returned Future, discarding a pending write —
    // exactly the T136-class bug destroy() already has a documented,
    // working fix for on _waterfallTuner/_selfHealingObserver two lines
    // above the spot that was missed.
    //
    // Known limitation, disclosed rather than hidden: under
    // flutter_test's mocked SharedPreferences, the write can finish
    // before this assertion runs even WITHOUT the fix (confirmed via
    // revert-and-confirm — this exact test still passed with the
    // `await` removed), so this test alone doesn't airtight-prove the
    // fix. The fix mirrors the already-reviewed, already-shipped
    // tunerToFlush/observerToFlush pattern two lines above it, which is
    // the actual basis for confidence here.
    test(
        'AdManager().destroy() awaits the registered prefetcher\'s '
        'pending persisted write — the last sample before destroy() is '
        'not lost', () async {
      final registered = JourneyPrefetcher();
      await registered.ready;
      AdManager().enableJourneyPrefetcher(registered);

      registered.notifySignal('levelStarted', AdSlotType.interstitial);
      AdManager().debugEmit(const AdShowEvent(
        providerTag: '[Fake]',
        type: AdSlotType.interstitial,
        placement: AdPlacement.unspecified,
        success: true,
      ));
      // One microtask turn for the stream-delivery step only — no delay
      // for the persisted write itself: destroy() is the thing under
      // test that must wait for it.
      await Future<void>.delayed(Duration.zero);
      await AdManager().destroy();

      final prefs = await AdPreferences.getInstance();
      final raw = prefs.getJourneyPrefetcherStateRaw();
      expect(raw, isNotNull);
      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      expect(decoded['levelStarted|interstitial'], hasLength(1),
          reason: 'the sample must have reached disk by the time '
              'AdManager().destroy() returns, not be silently dropped');
    });
  });
}
