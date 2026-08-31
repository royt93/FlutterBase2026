// T106 — bootstrap() sequences ATT → UMP → AdManager.initialize() in the
// one order the README already documents callers doing by hand. The `debug*`
// overrides stand in for ATT/UMP (no real platform channel for either in
// `flutter test`); initialize() itself runs for real against
// FakeAdProviderAdapter (T118) via AdManager.debugAdapterFactory, so the
// ordering assertion below reflects the actual production call sequence,
// not a re-description of it.
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

const _alChannel = MethodChannel('applovin_max');
const _gmaChannel = MethodChannel('plugins.flutter.io/google_mobile_ads');

class _OrderRecordingAdapter extends FakeAdProviderAdapter {
  _OrderRecordingAdapter(this.callOrder);
  final List<String> callOrder;

  @override
  Future<bool> initialize(
    AdConfig config, {
    String deviceGaid = '',
    bool isAgeRestrictedUser = false,
    AdConsent? consent,
  }) {
    callOrder.add('init');
    return super.initialize(config,
        deviceGaid: deviceGaid,
        isAgeRestrictedUser: isAgeRestrictedUser,
        consent: consent);
  }
}

const _config = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
      bannerId: 'b', interstitialId: 'i', appOpenId: 'ao', rewardedId: 'r'),
  // bootstrap() already runs the UMP step itself; the debug override below
  // bypasses AdManager entirely so its internal "already requested" skip
  // never engages — turning this off avoids initialize() ALSO trying a
  // real (unmocked) UMP round trip on top of it. In production, where
  // bootstrap() calls the real AdManager().requestUmpConsent(), leaving
  // this at its default `true` is fine — initialize()'s own skip-if-already-
  // requested logic covers that case.
  autoRequestUmpConsent: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<String> callOrder;

  setUp(() async {
    callOrder = <String>[];
    AdManager.debugAdapterFactory = (_) => _OrderRecordingAdapter(callOrder);
    messenger.setMockMethodCallHandler(_alChannel, (call) async => null);
    messenger.setMockMethodCallHandler(_gmaChannel, (call) async => null);
    await AdManager().destroy();
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData({});
  });

  tearDown(() async {
    AdManager.debugAdapterFactory = null;
    await AdManager().destroy();
    messenger.setMockMethodCallHandler(_alChannel, null);
    messenger.setMockMethodCallHandler(_gmaChannel, null);
  });

  test('bootstrap() runs ATT, then UMP, then initialize — in that order',
      () async {
    final result = await bootstrap(
      const AdBootstrapOptions(config: _config),
      debugRequestAtt: () async {
        callOrder.add('att');
        return const AttResult(status: AttStatus.authorized, idfa: 'idfa');
      },
      debugRequestUmp: () async {
        callOrder.add('ump');
        return const UmpConsentResult(
            canRequestAds: true, status: ConsentStatus.obtained);
      },
    );

    expect(callOrder, ['att', 'ump', 'init']);
    expect(result.att?.status, AttStatus.authorized);
    expect(result.ump.canRequestAds, isTrue);
    expect(result.initSuccess, isTrue);
  });

  test('requestAtt: false skips the ATT step entirely', () async {
    final result = await bootstrap(
      const AdBootstrapOptions(config: _config, requestAtt: false),
      debugRequestAtt: () async {
        callOrder.add('att');
        return const AttResult(status: AttStatus.authorized);
      },
      debugRequestUmp: () async {
        callOrder.add('ump');
        return const UmpConsentResult(
            canRequestAds: true, status: ConsentStatus.obtained);
      },
    );

    expect(callOrder, ['ump', 'init'],
        reason: 'att must never run when the caller opted out of it');
    expect(result.att, isNull,
        reason: 'null distinguishes "skipped" from "attempted and failed"');
  });

  test('a UMP result that cannot request ads still reaches initialize() — '
      'bootstrap does not gate init on consent itself, callers do',
      () async {
    final result = await bootstrap(
      const AdBootstrapOptions(config: _config),
      debugRequestAtt: () async => const AttResult(status: AttStatus.denied),
      debugRequestUmp: () async => const UmpConsentResult(
          canRequestAds: false, status: ConsentStatus.required),
    );

    expect(callOrder, ['init'],
        reason: 'the real requestAtt/requestUmp overrides above do not '
            'push into callOrder — only the adapter\'s initialize() does');
    expect(result.ump.canRequestAds, isFalse);
    expect(result.initSuccess, isTrue,
        reason: 'bootstrap sequences the calls; it is not a policy gate — '
            'AdManager.initialize() itself is what decides how to behave '
            'under non-personalised consent');
  });
}
