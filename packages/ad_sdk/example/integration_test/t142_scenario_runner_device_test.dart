import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('T142: ScenarioRunner runs deterministic scenario offline on physical device', (tester) async {
    final runner = ScenarioRunner();

    final result = await runner.run(const [
      ScenarioStep(action: ScenarioStepAction.initialize),
      ScenarioStep(action: ScenarioStepAction.loadInterstitial),
      ScenarioStep(action: ScenarioStepAction.showInterstitial),
      ScenarioStep(action: ScenarioStepAction.loadRewarded),
      ScenarioStep(action: ScenarioStepAction.showRewarded),
    ]);

    expect(result.success, isTrue);
    expect(result.events.whereType<AdLoadEvent>(), hasLength(2));
    expect(result.events.whereType<AdShowEvent>(), hasLength(2));
  });
}
