import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('ScenarioRunner records deterministic load and show events', () async {
    final runner = ScenarioRunner();

    final result = await runner.run(const [
      ScenarioStep(action: ScenarioStepAction.initialize),
      ScenarioStep(action: ScenarioStepAction.loadInterstitial),
      ScenarioStep(action: ScenarioStepAction.showInterstitial),
    ]);

    expect(result.success, isTrue);
    expect(result.error, isNull);
    expect(result.events.whereType<AdLoadEvent>(), hasLength(1));
    expect(result.events.whereType<AdShowEvent>(), hasLength(1));

    final load = result.events.whereType<AdLoadEvent>().single;
    expect(load.type, AdSlotType.interstitial);
    expect(load.success, isTrue);

    final show = result.events.whereType<AdShowEvent>().single;
    expect(show.type, AdSlotType.interstitial);
    expect(show.success, isTrue);
  });

  test('ScenarioRunner scripts load failure deterministically', () async {
    final runner = ScenarioRunner();

    final result = await runner.run(const [
      ScenarioStep(action: ScenarioStepAction.initialize),
      ScenarioStep(
        action: ScenarioStepAction.loadRewarded,
        shouldSucceed: false,
      ),
      ScenarioStep(action: ScenarioStepAction.showRewarded),
    ]);

    expect(result.success, isTrue);
    final load = result.events.whereType<AdLoadEvent>().single;
    expect(load.type, AdSlotType.rewarded);
    expect(load.success, isFalse);
    expect(load.errorCode, -1);

    final show = result.events.whereType<AdShowEvent>().single;
    expect(show.type, AdSlotType.rewarded);
    expect(show.success, isFalse);
  });

  test('ScenarioRunner writes AdEventLog and builds MonetizationDigitalTwin', () async {
    final prefs = await AdPreferences.getInstance();
    final log = AdEventLog(prefs);
    final runner = ScenarioRunner(eventLog: log);

    final result = await runner.run(const [
      ScenarioStep(action: ScenarioStepAction.initialize),
      ScenarioStep(action: ScenarioStepAction.loadInterstitial),
      ScenarioStep(action: ScenarioStepAction.showInterstitial),
    ]);

    await log.flush();

    expect(result.success, isTrue);
    expect(log.entries.map((e) => e['eventType']), contains('AdLoadEvent'));
    expect(log.entries.map((e) => e['eventType']), contains('AdShowEvent'));
    expect(result.digitalTwin, isNotNull);
    expect(result.digitalTwin!.actualDailyOutcomes.single.shown, 1);
  });
}
