// T231 — AdManager-level opt-in wiring for the Flight Recorder: default OFF,
// zero overhead when disabled, DisputeKit extension, click-event hook.
import 'dart:async';
import 'dart:convert';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/core/iab_storage.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    AdManager().disableFlightRecorder();
    AdManager().debugConfig = null;
  });

  group('opt-in / default off', () {
    test('flightRecorder is null until enableFlightRecorder is called', () {
      expect(AdManager().flightRecorder, isNull);
    });

    test('recordFlightRecorderEvent no-ops with zero entries when disabled',
        () async {
      await AdManager().recordFlightRecorderEvent(
        label: 'bannerVisible',
        type: AdSlotType.banner,
        placement: AdPlacement.home,
      );

      expect(AdManager().flightRecorder, isNull);
    });

    test('enableFlightRecorder wires a recorder that actually records',
        () async {
      AdManager().enableFlightRecorder(AdFlightRecorder());

      await AdManager().recordFlightRecorderEvent(
        label: 'bannerVisible',
        type: AdSlotType.banner,
        placement: AdPlacement.home,
        viewabilityFraction: 1,
      );

      expect(AdManager().flightRecorder!.entries, hasLength(1));
      expect(AdManager().flightRecorder!.entries.single.label, 'bannerVisible');
      expect(AdManager().flightRecorder!.entries.single.slotType, 'banner');
      expect(AdManager().flightRecorder!.entries.single.placement, 'home');
    });

    test('disableFlightRecorder drops the recorder back to null', () async {
      AdManager().enableFlightRecorder(AdFlightRecorder());
      AdManager().disableFlightRecorder();

      expect(AdManager().flightRecorder, isNull);
    });

    test('a global event (no type/placement) records slotType "global"',
        () async {
      AdManager().enableFlightRecorder(AdFlightRecorder());

      await AdManager().recordFlightRecorderEvent(label: 'consentChanged');

      final entry = AdManager().flightRecorder!.entries.single;
      expect(entry.slotType, 'global');
      expect(entry.placement, '-');
    });
  });

  group('replace / disable lifecycle (T235)', () {
    late AdPreferences prefs;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await AdPreferences.getInstance();
      await prefs.clearAllData();
    });

    // These tests persist real data onto the shared `AdPreferences`
    // singleton (needed to exercise the actual debounce/disk-write race) —
    // without cleaning it back up, later tests in this file that enable a
    // fresh `AdFlightRecorder` auto-`attach()` (via `AdManager
    // .enableFlightRecorder`'s `AdPreferences.instanceOrNull` check) and
    // silently reload this leftover persisted entry.
    tearDown(() async {
      await prefs.clearAllData();
    });

    test('old debounce cannot overwrite a replacement recorder', () async {
      final old = AdFlightRecorder()..attach(prefs);
      AdManager().enableFlightRecorder(old);
      await old.record(
        label: 'old',
        slotType: 'banner',
        placement: 'home',
        providerTag: '[AdMob]',
      );

      final replacement = AdFlightRecorder();
      AdManager().enableFlightRecorder(replacement);
      await replacement.record(
        label: 'new',
        slotType: 'banner',
        placement: 'home',
        providerTag: '[AdMob]',
      );
      await replacement.flush();
      await Future<void>.delayed(const Duration(milliseconds: 1100));

      final persisted = FlightRecorderBundle.fromJsonString(
        prefs.getFlightRecorderRaw()!,
      );
      expect(persisted.entries.map((entry) => entry.label), ['new']);
    });

    test('disable with no pending write is safe and idempotent', () {
      AdManager().enableFlightRecorder(AdFlightRecorder()..attach(prefs));

      AdManager().disableFlightRecorder();
      AdManager().disableFlightRecorder();

      expect(AdManager().flightRecorder, isNull);
    });

    test('rapid enable-disable-enable cycles cancel every old timer', () async {
      final active = AdFlightRecorder();
      for (var i = 0; i < 3; i++) {
        final stale = AdFlightRecorder()..attach(prefs);
        AdManager().enableFlightRecorder(stale);
        await stale.record(
          label: 'stale-$i',
          slotType: 'banner',
          placement: 'home',
          providerTag: '[AdMob]',
        );
        AdManager().disableFlightRecorder();
      }

      AdManager().enableFlightRecorder(active);
      await active.record(
        label: 'active',
        slotType: 'banner',
        placement: 'home',
        providerTag: '[AdMob]',
      );
      await active.flush();
      await Future<void>.delayed(const Duration(milliseconds: 1100));

      final persisted = FlightRecorderBundle.fromJsonString(
        prefs.getFlightRecorderRaw()!,
      );
      expect(persisted.entries.map((entry) => entry.label), ['active']);
    });
  });

  group('exportSignedFlightRecorderBundle', () {
    test('returns null when the recorder was never enabled', () async {
      expect(await AdManager().exportSignedFlightRecorderBundle(), isNull);
    });

    test('signs an empty bundle when enabled but nothing was recorded yet',
        () async {
      AdManager().enableFlightRecorder(AdFlightRecorder());

      final signed = await AdManager().exportSignedFlightRecorderBundle();

      expect(signed, isNotNull);
      expect(await verifySignedJsonPayload(signed!.toJsonString()), isTrue);
      final bundle = FlightRecorderBundle.fromJsonString(signed.payloadJson);
      expect(bundle.entries, isEmpty);
    });

    test('signs and verifies a bundle with real entries', () async {
      AdManager().enableFlightRecorder(AdFlightRecorder());
      await AdManager().recordFlightRecorderEvent(
        label: 'bannerVisible',
        type: AdSlotType.banner,
        placement: AdPlacement.home,
      );

      final signed = await AdManager().exportSignedFlightRecorderBundle();

      expect(
          await verifySignedFlightRecorderBundle(signed!.toJsonString()),
          isTrue);
    });
  });

  group('DisputeKit.flightRecorderBundle', () {
    test('is null when the flight recorder was never enabled — existing '
        '3-key shape unchanged', () async {
      final kit = await AdManager().exportDisputeKit();

      expect(kit.flightRecorderBundle, isNull);
      final decoded = jsonDecode(kit.toJsonString()) as Map<String, dynamic>;
      expect(decoded.containsKey('flightRecorderBundle'), isFalse);
    });

    test('is populated and independently verifiable when enabled', () async {
      AdManager().enableFlightRecorder(AdFlightRecorder());
      await AdManager().recordFlightRecorderEvent(
        label: 'bannerVisible',
        type: AdSlotType.banner,
        placement: AdPlacement.home,
      );

      final kit = await AdManager().exportDisputeKit();

      expect(kit.flightRecorderBundle, isNotNull);
      expect(
          await verifySignedFlightRecorderBundle(
              jsonEncode(kit.flightRecorderBundle!.toJson())),
          isTrue);
      final decoded = jsonDecode(kit.toJsonString()) as Map<String, dynamic>;
      expect(decoded.containsKey('flightRecorderBundle'), isTrue);
    });
  });

  group('click events feed the flight recorder', () {
    test('an AdClickEvent on AdManager().events records a "clicked" entry '
        'when enabled', () async {
      AdManager().enableFlightRecorder(AdFlightRecorder());
      AdManager().debugEmit(const AdClickEvent(
        providerTag: '[AdMob]',
        type: AdSlotType.interstitial,
        placement: AdPlacement.home,
      ));
      // The click hook is fire-and-forget (unawaited) — give its Future a
      // microtask turn to complete before asserting.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final entries = AdManager().flightRecorder!.entries;
      expect(entries.any((e) => e.label == 'clicked' && e.touchActive), isTrue);
    });

    test('an AdClickEvent is a no-op for the flight recorder when disabled',
        () async {
      AdManager().debugEmit(const AdClickEvent(
        providerTag: '[AdMob]',
        type: AdSlotType.interstitial,
        placement: AdPlacement.home,
      ));
      await Future<void>.delayed(Duration.zero);

      expect(AdManager().flightRecorder, isNull);
    });
  });

  group('clearSdkData clears the live flight recorder', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await AdPreferences.getInstance();
      await prefs.clearAllData();
    });

    test('erases the live in-memory buffer, not just the persisted key',
        () async {
      AdManager().enableFlightRecorder(AdFlightRecorder());
      await AdManager().recordFlightRecorderEvent(
        label: 'bannerVisible',
        type: AdSlotType.banner,
        placement: AdPlacement.home,
      );
      expect(AdManager().flightRecorder!.entries, isNotEmpty);

      await AdManager().clearSdkData();

      expect(AdManager().flightRecorder!.entries, isEmpty,
          reason: 'a live instance must reflect the erasure immediately, '
              'same as ProviderFailoverAdvisor/consent-provenance-journal '
              'do for their own in-memory state');
    });

    test('an in-flight snapshot cannot restore entries after SDK erasure',
        () async {
      final previousStore = SharedPreferencesStorePlatform.instance;
      final store = _GatedFlightStore();
      SharedPreferencesStorePlatform.instance = store;
      SharedPreferences.resetStatic();
      AdPreferences.resetForTest();
      addTearDown(() {
        SharedPreferencesStorePlatform.instance = previousStore;
        SharedPreferences.resetStatic();
        AdPreferences.resetForTest();
      });
      final prefs = await AdPreferences.getInstance();
      final recorder = AdFlightRecorder()..attach(prefs);
      AdManager().enableFlightRecorder(recorder);
      await recorder.record(
        label: 'before-erasure',
        slotType: 'banner',
        placement: 'home',
        providerTag: '[AdMob]',
      );
      final pendingWrite = recorder.flush();
      await store.writeStarted.future;

      var clearDone = false;
      final clearing = AdManager().clearSdkData().whenComplete(() {
        clearDone = true;
      });
      try {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(clearDone, isFalse,
            reason: 'erasure must wait for the already-issued write');
      } finally {
        store.releaseWrite.complete();
      }
      await pendingWrite;
      await clearing;
      expect(recorder.entries, isEmpty);

      SharedPreferences.resetStatic();
      AdPreferences.resetForTest();
      final reloadedPrefs = await AdPreferences.getInstance();
      final reloaded = AdFlightRecorder()..attach(reloadedPrefs);
      addTearDown(reloaded.dispose);
      expect(reloaded.entries, isEmpty,
          reason: 'a snapshot captured before erasure must not return on reload');
    });

    Future<void> rec(AdFlightRecorder r, String label) => r.record(
          label: label,
          slotType: 'banner',
          placement: 'home',
          providerTag: '[AdMob]',
        );

    test('events during erasure are dropped; later events persist fresh',
        () async {
      final prefs = await AdPreferences.getInstance();
      final recorder = AdFlightRecorder()..attach(prefs);
      AdManager().enableFlightRecorder(recorder);
      await rec(recorder, 'old');
      final clearing = AdManager().clearSdkData();
      await rec(recorder, 'during-erasure');
      await AdManager().recordFlightRecorderEvent(label: 'manager-during');
      await recorder.flush();
      await clearing;
      expect(recorder.entries, isEmpty);

      await rec(recorder, 'after');
      await recorder.flush();
      final persisted =
          FlightRecorderBundle.fromJsonString(prefs.getFlightRecorderRaw()!);
      expect(persisted.entries.map((e) => e.label), ['after']);
      expect(persisted.entries.single.previousHash, '');
    });

    test('a hash already in flight when erasure starts cannot append',
        () async {
      final prefs = await AdPreferences.getInstance();
      final recorder = AdFlightRecorder()..attach(prefs);
      final pending = rec(recorder, 'in-flight');
      final clearing = AdManager().clearSdkData();
      await pending;
      await clearing;
      expect(recorder.entries, isEmpty);
      expect(prefs.getFlightRecorderRaw(), isNull);
    });

    test('a widget write whose IAB read crosses erasure is dropped', () async {
      final prefs = await AdPreferences.getInstance();
      final recorder = AdFlightRecorder()..attach(prefs);
      AdManager().enableFlightRecorder(recorder);
      final gate = Completer<SharedPreferencesAsync?>();
      IabStorage.debugResetForTest();
      IabStorage.debugOpenOverride = () => gate.future;
      addTearDown(() {
        IabStorage.debugOpenOverride = null;
        IabStorage.debugResetForTest();
      });

      final pending =
          AdManager().recordFlightRecorderEvent(label: 'pre-erasure');
      await AdManager().clearSdkData();
      gate.complete(null);
      await pending;
      await recorder.flush();
      expect(recorder.entries, isEmpty,
          reason: 'pre-erasure work must not be accepted after reopening');
      final raw = prefs.getFlightRecorderRaw();
      expect(
          raw == null || FlightRecorderBundle.fromJsonString(raw).entries.isEmpty,
          isTrue);
    });

    test('a direct clear() fences a queued record without any SDK erasure',
        () async {
      final recorder = AdFlightRecorder();
      final pending = rec(recorder, 'queued');
      recorder.clear();
      await pending;
      expect(recorder.entries, isEmpty);
      await rec(recorder, 'fresh');
      expect(recorder.entries.single.previousHash, '');
    });

    test('a retired recorder reference cannot resurrect erased entries',
        () async {
      final prefs = await AdPreferences.getInstance();
      final old = AdFlightRecorder()..attach(prefs);
      AdManager().enableFlightRecorder(old);
      await rec(old, 'old');
      await old.flush();
      AdManager().enableFlightRecorder(AdFlightRecorder());
      await AdManager().clearSdkData();
      expect(old.entries, isEmpty);
      expect(prefs.getFlightRecorderRaw(), isNull);
    });

    test('a replacement recorder attached during erasure skips stale disk',
        () async {
      final prefs = await AdPreferences.getInstance();
      final seed = AdFlightRecorder()..attach(prefs);
      await rec(seed, 'seed');
      await seed.flush();
      final clearing = AdManager().clearSdkData();
      final replacement = AdFlightRecorder()..attach(prefs);
      await clearing;
      expect(replacement.entries, isEmpty);
      expect(prefs.getFlightRecorderRaw(), isNull);
    });

    test('overlapping erasures keep the gate shut until the last finishes',
        () async {
      final first = AdManager().clearSdkData();
      final second = AdManager().clearSdkData();
      await first;
      expect(AdPreferences.flightErasing, isTrue);
      await second;
      expect(AdPreferences.flightErasing, isFalse);
    });

    test('a failing flight-key removal still erases other SDK keys', () async {
      final previous = SharedPreferencesStorePlatform.instance;
      SharedPreferencesStorePlatform.instance = _FailingFlightRemoveStore();
      SharedPreferences.resetStatic();
      AdPreferences.resetForTest();
      addTearDown(() {
        SharedPreferencesStorePlatform.instance = previous;
        SharedPreferences.resetStatic();
        AdPreferences.resetForTest();
      });
      final fresh = await AdPreferences.getInstance();
      await expectLater(AdManager().clearSdkData(), throwsStateError);
      expect(fresh.getLastProviderExplorationAtMs(), isNull,
          reason: 'one failing key must not leave the others un-erased');
      expect(AdPreferences.flightErasing, isFalse);
    });

    group('erasure timeout (caller-only)', () {
      late _HeldRemoveStore store;
      late AdPreferences prefs;
      final logs = <String>[];
      const deadline = Duration(milliseconds: 150);

      setUp(() async {
        logs.clear();
        SafeLogger.configure(onLog: (l, t, m) => logs.add(m));
        AdManager().debugErasureTimeout = deadline;
        final previous = SharedPreferencesStorePlatform.instance;
        store = _HeldRemoveStore();
        SharedPreferencesStorePlatform.instance = store;
        SharedPreferences.resetStatic();
        AdPreferences.resetForTest();
        addTearDown(() async {
          store.releaseAll();
          for (var i = 0; i < 200 && AdPreferences.flightErasing; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          expect(AdPreferences.flightErasing, isFalse,
              reason: 'test cleanup must drain every real erasure');
          AdManager().debugErasureTimeout = null;
          SafeLogger.configure();
          SharedPreferencesStorePlatform.instance = previous;
          SharedPreferences.resetStatic();
          AdPreferences.resetForTest();
        });
        prefs = await AdPreferences.getInstance();
      });

      Future<Object?> outcome(Future<void> f) =>
          f.then<Object?>((_) => null, onError: (Object e) => e);

      Future<void> tick() =>
          Future<void>.delayed(const Duration(milliseconds: 20));

      Future<void> held([int n = 1]) async {
        for (var i = 0; i < 200 && store.pending < n; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(store.pending, greaterThanOrEqualTo(n));
      }

      test('timeout keeps the gate shut, drops events, then reopens', () async {
        final recorder = AdFlightRecorder()..attach(prefs);
        final result = outcome(AdManager().clearSdkData());
        await held();
        expect(await result, isA<TimeoutException>());
        expect(AdPreferences.flightErasing, isTrue,
            reason: 'a timeout is not a completed erasure');
        await recorder.record(
            label: 'during',
            slotType: 'banner',
            placement: 'home',
            providerTag: '[AdMob]');
        expect(recorder.entries, isEmpty);

        store.release();
        await tick();
        expect(AdPreferences.flightErasing, isFalse);
        expect(logs.any((m) => m.contains('finished after timeout')), isTrue);
        await recorder.record(
            label: 'after',
            slotType: 'banner',
            placement: 'home',
            providerTag: '[AdMob]');
        expect(recorder.entries.map((e) => e.label), ['after']);
      });

      test('a failure after the timeout is logged, not unhandled', () async {
        final result = outcome(AdManager().clearSdkData());
        expect(await result, isA<TimeoutException>());
        store.release(error: StateError('late failure'));
        await tick();
        expect(AdPreferences.flightErasing, isFalse);
        expect(logs.any((m) => m.contains('failed after timeout')), isTrue);
      });

      test('overlapping erasures hold the gate until the last one ends',
          () async {
        final first = outcome(AdManager().clearSdkData());
        await Future<void>.delayed(const Duration(milliseconds: 60));
        final second = outcome(AdManager().clearSdkData());
        expect(await first, isA<TimeoutException>());
        expect(await second, isA<TimeoutException>());
        expect(AdPreferences.flightErasing, isTrue);

        store.release();
        await tick();
        expect(AdPreferences.flightErasing, isTrue,
            reason: 'the second erasure is still queued behind the first');
        store.release();
        await tick();
        expect(AdPreferences.flightErasing, isFalse);
      });

      test('cleanup drains overlapping erasures including a queued remove',
          () async {
        final first = outcome(AdManager().clearSdkData());
        final second = outcome(AdManager().clearSdkData());
        await held();
        store.releaseAll();
        expect(await first, isNull);
        expect(await second, isNull);
        expect(store.pending, 0);
        expect(AdPreferences.flightErasing, isFalse);
      });

      test('a normal erasure completes before the deadline and reopens',
          () async {
        final done = AdManager().clearSdkData();
        await held();
        store.release();
        await done;
        expect(AdPreferences.flightErasing, isFalse);
        expect(logs.any((m) => m.contains('after timeout')), isFalse);
      });
    });

    test('an erasure that throws still reopens the gate', () async {
      await expectLater(
          AdManager().clearSdkData(
              scope: SdkDataErasureScope.allIncludingEntitlements),
          throwsArgumentError);
      expect(AdPreferences.flightErasing, isFalse);
    });

    test('is a no-op when the flight recorder was never enabled', () async {
      await AdManager().clearSdkData();
      expect(AdManager().flightRecorder, isNull);
    });
  });

  group('T241 audit follow-up — retire drains EVERY write, not a stale '
      'snapshot', () {
    // 2nd-round reviewer finding (HIGH): `_retireFlightRecorder` used to
    // snapshot the recorder's in-flight write chain ONCE and dispose as
    // soon as that single snapshot settled. If a second write landed on the
    // same not-yet-disposed recorder before the first settled (e.g. a
    // second widget instance sharing the recorder calling
    // `closeFlightRecorderInterval` with its own captured reference), that
    // second write's own chain replaced the map entry — and the stale
    // snapshot-based dispose fired without ever waiting for it, silently
    // dropping it at `AdFlightRecorder._doRecord`'s own `_disposed` guard.
    //
    // This drives that exact sequence with a recorder whose `record()` is
    // gated by a `Completer`, so the test controls the interleaving
    // precisely instead of hoping a race manifests.
    test(
        'disableFlightRecorder waits for a SECOND write chained on after '
        'the first was already retiring', () async {
      final recorder = _GatedFlightRecorder();
      AdManager().enableFlightRecorder(recorder);

      // First write: starts (enters record()) but is held open by the gate.
      final firstDone = AdManager().recordFlightRecorderEvent(
        label: 'bannerVisible',
        type: AdSlotType.banner,
        placement: AdPlacement.home,
      );
      await recorder.waitUntilGated();

      // Retire the recorder WHILE the first write is still gated — this is
      // the old code's single-snapshot moment.
      AdManager().disableFlightRecorder();
      expect(recorder.isDisposed, isFalse,
          reason: 'must not dispose synchronously while a write is still '
              'in flight against it');

      // A SECOND write lands on the same (still undisposed) recorder
      // before the first settles — mirrors a second widget instance's own
      // captured reference, or simply this recorder's `closeFlightRecorderInterval`.
      final secondDone = AdManager().closeFlightRecorderInterval(
        recorder,
        label: 'bannerHidden',
        type: AdSlotType.banner,
        placement: AdPlacement.home,
      );
      await Future<void>.delayed(Duration.zero);
      expect(recorder.isDisposed, isFalse,
          reason: 'the second write chained itself onto this recorder '
              'before it was disposed — it must be allowed to land');

      // Release both gates and let everything settle.
      recorder.release();
      await firstDone;
      await secondDone;
      // Disposal happens asynchronously once the drain loop observes no
      // further chain was appended — give it a beat.
      for (var i = 0; i < 20 && !recorder.isDisposed; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(recorder.isDisposed, isTrue);
      expect(recorder.entries.map((e) => e.label),
          containsAll(['bannerVisible', 'bannerHidden']),
          reason: 'a stale-snapshot retire would have disposed the '
              'recorder before the second write\'s own record() call ran, '
              'silently dropping it at the _disposed guard');
    });
  });
}

/// Holds each flight-key remove until [release]; optionally fails it.
class _HeldRemoveStore extends InMemorySharedPreferencesStore {
  _HeldRemoveStore() : super.empty();

  final _held = <Completer<void>>[];
  bool _draining = false;

  int get pending => _held.length;

  void releaseAll() {
    _draining = true;
    while (_held.isNotEmpty) {
      release();
    }
  }

  void release({Object? error}) {
    final c = _held.removeAt(0);
    error == null ? c.complete() : c.completeError(error);
  }

  @override
  Future<bool> remove(String key) async {
    if (key == 'flutter.ad_sdk_flight_recorder_v1' && !_draining) {
      final c = Completer<void>();
      _held.add(c);
      await c.future;
    }
    return super.remove(key);
  }
}

class _FailingFlightRemoveStore extends InMemorySharedPreferencesStore {
  _FailingFlightRemoveStore()
      : super.withData({'flutter.ad_sdk_last_provider_exploration_at_ms': 42});

  @override
  Future<bool> remove(String key) async {
    if (key == 'flutter.ad_sdk_flight_recorder_v1') {
      throw StateError('flight remove failed');
    }
    return super.remove(key);
  }
}

/// Holds the first flight-key write open so a test controls ordering.
class _GatedFlightStore extends InMemorySharedPreferencesStore {
  _GatedFlightStore() : super.empty();

  final writeStarted = Completer<void>();
  final releaseWrite = Completer<void>();

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key == 'flutter.ad_sdk_flight_recorder_v1' && !writeStarted.isCompleted) {
      writeStarted.complete();
      await releaseWrite.future;
    }
    return super.setValue(valueType, key, value);
  }
}

/// Lets a test deterministically pause [record] mid-flight (after
/// `AdManager.recordFlightRecorderEvent`'s own `IabStorage.read` await has
/// already resolved and the call has reached the recorder), so a retire can
/// be driven into the exact "a write is in flight" window without relying on
/// real scheduler timing.
class _GatedFlightRecorder extends AdFlightRecorder {
  Completer<void>? _gate;
  final Completer<void> _entered = Completer<void>();

  Future<void> waitUntilGated() => _entered.future;

  void release() {
    _gate?.complete();
  }

  @override
  Future<void> record({
    required String label,
    required String slotType,
    required String placement,
    required String providerTag,
    double viewabilityFraction = 0,
    double screenX = 0,
    double screenY = 0,
    double widthPx = 0,
    double heightPx = 0,
    String? tcfConsentString,
    bool touchActive = false,
    int? timestampMs,
  }) async {
    // Only the FIRST call actually gates — the second write must be free
    // to run immediately once it reaches the recorder, so the test can
    // observe it landing before the first write's retire-triggering gate
    // is released.
    if (_gate == null) {
      _gate = Completer<void>();
      if (!_entered.isCompleted) _entered.complete();
      await _gate!.future;
    }
    return super.record(
      label: label,
      slotType: slotType,
      placement: placement,
      providerTag: providerTag,
      viewabilityFraction: viewabilityFraction,
      screenX: screenX,
      screenY: screenY,
      widthPx: widthPx,
      heightPx: heightPx,
      tcfConsentString: tcfConsentString,
      touchActive: touchActive,
      timestampMs: timestampMs,
    );
  }
}
