// Tests for AdManager.runIntegrationSelfCheck() (T41 brainstorm) — the
// debug-only partner checklist covering init/consent/per-slot-load/VIP
// wiring, driven through the same debugSetAdapter/debugConfig seams as
// ad_manager_core_test.dart.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/core/ad_provider_adapter.dart'
    show AdEventSink;
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Minimal fake adapter — reports success/failure per slot via a real
/// eventSink (wired manually in setUp, mirroring what AdManager.initialize()
/// does for a real adapter) so runIntegrationSelfCheck()'s AdLoadEvent
/// listener has something to observe.
class _FakeAdapter implements AdProviderAdapter {
  @override
  AdEventSink? eventSink;

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
  });

  tearDown(() {
    AdManager().debugSetAdapter(null);
    AdManager().debugConfig = null;
    AdManager().debugVipManager = null;
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
}
