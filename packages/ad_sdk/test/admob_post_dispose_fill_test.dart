// Round-25 QC round 15 (`codex`, MAJOR) — a fullscreen fill that lands after
// `AdMobAdapter.dispose()`.
//
// GMA delivers a fill whenever it is ready, including after the host has torn
// the SDK down. `dispose()` releases the ads it can see at that instant; an ad
// arriving one millisecond later used to be stored into the discarded adapter,
// where nothing would ever dispose it (a leaked native ad object per late
// fill), and for App Open `markReady()` answered the host's `onAdLoaded` with
// `true` for an ad that could never be shown.
//
// The fake bridge here DEFERS `onLoaded` so the test controls the exact
// ordering: load → dispose → fill.


import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/adapters/admob_adapter.dart';
import 'package:applovin_admob_sdk/src/adapters/gma_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAd implements GmaFullscreenAd {
  int disposeCount = 0;
  int showCount = 0;

  @override
  Future<void> show(GmaShowCallbacks callbacks,
      {String? ssvCustomData, String? ssvUserId}) async {
    showCount++;
  }

  @override
  void setPaidEventListener(void Function(num, String, String) cb) {}

  @override
  List<String>? get mediationWaterfall => null;

  @override
  void dispose() => disposeCount++;
}

/// Holds every `onLoaded` back until the test calls [deliver].
class _DeferredBridge implements GmaBridge {
  final List<void Function(GmaFullscreenAd)> _pending = [];
  final List<_FakeAd> delivered = [];

  /// Hands the adapter the fill it has been waiting for.
  _FakeAd deliver() {
    final ad = _FakeAd();
    delivered.add(ad);
    _pending.removeAt(0)(ad);
    return ad;
  }

  bool get hasPending => _pending.isNotEmpty;

  @override
  Future<void> initialize() async {}
  @override
  Future<void> updateRequestConfiguration(List<String> ids,
      {int? tagForChildDirectedTreatment, int? tagForUnderAgeOfConsent}) async {}

  @override
  Future<void> loadAppOpen(String id,
          {required bool nonPersonalizedAds,
          bool restrictedDataProcessing = false,
          required void Function(GmaFullscreenAd) onLoaded,
          required void Function(int, String) onFailed}) async =>
      _pending.add(onLoaded);

  @override
  Future<void> loadInterstitial(String id,
          {required bool nonPersonalizedAds,
          bool restrictedDataProcessing = false,
          required void Function(GmaFullscreenAd) onLoaded,
          required void Function(int, String) onFailed}) async =>
      _pending.add(onLoaded);

  @override
  Future<void> loadRewarded(String id,
          {required bool nonPersonalizedAds,
          bool restrictedDataProcessing = false,
          required void Function(GmaFullscreenAd) onLoaded,
          required void Function(int, String) onFailed}) async =>
      _pending.add(onLoaded);

  @override
  Future<void> loadRewardedInterstitial(String id,
          {required bool nonPersonalizedAds,
          bool restrictedDataProcessing = false,
          required void Function(GmaFullscreenAd) onLoaded,
          required void Function(int, String) onFailed}) async =>
      _pending.add(onLoaded);
}

const _config = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'b',
    interstitialId: 'i',
    appOpenId: 'ao',
    rewardedId: 'r',
    rewardedInterstitialId: 'ri',
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _DeferredBridge bridge;
  late AdMobAdapter adapter;

  setUp(() async {
    bridge = _DeferredBridge();
    adapter = AdMobAdapter(bridge: bridge);
    expect(await adapter.initialize(_config), isTrue);
  });

  test(
      'CONTROL — a fill that lands BEFORE dispose() is kept, and the host is '
      'told the ad is ready', () async {
    bool? answer;
    await adapter.loadAppOpen(onAdLoaded: (ok) => answer = ok);
    final ad = bridge.deliver();

    expect(answer, isTrue);
    expect(ad.disposeCount, 0, reason: 'this ad is cached for a real show');
    expect(adapter.appOpenSlot.state.value, AdSlotState.ready);

    await adapter.dispose();
    expect(ad.disposeCount, 1,
        reason: 'and the normal teardown still releases it');
  });

  test(
      'an App Open fill landing after dispose() is released, and the host is '
      'told "no ad" instead of being lied to', () async {
    final answers = <bool>[];
    await adapter.loadAppOpen(onAdLoaded: answers.add);
    expect(bridge.hasPending, isTrue, reason: 'control — the load did happen');

    await adapter.dispose();
    expect(answers, [false],
        reason: 'the teardown itself answers the host, via AdSlot.reset()');
    final ad = bridge.deliver();

    expect(ad.disposeCount, 1,
        reason: 'the late ad is the leak — nothing else holds a reference to '
            'it once the adapter is discarded');
    expect(answers, [false],
        reason: 'and the late fill must not answer a SECOND time — least of '
            'all with true, for an ad that can never be shown');
    expect(ad.showCount, 0);
  });

  test('the same is true for interstitial, rewarded and rewarded-interstitial',
      () async {
    await adapter.loadInterstitial();
    await adapter.loadRewarded();
    await adapter.loadRewardedInterstitial();
    await adapter.dispose();

    final late1 = bridge.deliver();
    final late2 = bridge.deliver();
    final late3 = bridge.deliver();

    expect([late1.disposeCount, late2.disposeCount, late3.disposeCount],
        [1, 1, 1]);
  });

  test('a late fill does not crash on the disposed slot notifiers', () async {
    await adapter.loadInterstitial();
    await adapter.dispose();
    // Would throw "A _SlotStateNotifier was used after being disposed" if the
    // guard let the handler run on to markReady().
    expect(bridge.deliver().disposeCount, 1);
  });

  test('a fill for a second, live adapter is unaffected by the first teardown',
      () async {
    await adapter.loadAppOpen();
    await adapter.dispose();
    bridge.deliver();

    final freshBridge = _DeferredBridge();
    final fresh = AdMobAdapter(bridge: freshBridge);
    expect(await fresh.initialize(_config), isTrue);
    addTearDown(fresh.dispose);

    bool? answer;
    await fresh.loadAppOpen(onAdLoaded: (ok) => answer = ok);
    final ad = freshBridge.deliver();

    expect(answer, isTrue,
        reason: 'the disposed flag is per adapter instance, not global');
    expect(ad.disposeCount, 0);
  });
}
