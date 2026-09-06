// T137 on-device integration test — `initialize(..., remoteSafetyProvider:,
// remoteSafetyAutoRefreshInterval:)` must actually call
// fetchSafetyParamOverrides() again on that schedule, on top of the one-time
// fetch T88 already does at init, and must stop calling it after destroy().
//
// Run with:
//   flutter test integration_test/t137_periodic_refresh_test.dart -d <device-or-sim-id>

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

class _CountingRemoteSafetyProvider implements RemoteAdSafetyProvider {
  int callCount = 0;

  @override
  Future<Map<String, dynamic>?> fetchSafetyParamOverrides() async {
    callCount++;
    return null;
  }
}

AdConfig _config() => AdConfig(
      provider: AdProvider.admob,
      admob: const AdMobConfig(
        bannerId: 'ca-app-pub-3940256099942544/6300978111',
        interstitialId: 'ca-app-pub-3940256099942544/1033173712',
        appOpenId: 'ca-app-pub-3940256099942544/9257395921',
        rewardedId: 'ca-app-pub-3940256099942544/5224354917',
      ),
      safety: const AdSafetyParams(dryRun: true),
    );

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    await AdManager().destroy();
  });

  testWidgets(
      'remoteSafetyAutoRefreshInterval makes fetchSafetyParamOverrides() '
      'fire again on schedule, beyond the one-time init fetch',
      (tester) async {
    final provider = _CountingRemoteSafetyProvider();

    await AdManager().initialize(
      config: _config(),
      remoteSafetyProvider: provider,
      remoteSafetyAutoRefreshInterval: const Duration(seconds: 2),
      onComplete: (_, __) {},
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(provider.callCount, 1,
        reason: 'sanity: initialize() itself makes the one-time T88 fetch');

    // Real wall-clock wait — Timer.periodic needs real time to fire, this
    // is exactly why this proof belongs on-device, not in a mocked unit
    // test.
    await Future<void>.delayed(const Duration(seconds: 5));
    await tester.pump();

    expect(provider.callCount, greaterThanOrEqualTo(3),
        reason: 'a 2s interval waited out for 5s must have fired at least '
            'twice more beyond the initial call — proves the periodic '
            'Timer is real, not just configured and ignored');

    final countBeforeDestroy = provider.callCount;
    await AdManager().destroy();
    await Future<void>.delayed(const Duration(seconds: 3));
    await tester.pump();

    expect(provider.callCount, countBeforeDestroy,
        reason: 'destroy() must cancel the periodic timer — no further '
            'calls once the session it belonged to is torn down');
  });
}
