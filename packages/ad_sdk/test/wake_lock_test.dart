// Wake lock feature — AdConfig.keepScreenOnDuringSession (default true) keeps
// the device screen on for the whole SDK session so a video ad or an idle
// splash isn't interrupted by the device auto-locking. Runtime override via
// AdManager.setKeepScreenOn. Real toggle calls go through
// AdManager.debugWakelockToggleOverride in tests instead of the real
// WakelockPlus platform channel.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ConsentManager.applyToProviders() unconditionally touches both native
// bridges regardless of the active provider (see
// consent_persistence_on_init_test.dart's identical setup).
const _alChannel = MethodChannel('applovin_max');
const _gmaChannel = MethodChannel('plugins.flutter.io/google_mobile_ads');

class _OkAdapter implements AdProviderAdapter {
  @override
  void applyConsent(AdConsent consent) {}

  @override
  Future<bool> initialize(
    AdConfig config, {
    String deviceGaid = '',
    bool isAgeRestrictedUser = false,
    AdConsent? consent,
  }) async =>
      true;

  @override
  String get tag => 'stub';

  @override
  final AdSlot appOpenSlot = AdSlot(type: AdSlotType.appOpen);
  @override
  final AdSlot interstitialSlot = AdSlot(type: AdSlotType.interstitial);
  @override
  final AdSlot rewardedSlot = AdSlot(type: AdSlotType.rewarded);
  @override
  final AdSlot rewardedInterstitialSlot =
      AdSlot(type: AdSlotType.rewardedInterstitial);

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

AdConfig _config({bool keepScreenOnDuringSession = true}) => AdConfig(
      provider: AdProvider.admob,
      admob: const AdMobConfig(
          bannerId: 'b', interstitialId: 'i', appOpenId: 'ao', rewardedId: 'r'),
      autoRequestUmpConsent: false,
      keepScreenOnDuringSession: keepScreenOnDuringSession,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AdManager.debugAdapterFactory = (config) => _OkAdapter();
    messenger.setMockMethodCallHandler(_alChannel, (call) async => null);
    messenger.setMockMethodCallHandler(_gmaChannel, (call) async => null);
  });

  tearDown(() async {
    AdManager.debugWakelockToggleOverride = null;
    AdManager.debugSimulateReleaseModeForTestSeams = false;
    AdManager.debugAdapterFactory = null;
    await AdManager().destroy();
    messenger.setMockMethodCallHandler(_alChannel, null);
    messenger.setMockMethodCallHandler(_gmaChannel, null);
  });

  test('initialize() enables wake lock when keepScreenOnDuringSession is '
      '(default) true', () async {
    final calls = <bool>[];
    AdManager.debugWakelockToggleOverride = (enable) async => calls.add(enable);

    await AdManager().initialize(config: _config(), onComplete: (_, __) {});
    await pumpEventQueue();

    expect(calls, [true]);
  });

  test('initialize() does not enable wake lock when '
      'keepScreenOnDuringSession is false', () async {
    final calls = <bool>[];
    AdManager.debugWakelockToggleOverride = (enable) async => calls.add(enable);

    await AdManager().initialize(
        config: _config(keepScreenOnDuringSession: false),
        onComplete: (_, __) {});
    await pumpEventQueue();

    expect(calls, isEmpty,
        reason: 'a host that opts out must not have its screen kept on');
  });

  test('destroy() always releases the wake lock, even if it was never '
      'enabled', () async {
    final calls = <bool>[];
    AdManager.debugWakelockToggleOverride = (enable) async => calls.add(enable);

    await AdManager().initialize(
        config: _config(keepScreenOnDuringSession: false),
        onComplete: (_, __) {});
    await pumpEventQueue();
    await AdManager().destroy();

    expect(calls, [false],
        reason: 'destroy() must release the wake lock unconditionally — '
            'safe even when it was never acquired');
  });

  test('destroy() releases a wake lock that initialize() acquired', () async {
    final calls = <bool>[];
    AdManager.debugWakelockToggleOverride = (enable) async => calls.add(enable);

    await AdManager().initialize(config: _config(), onComplete: (_, __) {});
    await pumpEventQueue();
    await AdManager().destroy();

    expect(calls, [true, false]);
  });

  test('setKeepScreenOn toggles directly, independent of AdConfig', () async {
    final calls = <bool>[];
    AdManager.debugWakelockToggleOverride = (enable) async => calls.add(enable);

    await AdManager().setKeepScreenOn(false);
    await AdManager().setKeepScreenOn(true);

    expect(calls, [false, true]);
  });

  test('debugWakelockToggleOverride is ignored while release mode is '
      'simulated', () async {
    final calls = <bool>[];
    AdManager.debugWakelockToggleOverride = (enable) async => calls.add(enable);
    AdManager.debugSimulateReleaseModeForTestSeams = true;

    // Falls through to the real WakelockPlus platform channel, which throws
    // MissingPluginException in a unit test — caught and logged by
    // AdManager._setWakelock's own defensive wrapper, not left uncaught.
    await AdManager().setKeepScreenOn(true);

    expect(calls, isEmpty,
        reason: 'the override must not apply in a (simulated) release '
            'build');
  });
}
