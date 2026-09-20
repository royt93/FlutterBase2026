// T106 — bootstrap() sequences ATT → UMP → AdManager.initialize() in the
// one order the README already documents callers doing by hand. The `debug*`
// overrides stand in for ATT/UMP (no real platform channel for either in
// `flutter test`); initialize() itself runs for real against
// FakeAdProviderAdapter (T118) via AdManager.debugAdapterFactory, so the
// ordering assertion below reflects the actual production call sequence,
// not a re-description of it.
import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:fake_async/fake_async.dart';
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

  group('round-32 audit (MAJOR): bootstrap() must not hang for '
      'AdManager.initialize()\'s full ~130s worst-case retry pileup '
      '(20s init timeout + [5s,15s,30s] backoff x4 attempts)', () {
    test('a wedged initialize() (never calls onComplete) still returns '
        'within the default initTimeout, not 130s later', () {
      fakeAsync((async) {
        AdManager.debugAdapterFactory = (_) => _HangingInitAdapter();

        AdBootstrapResult? result;
        bootstrap(
          const AdBootstrapOptions(config: _config),
          debugRequestAtt: () async =>
              const AttResult(status: AttStatus.authorized),
          debugRequestUmp: () async => const UmpConsentResult(
              canRequestAds: true, status: ConsentStatus.obtained),
        ).then((r) => result = r);

        // Default initTimeout is 20s — elapse just past it, nowhere near
        // the ~130s a real wedged native init retry loop could take.
        async.elapse(const Duration(seconds: 21));

        expect(result, isNotNull,
            reason: 'bootstrap() must give up waiting on init and return, '
                'not hang for the full retry pileup');
        expect(result!.initSuccess, isFalse,
            reason: 'init never actually reported success within the '
                'timeout — must not be reported as true');
      });
    });

    test('initTimeout: null restores the old unbounded-wait behaviour', () {
      fakeAsync((async) {
        AdManager.debugAdapterFactory = (_) => _HangingInitAdapter();

        AdBootstrapResult? result;
        bootstrap(
          const AdBootstrapOptions(config: _config, initTimeout: null),
          debugRequestAtt: () async =>
              const AttResult(status: AttStatus.authorized),
          debugRequestUmp: () async => const UmpConsentResult(
              canRequestAds: true, status: ConsentStatus.obtained),
        ).then((r) => result = r);

        async.elapse(const Duration(minutes: 10));

        expect(result, isNull,
            reason: 'an explicit null must opt back out of the timeout — '
                'this is an intentional escape hatch, not just this '
                'default\'s absence');
      });
    });
  });

  // Round 52 audit fix (MINOR) — same reasoning as AttResult.toString()
  // never printing the raw idfa: AdBootstrapResult is a public return value
  // a host may log/print directly, entirely outside this SDK's own
  // SafeLogger redaction.
  test('toString() never prints the raw GAID', () {
    const result = AdBootstrapResult(
      att: null,
      ump: UmpConsentResult(canRequestAds: true, status: ConsentStatus.obtained),
      initSuccess: true,
      gaid: '38400000-8cf0-11bd-b23e-10b96e40000d',
    );

    expect(result.toString(), isNot(contains('38400000-8cf0-11bd-b23e')),
        reason: 'the raw device advertising ID must never appear in a '
            'toString() a host might pass straight to a logger or crash '
            'reporter');
    expect(result.toString(), contains('hasGaid=true'));
  });
}

/// `initialize()` never resolves — the worst case this timeout guards
/// against (a wedged native SDK init call that never calls back).
class _HangingInitAdapter extends FakeAdProviderAdapter {
  @override
  Future<bool> initialize(
    AdConfig config, {
    String deviceGaid = '',
    bool isAgeRestrictedUser = false,
    AdConsent? consent,
  }) =>
      Completer<bool>().future;
}
