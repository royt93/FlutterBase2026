// Unit tests for the iOS App Tracking Transparency (ATT) flow.
//
// `requestAttIfNeeded` depends on `Platform.isIOS` and the
// `app_tracking_transparency` plugin's static method-channel calls, none of
// which are reachable from the pure-Dart test environment. The function
// therefore exposes optional `*Override` parameters (matching the
// FirstInstallGuard convention) so each branch can be driven deterministically.
// Production callers use `requestAttIfNeeded()` with no args.
//
// What's covered:
//   • allowsTracking semantics for every AttStatus.
//   • Non-iOS short-circuits to notSupported (no plugin call).
//   • notDetermined → prompt is shown, result mapped.
//   • Already-decided status returns WITHOUT re-prompting.
//   • IDFA is read only when authorized; zero/empty IDFA normalised to null.
//   • denied/restricted yield null IDFA.
//   • Any thrown error degrades to denied (never rethrows).

import 'dart:async';

import 'package:app_tracking_transparency/app_tracking_transparency.dart';
import 'package:applovin_admob_sdk/src/core/att_consent.dart';
import 'package:applovin_admob_sdk/src/core/ump_consent.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

const _zeroIdfa = '00000000-0000-0000-0000-000000000000';
const _realIdfa = 'ABCDEF12-3456-7890-ABCD-EF1234567890';

void main() {
  // Round-31 audit fix — requestAttIfNeeded() now has the side effect of
  // marking `umpFormOnScreen` (module-level global, shared across every
  // test in this process). A test that parks a `Completer` and never
  // completes it (the "prompt hang timeout" test below, deliberately)
  // leaves that mark set forever otherwise, bleeding into whichever test
  // runs next.
  tearDown(resetUmpFormOnScreen);
  // T161 — same reasoning, for the duplicate-call guard: it stays held
  // until the RAW native future settles (see requestAttIfNeeded's doc
  // comment), which the SAME abandoned-Completer tests above never do.
  tearDown(resetPendingAttRequest);

  group('AttResult.allowsTracking', () {
    test('true for authorized', () {
      expect(
          const AttResult(status: AttStatus.authorized).allowsTracking, isTrue);
    });
    test('true for notSupported (ATT does not apply)', () {
      expect(const AttResult(status: AttStatus.notSupported).allowsTracking,
          isTrue);
    });
    test('false for denied / restricted / notDetermined', () {
      expect(const AttResult(status: AttStatus.denied).allowsTracking, isFalse);
      expect(const AttResult(status: AttStatus.restricted).allowsTracking,
          isFalse);
      expect(const AttResult(status: AttStatus.notDetermined).allowsTracking,
          isFalse);
    });
  });

  group('requestAttIfNeeded — non-iOS', () {
    test('returns notSupported and never touches the plugin', () async {
      var pluginCalled = false;
      final result = await requestAttIfNeeded(
        platformIsIosOverride: () => false,
        readStatusOverride: () async {
          pluginCalled = true;
          return TrackingStatus.authorized;
        },
      );
      expect(result.status, AttStatus.notSupported);
      expect(result.idfa, isNull);
      expect(pluginCalled, isFalse,
          reason: 'non-iOS must short-circuit before any plugin call');
    });
  });

  group('requestAttIfNeeded — iOS notDetermined → prompt', () {
    test('shows the prompt and maps an authorized result with IDFA', () async {
      var promptShown = false;
      final result = await requestAttIfNeeded(
        platformIsIosOverride: () => true,
        readStatusOverride: () async => TrackingStatus.notDetermined,
        requestAuthorizationOverride: () async {
          promptShown = true;
          return TrackingStatus.authorized;
        },
        readIdfaOverride: () async => _realIdfa,
      );
      expect(promptShown, isTrue);
      expect(result.status, AttStatus.authorized);
      expect(result.idfa, _realIdfa);
      expect(result.allowsTracking, isTrue);
    });

    test('maps a denied prompt result with null IDFA', () async {
      var idfaRead = false;
      final result = await requestAttIfNeeded(
        platformIsIosOverride: () => true,
        readStatusOverride: () async => TrackingStatus.notDetermined,
        requestAuthorizationOverride: () async => TrackingStatus.denied,
        readIdfaOverride: () async {
          idfaRead = true;
          return _realIdfa;
        },
      );
      expect(result.status, AttStatus.denied);
      expect(result.idfa, isNull);
      expect(idfaRead, isFalse, reason: 'IDFA is only read when authorized');
    });
  });

  group('requestAttIfNeeded — iOS already decided', () {
    test('authorized status returns without re-prompting', () async {
      var promptShown = false;
      final result = await requestAttIfNeeded(
        platformIsIosOverride: () => true,
        readStatusOverride: () async => TrackingStatus.authorized,
        requestAuthorizationOverride: () async {
          promptShown = true;
          return TrackingStatus.denied;
        },
        readIdfaOverride: () async => _realIdfa,
      );
      expect(promptShown, isFalse,
          reason: 'Apple only allows the prompt once; cached status is reused');
      expect(result.status, AttStatus.authorized);
      expect(result.idfa, _realIdfa);
    });

    test('restricted status maps through with null IDFA', () async {
      final result = await requestAttIfNeeded(
        platformIsIosOverride: () => true,
        readStatusOverride: () async => TrackingStatus.restricted,
      );
      expect(result.status, AttStatus.restricted);
      expect(result.idfa, isNull);
      expect(result.allowsTracking, isFalse);
    });
  });

  group('requestAttIfNeeded — IDFA normalisation', () {
    test('all-zero IDFA is normalised to null even when authorized', () async {
      final result = await requestAttIfNeeded(
        platformIsIosOverride: () => true,
        readStatusOverride: () async => TrackingStatus.authorized,
        readIdfaOverride: () async => _zeroIdfa,
      );
      expect(result.status, AttStatus.authorized);
      expect(result.idfa, isNull,
          reason: 'zero IDFA means tracking unavailable');
    });

    test('empty IDFA string is normalised to null', () async {
      final result = await requestAttIfNeeded(
        platformIsIosOverride: () => true,
        readStatusOverride: () async => TrackingStatus.authorized,
        readIdfaOverride: () async => '',
      );
      expect(result.idfa, isNull);
    });
  });

  group('requestAttIfNeeded — error degradation', () {
    test('status read throwing degrades to denied (never rethrows)', () async {
      final result = await requestAttIfNeeded(
        platformIsIosOverride: () => true,
        readStatusOverride: () async => throw StateError('plugin missing'),
      );
      expect(result.status, AttStatus.denied);
      expect(result.idfa, isNull);
    });

    test('prompt throwing degrades to denied', () async {
      final result = await requestAttIfNeeded(
        platformIsIosOverride: () => true,
        readStatusOverride: () async => TrackingStatus.notDetermined,
        // `.timeout()` reifies T from the Future's own runtime type; an
        // `async => throw` literal infers Future<Never> instead of
        // Future<TrackingStatus>, which breaks the onTimeout signature.
        // Future<T>.error(...) keeps the type explicit.
        requestAuthorizationOverride: () =>
            Future<TrackingStatus>.error(StateError('channel error')),
      );
      expect(result.status, AttStatus.denied);
    });

    // codex re-review (T161, P2) — platformIsIosOverride() (and Platform.isIOS
    // in real code) is called before any prompt is ever shown; a throw here
    // has no native interaction to wait for, so the duplicate-call guard
    // must still release immediately, not hang forever.
    test('platformIsIosOverride() itself throwing degrades to denied AND '
        'releases the duplicate-call guard immediately', () async {
      final result = await requestAttIfNeeded(
        platformIsIosOverride: () => throw StateError('platform check failed'),
      );
      expect(result.status, AttStatus.denied);

      // If the guard were stuck, this second call would hang forever
      // joining a completer that never resolves — timeout proves it didn't.
      final second = await requestAttIfNeeded(
        platformIsIosOverride: () => true,
        readStatusOverride: () async => TrackingStatus.authorized,
      ).timeout(const Duration(seconds: 5));
      expect(second.status, AttStatus.authorized);
    });
  });

  group('requestAttIfNeeded — prompt hang timeout', () {
    test('a prompt that never resolves times out after 20s as notDetermined',
        () {
      fakeAsync((async) {
        AttResult? result;
        requestAttIfNeeded(
          platformIsIosOverride: () => true,
          readStatusOverride: () async => TrackingStatus.notDetermined,
          // Never completes — simulates the OS never presenting/dismissing
          // the native prompt (observed on iOS Simulator).
          requestAuthorizationOverride: () =>
              Completer<TrackingStatus>().future,
        ).then((r) => result = r);

        async.elapse(const Duration(seconds: 20));

        expect(result, isNotNull,
            reason: 'requestAttIfNeeded must not hang forever');
        expect(result!.status, AttStatus.notDetermined);
      });
    });
  });

  // Round-31 audit (MAJOR) — the ATT prompt is a native, non-Flutter-route
  // dialog with no `AdScreenRouteLogger`/App-Open-resume visibility, same
  // as a UMP form. Reuses `markUmpFormOnScreen`'s exact ref-counted/
  // backstopped mutex rather than a parallel mechanism.
  group('requestAttIfNeeded — fullscreen-ad mutex (round-31)', () {
    test('umpFormOnScreen is true while the native prompt is up, and false '
        'once it actually resolves', () async {
      final promptCompleter = Completer<TrackingStatus>();
      expect(umpFormOnScreen.value, isFalse, reason: 'sanity: starts clear');

      final resultFuture = requestAttIfNeeded(
        platformIsIosOverride: () => true,
        readStatusOverride: () async => TrackingStatus.notDetermined,
        requestAuthorizationOverride: () => promptCompleter.future,
      );
      await Future<void>.delayed(Duration.zero);

      expect(umpFormOnScreen.value, isTrue,
          reason: 'a fullscreen ad must not be able to show over the '
              'native ATT alert');

      promptCompleter.complete(TrackingStatus.authorized);
      await resultFuture;

      expect(umpFormOnScreen.value, isFalse,
          reason: 'must release once the alert genuinely resolves');
    });

    // Round 52 audit fix (MAJOR) — same bug class ump_consent.dart's
    // requestPrivacyOptionsFlow() already had to fix (round-8 QC): a
    // SYNCHRONOUS throw out of the request call, before it even returns a
    // Future, used to skip every release path tied to `.whenComplete()` on
    // that Future, leaving the mutex held until the 15-minute backstop.
    test(
        'a SYNCHRONOUS throw from requestAuthorization still releases the '
        'mutex, not just an async failure', () async {
      expect(umpFormOnScreen.value, isFalse, reason: 'sanity: starts clear');

      final result = await requestAttIfNeeded(
        platformIsIosOverride: () => true,
        readStatusOverride: () async => TrackingStatus.notDetermined,
        requestAuthorizationOverride: () =>
            throw StateError('plugin not registered'),
      );

      expect(result.status, AttStatus.denied,
          reason: 'degrades to denied rather than crashing the caller');
      expect(umpFormOnScreen.value, isFalse,
          reason: 'must not leave the fullscreen-ad mutex held for the '
              '15-minute backstop when the request never even reached a '
              'Future to attach a release callback to');
    });

    test(
        'a 20s Dart-side timeout does NOT release the mutex — the native '
        'alert can still be up (same bug class as a UMP form timeout)',
        () {
      fakeAsync((async) {
        final promptCompleter = Completer<TrackingStatus>();
        requestAttIfNeeded(
          platformIsIosOverride: () => true,
          readStatusOverride: () async => TrackingStatus.notDetermined,
          requestAuthorizationOverride: () => promptCompleter.future,
        );
        async.elapse(const Duration(seconds: 20));

        expect(umpFormOnScreen.value, isTrue,
            reason: 'requestAttIfNeeded() returning at the synthetic '
                'timeout must not be mistaken for the native alert having '
                'actually closed — releasing here would let a fullscreen '
                'ad show over a still-visible system alert');

        promptCompleter.complete(TrackingStatus.denied);
        async.flushMicrotasks();

        expect(umpFormOnScreen.value, isFalse,
            reason: 'must still release once the real alert resolves, '
                'however much later than the synthetic timeout');
      });
    });
  });

  // T161 — a second requestAttIfNeeded() call before the first resolves
  // (a caller bug, or a user tapping a "grant permission" button twice)
  // must not present Apple's native prompt a second time.
  group('requestAttIfNeeded — duplicate-call guard (T161)', () {
    test(
        'two overlapping calls before the native prompt resolves only call '
        'native requestAuthorization once, and both callers get the same '
        'result', () async {
      var requestAuthorizationCalls = 0;
      final promptCompleter = Completer<TrackingStatus>();

      final first = requestAttIfNeeded(
        platformIsIosOverride: () => true,
        readStatusOverride: () async => TrackingStatus.notDetermined,
        requestAuthorizationOverride: () {
          requestAuthorizationCalls++;
          return promptCompleter.future;
        },
      );
      // Second call fires before the first has resolved — must join the
      // same in-flight request rather than starting a new one.
      final second = requestAttIfNeeded(
        platformIsIosOverride: () => true,
        readStatusOverride: () async => TrackingStatus.notDetermined,
        requestAuthorizationOverride: () {
          requestAuthorizationCalls++;
          return promptCompleter.future;
        },
      );

      // Let both calls' async bodies actually run up to (and past) the
      // requestAuthorization call — issuing the Future above only starts
      // it; the body suspends at its first `await` (reading status) until
      // the event loop gets a turn.
      await Future<void>.delayed(Duration.zero);
      expect(requestAuthorizationCalls, 1,
          reason: 'T161 — native requestAuthorization must be called at '
              'most once while a request is already in flight');

      promptCompleter.complete(TrackingStatus.authorized);
      final results = await Future.wait([first, second]);

      expect(results[0].status, AttStatus.authorized);
      expect(results[1].status, AttStatus.authorized,
          reason: 'the joined call must resolve with the SAME result as '
              'the in-flight request it joined');
      expect(requestAuthorizationCalls, 1,
          reason: 'still exactly one native call after both resolve');
    });

    test('three overlapping calls all join the same single native call',
        () async {
      var requestAuthorizationCalls = 0;
      final promptCompleter = Completer<TrackingStatus>();
      Future<TrackingStatus> nativeCall() {
        requestAuthorizationCalls++;
        return promptCompleter.future;
      }

      final futures = [
        requestAttIfNeeded(
          platformIsIosOverride: () => true,
          readStatusOverride: () async => TrackingStatus.notDetermined,
          requestAuthorizationOverride: nativeCall,
        ),
        requestAttIfNeeded(
          platformIsIosOverride: () => true,
          readStatusOverride: () async => TrackingStatus.notDetermined,
          requestAuthorizationOverride: nativeCall,
        ),
        requestAttIfNeeded(
          platformIsIosOverride: () => true,
          readStatusOverride: () async => TrackingStatus.notDetermined,
          requestAuthorizationOverride: nativeCall,
        ),
      ];

      await Future<void>.delayed(Duration.zero);
      expect(requestAuthorizationCalls, 1);
      promptCompleter.complete(TrackingStatus.denied);
      final results = await Future.wait(futures);
      expect(results.map((r) => r.status).toSet(), {AttStatus.denied});
      expect(requestAuthorizationCalls, 1);
    });

    // codex re-review (T161, round 2, P2) — the native ATT alert closing
    // is not the end of the work: an `authorized` result still triggers a
    // readIdfa() call afterward. A second call arriving in exactly that
    // window must still join the first, not start a fresh, independent
    // request.
    test(
        'a second call arriving after the native alert closes but WHILE '
        'the IDFA read is still in flight still joins the first call',
        () async {
      var requestAuthorizationCalls = 0;
      var readIdfaCalls = 0;
      final idfaCompleter = Completer<String>();

      final first = requestAttIfNeeded(
        platformIsIosOverride: () => true,
        readStatusOverride: () async => TrackingStatus.notDetermined,
        requestAuthorizationOverride: () {
          requestAuthorizationCalls++;
          return Future.value(TrackingStatus.authorized);
        },
        readIdfaOverride: () {
          readIdfaCalls++;
          return idfaCompleter.future;
        },
      );

      // Give the native alert time to "close" (resolve) and the function
      // to reach its readIdfa() call, which is still pending.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final second = requestAttIfNeeded(
        platformIsIosOverride: () => true,
        readStatusOverride: () async => TrackingStatus.notDetermined,
        requestAuthorizationOverride: () {
          requestAuthorizationCalls++;
          return Future.value(TrackingStatus.authorized);
        },
        readIdfaOverride: () {
          readIdfaCalls++;
          return idfaCompleter.future;
        },
      );

      expect(requestAuthorizationCalls, 1,
          reason: 'T161 (round 2) — the second call must join the first '
              'even though the native alert has already closed, because '
              'the first call\'s OWN result (its IDFA read) has not '
              'finished yet');
      expect(readIdfaCalls, 1);

      idfaCompleter.complete('11111111-2222-3333-4444-555555555555');
      final results = await Future.wait([first, second]);
      expect(results[0].idfa, results[1].idfa);
      expect(requestAuthorizationCalls, 1);
      expect(readIdfaCalls, 1);
    });

    test(
        'a call AFTER the previous one has fully resolved starts a fresh '
        'native request (the guard does not stick around)', () async {
      var requestAuthorizationCalls = 0;
      Future<TrackingStatus> nativeCall() {
        requestAuthorizationCalls++;
        return Future.value(TrackingStatus.authorized);
      }

      await requestAttIfNeeded(
        platformIsIosOverride: () => true,
        readStatusOverride: () async => TrackingStatus.notDetermined,
        requestAuthorizationOverride: nativeCall,
      );
      expect(requestAuthorizationCalls, 1);

      await requestAttIfNeeded(
        platformIsIosOverride: () => true,
        readStatusOverride: () async => TrackingStatus.notDetermined,
        requestAuthorizationOverride: nativeCall,
      );
      expect(requestAuthorizationCalls, 2,
          reason: 'a genuinely NEW request, made after the previous one '
              'already resolved, must not be blocked by a stale guard');
    });
  });
}
