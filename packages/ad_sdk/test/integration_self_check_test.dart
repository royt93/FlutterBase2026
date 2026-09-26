// Tests for AdManager.runIntegrationSelfCheck() (T41 brainstorm) — the
// debug-only partner checklist covering init/consent/per-slot-load/VIP
// wiring, driven through the same debugSetAdapter/debugConfig seams as
// ad_manager_core_test.dart.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  late FakeAdProviderAdapter adapter;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await AdPreferences.getInstance();
    await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
    AdSafetyConfig.resetForReinit();
    adapter = FakeAdProviderAdapter();
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
    adapter.successfulLoadTypes = {AdSlotType.rewarded, AdSlotType.appOpen};
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
    adapter.successfulLoadTypes = {AdSlotType.rewarded, AdSlotType.appOpen};
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
    expect(adapter.loadInterstitialCalls, 0,
        reason: 'readiness-first means checking the slot before invoking the '
            'adapter: a logical ready slot must not be replaced by a real '
            'network request that can turn it into no-fill/cooldown');
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)),
        reason: 'must resolve immediately via the readiness check, not by '
            'waiting out (a fraction of) the 10s timeout for an event '
            'that a real adapter would never emit in this scenario');
  });

  test('rewarded and app open already-ready slots also bypass load invocation',
      () async {
    adapter.successfulLoadTypes = {AdSlotType.interstitial};
    adapter.rewardedSlot.beginLoad();
    adapter.rewardedSlot.markReady();
    adapter.appOpenSlot.beginLoad();
    adapter.appOpenSlot.markReady();

    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _config();
    AdManager().debugVipManager = _FakeVip();

    final result = await AdManager()
        .runIntegrationSelfCheck(loadTimeout: const Duration(seconds: 5));

    final rewarded = result.items.firstWhere((i) => i.name == 'Rewarded load');
    expect(rewarded.status, SelfCheckStatus.pass);
    expect(rewarded.detail, contains('already ready'));
    expect(adapter.loadRewardedCalls, 0,
        reason: 'rewarded readiness check must precede loadRewarded()');

    final appOpen = result.items.firstWhere((i) => i.name == 'App Open load');
    expect(appOpen.status, SelfCheckStatus.pass);
    expect(appOpen.detail, contains('already ready'));
    expect(adapter.loadAppOpenCalls, 0,
        reason: 'appOpen readiness check must precede loadAppOpen()');

    // Interstitial was not pre-marked ready, so it should have been loaded.
    expect(adapter.loadInterstitialCalls, 1);
  });

  test('all three fullscreen slots already ready resolves the entire check '
      'with zero adapter load invocations', () async {
    for (final slot in [
      adapter.interstitialSlot,
      adapter.rewardedSlot,
      adapter.appOpenSlot,
    ]) {
      slot.beginLoad();
      slot.markReady();
    }

    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _config();
    AdManager().debugVipManager = _FakeVip();

    final stopwatch = Stopwatch()..start();
    final result = await AdManager()
        .runIntegrationSelfCheck(loadTimeout: const Duration(seconds: 10));
    stopwatch.stop();

    expect(
        result.items
            .where((i) => i.name.endsWith(' load'))
            .every((i) => i.status == SelfCheckStatus.pass),
        isTrue,
        reason: 'all ad-load checks must pass; unrelated doctor wiring items '
            'are intentionally allowed to fail/skip in this isolated test');
    expect(adapter.loadInterstitialCalls, 0);
    expect(adapter.loadRewardedCalls, 0);
    expect(adapter.loadAppOpenCalls, 0);
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));

    for (final name in [
      'Interstitial load',
      'Rewarded load',
      'App Open load',
    ]) {
      final item = result.items.firstWhere((i) => i.name == name);
      expect(item.status, SelfCheckStatus.pass);
      expect(item.detail, contains('already ready'));
    }
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

    // B: coverage — SelfCheckItem.toJson and SelfCheckResult.toJson (lines 15,16,34,35).
    test('SelfCheckItem.toJson serialises name/status/detail correctly',
        () async {
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _config();
      AdManager().debugVipManager = _FakeVip();

      final result = await AdManager()
          .runIntegrationSelfCheck(loadTimeout: const Duration(seconds: 2));

      for (final item in result.items) {
        final j = item.toJson();
        expect(j['name'], item.name);
        expect(j['status'], item.status.name);
        expect(j.containsKey('detail'), isTrue);
      }
    });

    test('SelfCheckResult.toJson contains allPassed and items list', () async {
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _config();
      AdManager().debugVipManager = _FakeVip();

      final result = await AdManager()
          .runIntegrationSelfCheck(loadTimeout: const Duration(seconds: 2));

      final j = result.toJson();
      expect(j['allPassed'], isA<bool>());
      expect(j['items'], isA<List>());
      expect((j['items'] as List).length, result.items.length);
    });
  });
}
