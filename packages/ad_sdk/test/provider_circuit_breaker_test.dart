import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

AdLoadEvent _failure() => const AdLoadEvent(
      providerTag: '[AppLovin]',
      type: AdSlotType.interstitial,
      placement: AdPlacement.unspecified,
      success: false,
    );

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('opens after threshold, allows one probe after cooldown, then closes',
      () async {
    var now = DateTime(2026, 1, 1);
    final advisor = ProviderFailoverAdvisor(
      consecutiveFailureThreshold: 2,
      persist: false,
      cooldown: const Duration(seconds: 10),
      now: () => now,
    );
    await advisor.ready;
    AdManager().debugEmit(_failure());
    AdManager().debugEmit(_failure());
    await _flush();
    expect(advisor.circuitState, ProviderCircuitState.open);
    expect(advisor.shouldFailoverNextSession, isTrue);
    now = now.add(const Duration(seconds: 11));
    expect(advisor.circuitState, ProviderCircuitState.halfOpen);
    expect(advisor.allowHalfOpenProbe(), isTrue);
    expect(advisor.allowHalfOpenProbe(), isFalse);
    AdManager().debugEmit(const AdLoadEvent(
      providerTag: '[AppLovin]',
      type: AdSlotType.interstitial,
      placement: AdPlacement.unspecified,
      success: true,
    ));
    await _flush();
    expect(advisor.circuitState, ProviderCircuitState.closed);
    expect(advisor.shouldFailoverNextSession, isFalse);
    await advisor.dispose();
  });

  test('failed half-open probe reopens the circuit and restarts cooldown',
      () async {
    var now = DateTime(2026, 1, 1);
    final advisor = ProviderFailoverAdvisor(
      consecutiveFailureThreshold: 1,
      persist: false,
      cooldown: const Duration(seconds: 5),
      now: () => now,
    );
    await advisor.ready;
    AdManager().debugEmit(_failure());
    await _flush();
    now = now.add(const Duration(seconds: 6));
    expect(advisor.allowHalfOpenProbe(), isTrue);
    AdManager().debugEmit(_failure());
    await _flush();
    expect(advisor.circuitState, ProviderCircuitState.open);
    expect(advisor.shouldFailoverNextSession, isTrue);
    await advisor.dispose();
  });

  test('non-positive cooldown is rejected', () {
    expect(
      () => ProviderFailoverAdvisor(persist: false, cooldown: Duration.zero),
      throwsArgumentError,
    );
  });
}
