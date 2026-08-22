// MJ19 (2026-08-22 audit): when `AdManager.initialize()`'s adapter.initialize()
// call fails (or times out), the adapter it just built used to be silently
// abandoned — `AppLovinAdapter` wires its four native listeners BEFORE
// awaiting SDK init, so a late native callback after the 20s timeout kept
// firing into slots this manager had already walked away from, and every
// retry attempt (up to 4x) orphaned another one. The fix disposes the local
// `adapter` before returning on the `!ok` branch. This drives that exact
// branch via `AdManager.debugAdapterFactory`, a test-only seam that swaps
// which adapter instance gets built — the dispose call itself is the real
// production code path, not reimplemented here.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/core/ad_provider_adapter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FailingAdapter implements AdProviderAdapter {
  int disposeCalls = 0;
  bool initializeCalled = false;

  @override
  final AdSlot appOpenSlot = AdSlot(type: AdSlotType.appOpen);
  @override
  final AdSlot interstitialSlot = AdSlot(type: AdSlotType.interstitial);
  @override
  final AdSlot rewardedSlot = AdSlot(type: AdSlotType.rewarded);

  @override
  AdEventSink? eventSink;

  @override
  bool Function() canReload = () => true;

  @override
  Future<bool> initialize(
    AdConfig config, {
    String deviceGaid = '',
    bool isAgeRestrictedUser = false,
    AdConsent? consent,
  }) async {
    initializeCalled = true;
    return false;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _config = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'b',
    interstitialId: 'i',
    appOpenId: 'ao',
    rewardedId: 'r',
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    AdManager.debugAdapterFactory = null;
    AdManager().debugSetAdapter(null);
    await AdManager().destroy();
  });

  test(
      'MJ19: a failed adapter.initialize() disposes the adapter instead of '
      'orphaning it', () async {
    final failing = _FailingAdapter();
    AdManager.debugAdapterFactory = (config) => failing;

    await AdManager().initialize(
      config: _config,
      onComplete: (success, gaid) {},
    );

    expect(failing.initializeCalled, isTrue);
    expect(failing.disposeCalls, 1,
        reason: 'the adapter built for a failed init must be disposed, not '
            'left holding live native listeners');
    expect(AdManager().isInitialised, isFalse);
  });
}
