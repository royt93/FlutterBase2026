// Tests for AdManager.runIntegrationSelfCheck() (T41 brainstorm) — the
// debug-only partner checklist covering init/consent/per-slot-load/VIP
// wiring, driven through the same debugSetAdapter/debugConfig seams as
// ad_manager_core_test.dart.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/core/ad_provider_adapter.dart'
    show AdEventSink;
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Minimal fake adapter — mutates the real slot (beginLoad() +
/// markReady()/markFailed()), mirroring what a real adapter does, since
/// runIntegrationSelfCheck() (T193) watches slot state directly rather
/// than the event stream. Also still emits the matching AdLoadEvent, same
/// as a real adapter, for any other test/listener that cares about it.
class _FakeAdapter implements AdProviderAdapter {
  @override
  AdEventSink? eventSink;

  // T75 — AdManager's _adapter setter now reads these on every
  // debugSetAdapter() call to wire fullscreenBusy's slot listeners.
  @override
  final AdSlot appOpenSlot = AdSlot(type: AdSlotType.appOpen);
  @override
  final AdSlot interstitialSlot = AdSlot(type: AdSlotType.interstitial);
  @override
  final AdSlot rewardedSlot = AdSlot(type: AdSlotType.rewarded);
  @override
  final AdSlot rewardedInterstitialSlot =
      AdSlot(type: AdSlotType.rewardedInterstitial);

  /// Slots this fake reports a successful load for; anything else never
  /// fires an AdLoadEvent, so the self-check's wait times out (mirrors a
  /// real ad network failing to fill).
  Set<AdSlotType> succeeds = {
    AdSlotType.interstitial,
    AdSlotType.rewarded,
    AdSlotType.appOpen,
  };

  AdSlot _slotFor(AdSlotType type) => switch (type) {
        AdSlotType.appOpen => appOpenSlot,
        AdSlotType.interstitial => interstitialSlot,
        AdSlotType.rewarded => rewardedSlot,
        AdSlotType.rewardedInterstitial => rewardedInterstitialSlot,
        _ => throw ArgumentError('no fullscreen slot for $type'),
      };

  void _reportLoad(AdSlotType type) {
    final slot = _slotFor(type);
    final success = succeeds.contains(type);
    slot.beginLoad();
    if (success) {
      slot.markReady();
    } else {
      slot.markFailed();
    }
    eventSink?.call(AdLoadEvent(
      providerTag: '[Fake]',
      type: type,
      placement: AdPlacement.unspecified,
      success: success,
    ));
  }

  /// T193 — mirrors a real adapter's "fresh ad already cached — keep it"
  /// early return (e.g. `AdMobAdapter.loadInterstitial`): when true,
  /// `loadInterstitial()` does nothing at all — no `beginLoad()`, no new
  /// `AdLoadEvent`. The slot must already be `ready` (set directly by the
  /// test) for this to model a real "already preloaded" scenario.
  bool interstitialAlreadyReadyNoOp = false;

  @override
  Future<void> loadInterstitial() async {
    if (interstitialAlreadyReadyNoOp) return;
    _reportLoad(AdSlotType.interstitial);
  }

  @override
  Future<void> loadRewarded() async => _reportLoad(AdSlotType.rewarded);

  @override
  Future<void> loadAppOpen({void Function(bool loaded)? onAdLoaded}) async =>
      _reportLoad(AdSlotType.appOpen);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeVip implements VipManager {
  @override
  bool get isActive => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AdConfig _config() => const AdConfig(
      provider: AdProvider.admob,
      admob: AdMobConfig(
        bannerId: 'ca-app-pub-3940256099942544/6300978111',
        interstitialId: 'ca-app-pub-3940256099942544/1033173712',
        appOpenId: 'ca-app-pub-3940256099942544/3419835294',
        rewardedId: 'ca-app-pub-3940256099942544/5224354917',
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeAdapter adapter;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await AdPreferences.getInstance();
    await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
    AdSafetyConfig.resetForReinit();
    adapter = _FakeAdapter();
    adapter.eventSink = AdManager().debugEmit;
    // T98: isolate the "Route observer wired" check's static counter from
    // whatever an earlier test in this file (or a widget it pumped) left
    // behind.
    AdScreenRouteLogger.resetState();
  });

  tearDown(() {
    AdManager().debugSetAdapter(null);
    AdManager().debugConfig = null;
    AdManager().debugVipManager = null;
    // T98: a previous test's setNavigatorKey() must not leak into the next
    // test — AdManager is a singleton and there is no other reset path.
    AdManager().debugClearNavigatorKey();
  });

  test('fails fast when SDK not initialised', () async {
    final result = await AdManager().runIntegrationSelfCheck();

    expect(result.allPassed, isFalse);
    expect(result.items, hasLength(1));
    expect(result.items.single.name, 'SDK initialised');
    expect(result.items.single.status, SelfCheckStatus.fail);
  });

  test('all-pass path: adapter present, every load succeeds, vip wired',
      () async {
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _config();
    AdManager().debugVipManager = _FakeVip();
    // T98: without a navigator key set, the new "Navigator key wired" check
    // would fail — a real host always calls setNavigatorKey before runApp.
    // Not attached to a live tree here, so it reports `skipped`, not `pass`;
    // that's fine, `skipped` doesn't affect `allPassed`.
    AdManager().setNavigatorKey(GlobalKey<NavigatorState>());

    final result = await AdManager()
        .runIntegrationSelfCheck(loadTimeout: const Duration(seconds: 2));

    expect(result.allPassed, isTrue);
    expect(result.items.firstWhere((i) => i.name == 'Interstitial load').status,
        SelfCheckStatus.pass);
    expect(result.items.firstWhere((i) => i.name == 'Rewarded load').status,
        SelfCheckStatus.pass);
    expect(result.items.firstWhere((i) => i.name == 'App Open load').status,
        SelfCheckStatus.pass);
    expect(result.items.firstWhere((i) => i.name == 'VIP manager wired').status,
        SelfCheckStatus.pass);
  });

  test('VIP manager not wired → that item fails, rest unaffected', () async {
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _config();

    final result = await AdManager()
        .runIntegrationSelfCheck(loadTimeout: const Duration(seconds: 2));

    expect(result.allPassed, isFalse);
    expect(result.items.firstWhere((i) => i.name == 'VIP manager wired').status,
        SelfCheckStatus.fail);
  });

  test('a slot that never loads reports a failing item on timeout', () async {
    adapter.succeeds = {AdSlotType.rewarded, AdSlotType.appOpen};
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _config();
    AdManager().debugVipManager = _FakeVip();

    final result = await AdManager().runIntegrationSelfCheck(
        loadTimeout: const Duration(milliseconds: 200));

    expect(result.allPassed, isFalse);
    final interstitial =
        result.items.firstWhere((i) => i.name == 'Interstitial load');
    expect(interstitial.status, SelfCheckStatus.fail);
    expect(interstitial.detail, contains('Interstitial load'));
  });

  // T193 — a slot that was already ready (a real, still-fresh preloaded ad)
  // used to be reported as a FALSE FAIL: the self-check waited only for a
  // NEW AdLoadEvent, but a real adapter's loadInterstitial() silently
  // short-circuits without emitting one when it already has a fresh,
  // ready ad cached — see AdMobAdapter.loadInterstitial's "fresh — keep
  // it" early return.
  test('an already-ready (preloaded) slot passes immediately, without '
      'waiting for a new AdLoadEvent', () async {
    adapter.succeeds = {AdSlotType.rewarded, AdSlotType.appOpen};
    // Simulates a slot that was ALREADY loaded successfully before this
    // self-check ever ran.
    adapter.interstitialSlot.beginLoad();
    adapter.interstitialSlot.markReady();
    // Mirrors the real "fresh ad already cached" short-circuit: the load
    // call itself does nothing at all when called again.
    adapter.interstitialAlreadyReadyNoOp = true;
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _config();
    AdManager().debugVipManager = _FakeVip();

    final stopwatch = Stopwatch()..start();
    // A LONG timeout — if the fix regressed back to event-only waiting,
    // this test would still eventually pass, just slowly. The elapsed-time
    // assertion below is what actually proves readiness-first, not a
    // fallback wait.
    final result = await AdManager()
        .runIntegrationSelfCheck(loadTimeout: const Duration(seconds: 10));
    stopwatch.stop();

    final interstitial =
        result.items.firstWhere((i) => i.name == 'Interstitial load');
    expect(interstitial.status, SelfCheckStatus.pass,
        reason: 'an already-ready slot must pass — the SDK genuinely has '
            'a usable ad, silently reusing it is correct behavior, not a '
            'failure');
    expect(interstitial.detail, contains('already ready'));
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)),
        reason: 'must resolve immediately via the readiness check, not by '
            'waiting out (a fraction of) the 10s timeout for an event '
            'that a real adapter would never emit in this scenario');
  });

  group('T98 — "doctor" checks', () {
    test('Navigator key wired: fails when setNavigatorKey was never called',
        () async {
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _config();
      AdManager().debugVipManager = _FakeVip();

      final result = await AdManager()
          .runIntegrationSelfCheck(loadTimeout: const Duration(seconds: 2));

      final item =
          result.items.firstWhere((i) => i.name == 'Navigator key wired');
      expect(item.status, SelfCheckStatus.fail);
      expect(item.detail, contains('setNavigatorKey'));
    });

    test(
        'Navigator key wired: skipped (not pass/fail) when set but not '
        'attached to a live Navigator', () async {
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _config();
      AdManager().debugVipManager = _FakeVip();
      AdManager().setNavigatorKey(GlobalKey<NavigatorState>());

      final result = await AdManager()
          .runIntegrationSelfCheck(loadTimeout: const Duration(seconds: 2));

      final item =
          result.items.firstWhere((i) => i.name == 'Navigator key wired');
      expect(item.status, SelfCheckStatus.skipped);
    });

    test(
        'Route observer wired: skipped when no navigation event has been '
        'observed yet', () async {
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _config();
      AdManager().debugVipManager = _FakeVip();

      final result = await AdManager()
          .runIntegrationSelfCheck(loadTimeout: const Duration(seconds: 2));

      final item =
          result.items.firstWhere((i) => i.name == 'Route observer wired');
      expect(item.status, SelfCheckStatus.skipped);
    });

    test(
        'Route observer wired: passes once AdScreenRouteLogger has actually '
        'received a navigation callback', () async {
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _config();
      AdManager().debugVipManager = _FakeVip();

      // A real Navigator only ever calls didPush/didPop/etc on an observer
      // it was actually given — calling it directly here is the same signal
      // runIntegrationSelfCheck relies on (navigationEventsObserved > 0),
      // without needing a full pumped widget tree.
      AdScreenRouteLogger().didPush(
        MaterialPageRoute<void>(builder: (_) => const SizedBox()),
        null,
      );

      final result = await AdManager()
          .runIntegrationSelfCheck(loadTimeout: const Duration(seconds: 2));

      final item =
          result.items.firstWhere((i) => i.name == 'Route observer wired');
      expect(item.status, SelfCheckStatus.pass);
    });

    test('ATT status readable (iOS): skipped on a non-iOS test host',
        () async {
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _config();
      AdManager().debugVipManager = _FakeVip();

      final result = await AdManager()
          .runIntegrationSelfCheck(loadTimeout: const Duration(seconds: 2));

      final item = result.items
          .firstWhere((i) => i.name == 'ATT status readable (iOS)');
      expect(item.status, SelfCheckStatus.skipped);
    });
  });
}
