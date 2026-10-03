// T236 — Flight Recorder coverage for the 4 fullscreen show*() call sites
// (App Open/Interstitial/Rewarded/Rewarded Interstitial) and for
// NativeAdWidget, mirroring the Banner/MREC `'*Visible'`/`'*Hidden'`
// evidence contract already covered by ad_manager_flight_recorder_test.dart
// and mrec_ad_widget_test.dart's "T231 Flight Recorder" group.
//
// Unit coverage here drives AdManager's public show*() methods through a
// minimal `_FakeAdapter` (debugSetAdapter seam) — no native platform
// channels — proving the SDK orchestrator itself records fullscreenVisible/
// fullscreenDismissed entries, not just a direct AdFlightRecorder.record()
// call. Native widget visible/hidden coverage lives in
// native_ad_widget_test.dart instead, mirroring where Banner/MREC's own
// flight recorder widget tests live.

import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/core/iab_storage.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Minimal adapter: real [AdSlot]s (so beginShow/markDismissed gating stays
/// authentic) plus a toggle per format to simulate a show that never
/// actually displayed. Mirrors `ad_manager_core_test.dart`'s `_FakeAdapter`
/// but trimmed to just what this file's 4 fullscreen formats need —
/// everything else routes through `noSuchMethod` since these tests never
/// touch banner/mrec/native.
class _FakeFullscreenAdapter implements AdProviderAdapter {
  @override
  final AdSlot appOpenSlot = AdSlot(type: AdSlotType.appOpen);
  @override
  final AdSlot interstitialSlot = AdSlot(type: AdSlotType.interstitial);
  @override
  final AdSlot rewardedSlot = AdSlot(type: AdSlotType.rewarded);
  @override
  final AdSlot rewardedInterstitialSlot = AdSlot(
    type: AdSlotType.rewardedInterstitial,
  );

  @override
  String get tag => '[Fake]';

  bool appOpenDismissedResult = true;
  bool interstitialShownResult = true;
  bool rewardedShown = true;
  bool rewardedInterstitialShown = true;

  @override
  Future<void> showAppOpen({
    required void Function(bool dismissed) onDismiss,
  }) async {
    appOpenSlot.beginShow();
    appOpenSlot.markDismissed();
    onDismiss(appOpenDismissedResult);
  }

  @override
  Future<void> showInterstitial({
    required void Function(bool shown) onDone,
  }) async {
    interstitialSlot.beginShow();
    interstitialSlot.markDismissed();
    onDone(interstitialShownResult);
  }

  @override
  Future<void> showRewarded({
    required void Function(RewardResult result) onDone,
    String? ssvCustomData,
    String? ssvUserId,
  }) async {
    rewardedSlot.beginShow();
    rewardedSlot.markDismissed();
    onDone(RewardResult(earned: rewardedShown, shown: rewardedShown));
  }

  @override
  Future<void> showRewardedInterstitial({
    required void Function(RewardResult result) onDone,
  }) async {
    rewardedInterstitialSlot.beginShow();
    rewardedInterstitialSlot.markDismissed();
    onDone(
      RewardResult(
        earned: rewardedInterstitialShown,
        shown: rewardedInterstitialShown,
      ),
    );
  }

  @override
  Future<void> dispose() async {}

  // Each show*() reloads its own slot afterward (see AdManager.show*'s own
  // `unawaited(load...())` call) — stub as no-ops so that reload never hits
  // noSuchMethod; none of these tests assert on reload behavior.
  @override
  Future<void> loadAppOpen({void Function(bool loaded)? onAdLoaded}) async {}
  @override
  Future<void> loadInterstitial() async {}
  @override
  Future<void> loadRewarded() async {}
  @override
  Future<void> loadRewardedInterstitial() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _drainRecorderWrites() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeFullscreenAdapter adapter;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AdPreferences.resetForTest();
    final prefs = await AdPreferences.getInstance();
    await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
    AdSafetyConfig.resetForReinit();
    adapter = _FakeFullscreenAdapter();
    AdManager().debugSetAdapter(adapter);
    AdManager().debugCanRequestAds = true;
    AdManager().debugVipManager = null;
  });

  tearDown(() {
    AdManager().disableFlightRecorder();
    AdManager().debugSetAdapter(null);
    AdManager().debugCanRequestAds = true;
    AdPreferences.resetForTest();
  });

  group('T236 — fullscreen show*() emit flight recorder evidence', () {
    test('showAppOpenAd (bypassSafety) records exactly one '
        'fullscreenVisible + fullscreenDismissed pair when enabled',
        () async {
      final recorder = AdFlightRecorder();
      AdManager().enableFlightRecorder(recorder);

      bool? dismissed;
      await AdManager().showAppOpenAd(
        bypassSafety: true,
        onAdDismiss: (d) => dismissed = d,
      );
      await _drainRecorderWrites();

      expect(dismissed, isTrue);
      final shown = recorder.entries.singleWhere(
        (e) => e.label == 'fullscreenVisible',
      );
      expect(shown.slotType, 'appOpen');
      final done = recorder.entries.singleWhere(
        (e) => e.label == 'fullscreenDismissed',
      );
      expect(done.slotType, 'appOpen');
      expect(done.timestampMs, greaterThanOrEqualTo(shown.timestampMs));
      expect(await verifyFlightRecorderChain(recorder.entries), isTrue);
    });

    // T236 audit fix — the write is `unawaited` at its call site (see
    // _recordFullscreenFlight's doc comment for why), but
    // exportSignedFlightRecorderBundle() awaits the in-flight write first.
    // A host that exports immediately from inside onAdDismiss (T231's whole
    // documented use case) must never get a bundle missing this impression.
    test('exportSignedFlightRecorderBundle from inside onAdDismiss never '
        'misses the just-recorded pair', () async {
      final recorder = AdFlightRecorder();
      AdManager().enableFlightRecorder(recorder);

      final exported = Completer<SignedPayload?>();
      await AdManager().showAppOpenAd(
        bypassSafety: true,
        onAdDismiss: (_) async {
          exported.complete(
            await AdManager().exportSignedFlightRecorderBundle(),
          );
        },
      );
      // The onAdDismiss closure above is async and not awaited by
      // showAppOpenAd (see _recordFullscreenFlight's doc comment on why
      // show*() callbacks can't become a wait point) — await its own
      // completer, not showAppOpenAd's return, before asserting.
      final bundle = await exported.future;

      expect(bundle, isNotNull);
      final decoded = FlightRecorderBundle.fromJsonString(bundle!.payloadJson);
      expect(
        decoded.entries.where((e) => e.label == 'fullscreenVisible'),
        hasLength(1),
      );
      expect(
        decoded.entries.where((e) => e.label == 'fullscreenDismissed'),
        hasLength(1),
      );
    });

    // T236 audit fix (Finding 5) — if `enableFlightRecorder` swaps in a new
    // recorder while `_recordFullscreenFlight` is suspended on
    // `IabStorage.read`, the post-await guard must catch it by identity (not
    // just null-check `_flightRecorder`) or this would silently write into a
    // disposed, orphaned recorder — losing the impression from BOTH the old
    // and new recorder.
    test('recorder swapped mid-await is never written to, and the new '
        'recorder stays empty for that impression', () async {
      final oldRecorder = AdFlightRecorder();
      AdManager().enableFlightRecorder(oldRecorder);

      final gate = Completer<void>();
      IabStorage.debugOpenOverride = () async {
        await gate.future;
        throw StateError('no platform store in test');
      };
      addTearDown(() => IabStorage.debugOpenOverride = null);

      final dismissFuture = AdManager().showAppOpenAd(
        bypassSafety: true,
        onAdDismiss: (_) {},
      );

      // Swap recorders while _recordFullscreenFlight is suspended awaiting
      // IabStorage.read above.
      final newRecorder = AdFlightRecorder();
      AdManager().enableFlightRecorder(newRecorder);
      gate.complete();
      await dismissFuture;
      await _drainRecorderWrites();

      expect(oldRecorder.entries, isEmpty,
          reason: 'old recorder was disposed before the write could land');
      expect(newRecorder.entries, isEmpty,
          reason: 'the write belonged to the old recorder\'s in-flight call, '
              'not the new one — it must not silently migrate');
    });

    test('recordPair keeps visible/dismissed adjacent under concurrent writes',
        () async {
      final recorder = AdFlightRecorder();
      final pair = recorder.recordPair(
        label1: 'fullscreenVisible',
        label2: 'fullscreenDismissed',
        slotType: 'appOpen',
        placement: 'splash',
        providerTag: '[Fake]',
      );
      final other = recorder.record(
        label: 'clicked',
        slotType: 'appOpen',
        placement: 'splash',
        providerTag: '[Fake]',
      );
      await Future.wait([pair, other]);

      expect(
        recorder.entries.map((e) => e.label).toList(),
        ['fullscreenVisible', 'fullscreenDismissed', 'clicked'],
      );
      expect(await verifyFlightRecorderChain(recorder.entries), isTrue);
    });

    // T236 audit fix — a real click mid-display appends a 'clicked' entry
    // chained strictly after this one; the fullscreen pair must never be
    // backdated earlier than an entry already in the chain (verified here
    // by requiring the pair's timestamps are never less than a 'clicked'
    // entry written before the ad was dismissed).
    test('multiple concurrent dismiss callbacks queue their pending writes '
        'and export waits for all of them', () async {
      final recorder = AdFlightRecorder();
      AdManager().enableFlightRecorder(recorder);

      final gate = Completer<void>();
      IabStorage.debugOpenOverride = () async {
        await gate.future;
        throw StateError('no platform store in test');
      };
      addTearDown(() => IabStorage.debugOpenOverride = null);

      await AdManager().showAppOpenAd(
        bypassSafety: true,
        placement: AdPlacement.home,
        onAdDismiss: (_) {},
      );
      await AdManager().showAppOpenAd(
        bypassSafety: true,
        placement: AdPlacement.shop,
        onAdDismiss: (_) {},
      );

      final exportFuture = AdManager().exportSignedFlightRecorderBundle();
      gate.complete();
      final bundle = await exportFuture;

      expect(bundle, isNotNull);
      final decoded = FlightRecorderBundle.fromJsonString(bundle!.payloadJson);
      expect(
        decoded.entries.where((e) => e.label == 'fullscreenVisible'),
        hasLength(2),
        reason: 'export must await BOTH pending writes to complete',
      );
    });

    test('fullscreenVisible/fullscreenDismissed never precede an earlier '
        'clicked entry in the chain, but interactionDurationMs stays 0 as a '
        'documented limitation of dismiss-time pair emission', () async {
      final recorder = AdFlightRecorder();
      AdManager().enableFlightRecorder(recorder);
      await recorder.record(
        label: 'clicked',
        slotType: 'appOpen',
        placement: 'splash',
        providerTag: '[Fake]',
        touchActive: true,
      );
      final click1 = recorder.entries.single;
      expect(click1.interactionDurationMs, 0);

      await AdManager().showAppOpenAd(bypassSafety: true, onAdDismiss: (_) {});
      await _drainRecorderWrites();

      final shown =
          recorder.entries.singleWhere((e) => e.label == 'fullscreenVisible');
      final done = recorder.entries
          .singleWhere((e) => e.label == 'fullscreenDismissed');
      expect(shown.timestampMs, greaterThanOrEqualTo(click1.timestampMs));
      expect(done.timestampMs, greaterThanOrEqualTo(shown.timestampMs));
    });

    test('showInterstitial records exactly one fullscreenVisible + '
        'fullscreenDismissed pair when enabled', () async {
      adapter.interstitialSlot.beginReload();
      adapter.interstitialSlot.markReady();
      final recorder = AdFlightRecorder();
      AdManager().enableFlightRecorder(recorder);

      bool? shownFlow;
      await AdManager().showInterstitial(onDoneFlow: (s) => shownFlow = s);
      await _drainRecorderWrites();

      expect(shownFlow, isTrue);
      final shown = recorder.entries.singleWhere(
        (e) => e.label == 'fullscreenVisible' && e.slotType == 'interstitial',
      );
      final done = recorder.entries.singleWhere(
        (e) =>
            e.label == 'fullscreenDismissed' && e.slotType == 'interstitial',
      );
      expect(done.timestampMs, greaterThanOrEqualTo(shown.timestampMs));
      expect(await verifyFlightRecorderChain(recorder.entries), isTrue);
    });

    test('showRewardedAd records exactly one fullscreenVisible + '
        'fullscreenDismissed pair when enabled, with dwell time on a '
        'click', () async {
      adapter.rewardedSlot.beginReload();
      adapter.rewardedSlot.markReady();
      final recorder = AdFlightRecorder();
      AdManager().enableFlightRecorder(recorder);

      await AdManager().showRewardedAd(onEarnedReward: (_) {});
      await _drainRecorderWrites();

      recorder.entries.singleWhere(
        (e) => e.label == 'fullscreenVisible' && e.slotType == 'rewarded',
      );
      recorder.entries.singleWhere(
        (e) => e.label == 'fullscreenDismissed' && e.slotType == 'rewarded',
      );
      expect(await verifyFlightRecorderChain(recorder.entries), isTrue);

      // T236 audit fix — 'fullscreenVisible' (not 'fullscreenShown') must
      // match AdFlightRecorder._msSinceLastVisible's `endsWith('visible')`
      // lookup, or every fullscreen click's interactionDurationMs silently
      // computes as 0.
      await recorder.record(
        label: 'clicked',
        slotType: 'rewarded',
        placement: '-',
        providerTag: '[Fake]',
        touchActive: true,
      );
      final click =
          recorder.entries.firstWhere((e) => e.label == 'clicked');
      expect(click.interactionDurationMs, greaterThanOrEqualTo(0));
    });

    test('showRewardedInterstitialAd records exactly one fullscreenVisible '
        '+ fullscreenDismissed pair when enabled', () async {
      adapter.rewardedInterstitialSlot.beginReload();
      adapter.rewardedInterstitialSlot.markReady();
      final recorder = AdFlightRecorder();
      AdManager().enableFlightRecorder(recorder);

      await AdManager().showRewardedInterstitialAd(onDone: (_, _) {});
      await _drainRecorderWrites();

      final shown = recorder.entries.singleWhere(
        (e) =>
            e.label == 'fullscreenVisible' &&
            e.slotType == 'rewardedInterstitial',
      );
      final done = recorder.entries.singleWhere(
        (e) =>
            e.label == 'fullscreenDismissed' &&
            e.slotType == 'rewardedInterstitial',
      );
      expect(done.timestampMs, greaterThanOrEqualTo(shown.timestampMs));
      expect(await verifyFlightRecorderChain(recorder.entries), isTrue);
    });

    test('an unsuccessful show (shown:false) records nothing — never a '
        'fake impression/dismiss pair', () async {
      adapter.interstitialSlot.beginReload();
      adapter.interstitialSlot.markReady();
      adapter.interstitialShownResult = false;
      final recorder = AdFlightRecorder();
      AdManager().enableFlightRecorder(recorder);

      bool? shownFlow;
      await AdManager().showInterstitial(onDoneFlow: (s) => shownFlow = s);
      await _drainRecorderWrites();

      expect(shownFlow, isFalse);
      expect(
        recorder.entries,
        isEmpty,
        reason:
            'a failed show must not be recorded as a real impression '
            'at all, same "no evidence for what never displayed" rule '
            'T237 applies to house-ad fallbacks',
      );
    });

    test(
      'disabled recorder (default OFF) — no entries, behavior unchanged',
      () async {
        adapter.interstitialSlot.beginReload();
        adapter.interstitialSlot.markReady();

        bool? shownFlow;
        await AdManager().showInterstitial(onDoneFlow: (s) => shownFlow = s);
        await _drainRecorderWrites();

        expect(shownFlow, isTrue);
        expect(AdManager().flightRecorder, isNull);
      },
    );
  });
}
