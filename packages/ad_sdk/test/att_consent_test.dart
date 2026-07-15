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
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

const _zeroIdfa = '00000000-0000-0000-0000-000000000000';
const _realIdfa = 'ABCDEF12-3456-7890-ABCD-EF1234567890';

void main() {
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
}
