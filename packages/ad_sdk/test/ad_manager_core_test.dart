// Behavioral unit tests for the AdManager orchestrator core, driven through the
// @visibleForTesting seams (debugSetAdapter / debugVipManager / debugEmit /
// releaseFootgunWarnings) so the gating logic is exercised WITHOUT the native
// AppLovin/AdMob plugins.
//
// Covered:
//   1. releaseFootgunWarnings — the loud release-build guards (dryRun, AdMob
//      Google test IDs in release) as a pure function.
//   2. VIP gating — every public load/show/canShow path must short-circuit when
//      a VIP entry is active (the SDK's "VIP suppresses all ad surfaces"
//      contract), including the documented canShowRewardedAd()==true quirk.
//   3. RevenuePanel — a real consumer of AdManager().events: feeding
//      AdRevenueEvents through debugEmit must accumulate on screen.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Minimal fake adapter: real slots (so the non-VIP slot reads work) and call
/// counters for the load/show paths. Everything else is routed through
/// noSuchMethod — these tests never touch the rest of the surface.
class _FakeAdapter implements AdProviderAdapter {
  @override
  final AdSlot appOpenSlot = AdSlot(type: AdSlotType.appOpen);
  @override
  final AdSlot interstitialSlot = AdSlot(type: AdSlotType.interstitial);
  @override
  final AdSlot rewardedSlot = AdSlot(type: AdSlotType.rewarded);
  @override
  final AdSlot bannerSlot = AdSlot(type: AdSlotType.banner);

  int loadInterstitialCalls = 0;
  int showInterstitialCalls = 0;
  int loadRewardedCalls = 0;

  @override
  String get tag => 'fake';

  @override
  Future<void> loadInterstitial() async => loadInterstitialCalls++;

  @override
  Future<void> showInterstitial(
      {required void Function(bool shown) onDone}) async {
    showInterstitialCalls++;
    onDone(true);
  }

  @override
  Future<void> loadRewarded() async => loadRewardedCalls++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Fake VipManager whose `isActive` is fixed — the only member AdManager reads
/// for gating (`_isVipMember => _vipManager?.isActive ?? false`).
class _FakeVip implements VipManager {
  _FakeVip(this._active);
  final bool _active;

  @override
  bool get isActive => _active;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AdConfig _admobConfig({required bool dryRun, required bool testIds}) {
  const realPrefix = 'ca-app-pub-9999999999999999';
  const testPrefix = 'ca-app-pub-3940256099942544';
  final p = testIds ? testPrefix : realPrefix;
  return AdConfig(
    provider: AdProvider.admob,
    admob: AdMobConfig(
      bannerId: '$p/1111111111',
      interstitialId: '$p/2222222222',
      appOpenId: '$p/3333333333',
      rewardedId: '$p/4444444444',
    ),
    safety: AdSafetyParams(dryRun: dryRun),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('releaseFootgunWarnings', () {
    test('debug build never warns (guards are release-only)', () {
      final w = AdManager.releaseFootgunWarnings(
        _admobConfig(dryRun: true, testIds: true),
        isDebug: true,
      );
      expect(w, isEmpty);
    });

    test('release + dryRun → one warning about the safety bypass', () {
      final w = AdManager.releaseFootgunWarnings(
        _admobConfig(dryRun: true, testIds: false),
        isDebug: false,
      );
      expect(w, hasLength(1));
      expect(w.single, contains('dryRun'));
    });

    test('release + AdMob Google test IDs → one warning', () {
      final w = AdManager.releaseFootgunWarnings(
        _admobConfig(dryRun: false, testIds: true),
        isDebug: false,
      );
      expect(w, hasLength(1));
      expect(w.single, contains('TEST'));
    });

    test('release + dryRun + test IDs → both warnings fire', () {
      final w = AdManager.releaseFootgunWarnings(
        _admobConfig(dryRun: true, testIds: true),
        isDebug: false,
      );
      expect(w, hasLength(2));
    });

    test('release + production AdMob IDs + dryRun off → clean', () {
      final w = AdManager.releaseFootgunWarnings(
        _admobConfig(dryRun: false, testIds: false),
        isDebug: false,
      );
      expect(w, isEmpty);
    });

    test('AppLovin provider is exempt from the AdMob test-ID guard', () {
      final w = AdManager.releaseFootgunWarnings(
        const AdConfig(
          provider: AdProvider.appLovin,
          appLovin: AppLovinConfig(
            sdkKey: 'k',
            // Even if an ID happens to contain the Google prefix, the AdMob
            // guard must not fire for an AppLovin provider.
            bannerId: 'ca-app-pub-3940256099942544/x',
            interstitialId: 'i',
            appOpenId: 'a',
            rewardedId: 'r',
          ),
        ),
        isDebug: false,
      );
      expect(w, isEmpty);
    });
  });

  group('VIP gating (via injected adapter + VipManager)', () {
    late _FakeAdapter adapter;

    setUp(() {
      adapter = _FakeAdapter();
      AdManager().debugSetAdapter(adapter);
    });

    tearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugVipManager = null;
    });

    test('VIP active → loadInterstitial is skipped (adapter not called)',
        () async {
      AdManager().debugVipManager = _FakeVip(true);
      await AdManager().loadInterstitial();
      expect(adapter.loadInterstitialCalls, 0);
    });

    test('VIP active → loadRewardedAd is skipped', () async {
      AdManager().debugVipManager = _FakeVip(true);
      await AdManager().loadRewardedAd();
      expect(adapter.loadRewardedCalls, 0);
    });

    test('VIP active → showInterstitial resolves false, never shows', () async {
      AdManager().debugVipManager = _FakeVip(true);
      bool? flow;
      await AdManager().showInterstitial(onDoneFlow: (v) => flow = v);
      expect(flow, isFalse);
      expect(adapter.showInterstitialCalls, 0);
    });

    test('VIP active → canShowInterstitial() is false', () {
      AdManager().debugVipManager = _FakeVip(true);
      expect(AdManager().canShowInterstitial(), isFalse);
    });

    test(
        'VIP active → canShowRewardedAd() is TRUE '
        '(documented quirk: gate the button, decide reward via vipAutoGrant)',
        () {
      AdManager().debugVipManager = _FakeVip(true);
      expect(AdManager().canShowRewardedAd(), isTrue);
    });

    test('no VIP + idle slot → canShowInterstitial() is false', () {
      AdManager().debugVipManager = _FakeVip(false);
      // Slot is idle (never loaded) → not ready → false regardless of the
      // safety layer's session-timing state.
      expect(adapter.interstitialSlot.isReady, isFalse);
      expect(AdManager().canShowInterstitial(), isFalse);
    });
  });

  group('null adapter (uninitialised) is safe', () {
    setUp(() => AdManager().debugSetAdapter(null));

    test('canShowInterstitial / canShowRewardedAd both false', () {
      expect(AdManager().canShowInterstitial(), isFalse);
      expect(AdManager().canShowRewardedAd(), isFalse);
    });

    test('showInterstitial resolves false without an adapter', () async {
      bool? flow;
      await AdManager().showInterstitial(onDoneFlow: (v) => flow = v);
      expect(flow, isFalse);
    });
  });

  group('RevenuePanel consumes AdManager().events (debugEmit)', () {
    AdRevenueEvent rev(int micros) => AdRevenueEvent(
          providerTag: 'fake',
          type: AdSlotType.interstitial,
          placement: AdPlacement.unspecified,
          valueMicros: micros,
          currencyCode: 'USD',
        );

    testWidgets('emitted revenue accumulates and renders', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: RevenuePanel(compact: true, showDecimals: false),
        ),
      ));
      await tester.pump();
      expect(find.text('Rev: \$0.00  /  0 imp'), findsOneWidget);

      AdManager().debugEmit(rev(1500000)); // $1.50
      AdManager().debugEmit(rev(500000)); //  $0.50
      // Broadcast-stream delivery is async (microtask) → flush, then rebuild.
      await tester.pump();
      await tester.pump();

      expect(find.text('Rev: \$2.00  /  2 imp'), findsOneWidget,
          reason: 'two events accumulate value + impression count');
    });

    testWidgets('non-revenue events do not move the counter', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: RevenuePanel(compact: true, showDecimals: false),
        ),
      ));
      await tester.pump();

      AdManager().debugEmit(AdShowEvent(
        providerTag: 'fake',
        type: AdSlotType.interstitial,
        placement: AdPlacement.unspecified,
        success: true,
      ));
      await tester.pump();

      expect(find.text('Rev: \$0.00  /  0 imp'), findsOneWidget);
    });
  });
}
