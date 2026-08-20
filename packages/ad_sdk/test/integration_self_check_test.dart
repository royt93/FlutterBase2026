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

/// Minimal fake adapter — reports success/failure per slot via a real
/// eventSink (wired manually in setUp, mirroring what AdManager.initialize()
/// does for a real adapter) so runIntegrationSelfCheck()'s AdLoadEvent
/// listener has something to observe.
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

  void _reportLoad(AdSlotType type) {
    eventSink?.call(AdLoadEvent(
      providerTag: '[Fake]',
      type: type,
      placement: AdPlacement.unspecified,
      success: succeeds.contains(type),
    ));
  }

  @override
  Future<void> loadInterstitial() async => _reportLoad(AdSlotType.interstitial);

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
