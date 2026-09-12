import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('T208 device smoke: provider circuit opens on real event stream',
      (tester) async {
    final advisor =
        ProviderFailoverAdvisor(consecutiveFailureThreshold: 2, persist: false);
    await advisor.ready;
    const event = AdLoadEvent(
      providerTag: '[AppLovin]',
      type: AdSlotType.interstitial,
      placement: AdPlacement.unspecified,
      success: false,
    );
    AdManager().debugEmit(event);
    AdManager().debugEmit(event);
    await tester.pump();
    expect(advisor.circuitState, ProviderCircuitState.open);
    expect(advisor.failingProvider, AdProvider.appLovin);
    await advisor.dispose();
  });
}
