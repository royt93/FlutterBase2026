// M2 (2026-08-22 audit, independent review): AppLovin MAX 4.x has no runtime
// setIsAgeRestrictedUser API, so a COPPA flag flip mid-session has to
// re-initialise the adapter to carry the new value (MJ7). AppLovinAdapter
// aborts init BY DESIGN for a child-directed audience, so flipping the flag
// to true legitimately leaves `_config`/`_adapter` null afterwards. The bug:
// the host correcting the flag back to false then hit setConsent()'s
// `if (!isInitialised) return;` early guard BEFORE ever reaching the COPPA
// recovery block, because that block used to sit below it — AppLovin stayed
// dead for the rest of the session with no way back short of destroy() +
// initialize(). The fix moved the COPPA block above the guard and reads
// `_config ?? _lastKnownConfig`, since `_lastKnownConfig` alone survives the
// failed re-init (see its doc comment: cleared only by destroy()).

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/core/ad_provider_adapter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Mirrors AppLovinAdapter's real, documented behaviour: refuses to
/// initialise for a child-directed (COPPA) audience.
class _CoppaAwareAdapter implements AdProviderAdapter {
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
  AdEventSink? eventSink;
  @override
  bool Function() canReload = () => true;
  @override
  String get tag => '[fake-coppa]';

  int initializeCalls = 0;
  final List<bool> ageRestrictedPerCall = [];

  @override
  Future<bool> initialize(
    AdConfig config, {
    String deviceGaid = '',
    bool isAgeRestrictedUser = false,
    AdConsent? consent,
  }) async {
    initializeCalls++;
    final restricted = isAgeRestrictedUser || consent?.isAgeRestrictedUser == true;
    ageRestrictedPerCall.add(restricted);
    return !restricted;
  }

  @override
  Future<void> dispose() async {}

  @override
  void applyConsent(AdConsent consent) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _appLovinConfig = AdConfig(
  provider: AdProvider.appLovin,
  autoRequestUmpConsent: false,
  enableCrashGuard: false,
  appLovin: AppLovinConfig(
    sdkKey: 'key',
    bannerId: 'b',
    interstitialId: 'i',
    appOpenId: 'ao',
    rewardedId: 'r',
  ),
);

/// The re-init this drives is fired via `unawaited(...)` (setConsent() does
/// not — and must not — block on it; see its own comment). Poll instead of a
/// fixed sleep: every await in that chain resolves against fast, already
/// primed test doubles, so this settles in well under the bound.
Future<void> _pumpUntil(bool Function() done) async {
  for (var i = 0; i < 500 && !done(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // applyConsentToProviders fires native calls on these channels (AppLovin's
  // are not awaited, so a MissingPluginException would surface as an
  // unhandled async error and fail the test) — same pattern as
  // ad_consent_test.dart.
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const alChannel = MethodChannel('applovin_max');
  const gmaChannel = MethodChannel('plugins.flutter.io/google_mobile_ads');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(alChannel, (call) async => null);
    messenger.setMockMethodCallHandler(gmaChannel, (call) async => null);
  });

  tearDown(() async {
    AdManager.debugAdapterFactory = null;
    await AdManager().destroy();
    messenger.setMockMethodCallHandler(alChannel, null);
    messenger.setMockMethodCallHandler(gmaChannel, null);
  });

  test(
      'M2: correcting COPPA back to false rebuilds AppLovin even after the '
      'COPPA-true re-init aborted', () async {
    final adapter = _CoppaAwareAdapter();
    AdManager.debugAdapterFactory = (config) => adapter;

    await AdManager().initialize(
      config: _appLovinConfig,
      onComplete: (_, _) {},
    );
    expect(AdManager().isInitialised, isTrue);
    expect(adapter.initializeCalls, 1);

    // Host flips COPPA on — AppLovin's own init aborts by design.
    await AdManager().setConsent(const AdConsent(isAgeRestrictedUser: true));
    await _pumpUntil(() => adapter.initializeCalls >= 2);
    expect(adapter.ageRestrictedPerCall[1], isTrue);
    expect(AdManager().isInitialised, isFalse,
        reason: 'sanity: AppLovin must actually have refused this init, or '
            'the recovery below proves nothing');

    // Host corrects the mistake — this must not silently no-op.
    await AdManager().setConsent(const AdConsent(isAgeRestrictedUser: false));
    await _pumpUntil(() => adapter.initializeCalls >= 3);

    expect(adapter.initializeCalls, 3,
        reason: 'M2: the COPPA recovery must reach the re-init block using '
            '_lastKnownConfig, not bail out at the !isInitialised guard');
    expect(adapter.ageRestrictedPerCall[2], isFalse);
    expect(AdManager().isInitialised, isTrue,
        reason: 'AppLovin must come back up once the flag is corrected');
  });
}
