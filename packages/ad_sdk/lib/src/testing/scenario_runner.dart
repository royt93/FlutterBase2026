import '../adapters/fake_adapter.dart';
import '../compliance/ad_event_log.dart';
import '../config/ad_config.dart';
import '../monetization/digital_twin.dart';
import '../state/ad_event.dart';
import '../state/ad_placement.dart';
import '../state/ad_slot.dart';

/// Actions that can be executed in an offline deterministic ad test scenario.
enum ScenarioStepAction {
  initialize,
  loadAppOpen,
  showAppOpen,
  loadInterstitial,
  showInterstitial,
  loadRewarded,
  showRewarded,
  loadRewardedInterstitial,
  showRewardedInterstitial,
}

/// A single step in a deterministic QA test scenario.
class ScenarioStep {
  const ScenarioStep({
    required this.action,
    this.placement = AdPlacement.unspecified,
    this.shouldSucceed = true,
    this.loadDelay = Duration.zero,
    this.ssvUserId,
    this.ssvCustomData,
  });

  final ScenarioStepAction action;
  final AdPlacement placement;

  /// Whether the next load call made by this step should resolve successful.
  final bool shouldSucceed;

  /// Synthetic delay applied to the next fake-adapter load call.
  final Duration loadDelay;

  final String? ssvUserId;
  final String? ssvCustomData;
}

/// The recorded result of running a scenario.
class ScenarioResult {
  const ScenarioResult({
    required this.events,
    required this.success,
    this.error,
    this.digitalTwin,
  });

  /// All [AdEvent]s emitted during the scenario execution.
  final List<AdEvent> events;

  /// Whether the scenario ran to completion without unhandled exceptions.
  final bool success;

  /// Any exception encountered during execution.
  final Object? error;

  /// Replay helper built from [ScenarioRunner.eventLog], when a log was supplied.
  final MonetizationDigitalTwin? digitalTwin;
}

/// Offline deterministic scenario runner for QA and automated testing.
///
/// Runs directly against [FakeAdProviderAdapter], never native SDKs or network.
/// If [eventLog] is supplied, every emitted event is also recorded so callers
/// can replay it through [MonetizationDigitalTwin].
class ScenarioRunner {
  ScenarioRunner({
    FakeAdProviderAdapter? adapter,
    this.eventLog,
    AdConfig? config,
  })  : adapter = adapter ?? FakeAdProviderAdapter(),
        config = config ?? _defaultFakeConfig;

  final FakeAdProviderAdapter adapter;
  final AdEventLog? eventLog;
  final AdConfig config;

  /// Executes [steps] deterministically against [adapter].
  Future<ScenarioResult> run(List<ScenarioStep> steps) async {
    final recordedEvents = <AdEvent>[];
    final previousSink = adapter.eventSink;

    void emit(AdEvent event) {
      recordedEvents.add(event);
      eventLog?.recordEvent(event);
      previousSink?.call(event);
    }

    adapter.eventSink = emit;
    try {
      for (final step in steps) {
        adapter.shouldSucceed = step.shouldSucceed;
        adapter.loadDelay = step.loadDelay;

        switch (step.action) {
          case ScenarioStepAction.initialize:
            await adapter.initialize(config);
          case ScenarioStepAction.loadAppOpen:
            await adapter.loadAppOpen();
          case ScenarioStepAction.showAppOpen:
            await adapter.showAppOpen(
              onDismiss: (dismissed) => emit(AdShowEvent(
                providerTag: adapter.tag,
                type: AdSlotType.appOpen,
                placement: step.placement,
                success: dismissed,
                requestId: adapter.appOpenSlot.requestId,
              )),
            );
          case ScenarioStepAction.loadInterstitial:
            await adapter.loadInterstitial();
          case ScenarioStepAction.showInterstitial:
            await adapter.showInterstitial(
              onDone: (shown) => emit(AdShowEvent(
                providerTag: adapter.tag,
                type: AdSlotType.interstitial,
                placement: step.placement,
                success: shown,
                requestId: adapter.interstitialSlot.requestId,
              )),
            );
          case ScenarioStepAction.loadRewarded:
            await adapter.loadRewarded();
          case ScenarioStepAction.showRewarded:
            await adapter.showRewarded(
              ssvUserId: step.ssvUserId,
              ssvCustomData: step.ssvCustomData,
              onDone: (result) {
                if (result.earned) {
                  emit(AdRewardEvent(
                    providerTag: adapter.tag,
                    placement: step.placement,
                    label: result.label,
                    amount: result.amount,
                    pendingServerConfirmation: result.pendingServerConfirmation,
                  ));
                }
                emit(AdShowEvent(
                  providerTag: adapter.tag,
                  type: AdSlotType.rewarded,
                  placement: step.placement,
                  success: result.shown,
                  requestId: adapter.rewardedSlot.requestId,
                ));
              },
            );
          case ScenarioStepAction.loadRewardedInterstitial:
            await adapter.loadRewardedInterstitial();
          case ScenarioStepAction.showRewardedInterstitial:
            await adapter.showRewardedInterstitial(
              onDone: (result) {
                if (result.earned) {
                  emit(AdRewardEvent(
                    providerTag: adapter.tag,
                    placement: step.placement,
                    label: result.label,
                    amount: result.amount,
                  ));
                }
                emit(AdShowEvent(
                  providerTag: adapter.tag,
                  type: AdSlotType.rewardedInterstitial,
                  placement: step.placement,
                  success: result.shown,
                  requestId: adapter.rewardedInterstitialSlot.requestId,
                ));
              },
            );
        }
      }
      return ScenarioResult(
        events: recordedEvents,
        success: true,
        digitalTwin: eventLog == null
            ? null
            : MonetizationDigitalTwin(eventLog!.entries),
      );
    } catch (e) {
      return ScenarioResult(
        events: recordedEvents,
        success: false,
        error: e,
        digitalTwin: eventLog == null
            ? null
            : MonetizationDigitalTwin(eventLog!.entries),
      );
    } finally {
      adapter.eventSink = previousSink;
    }
  }
}

const _defaultFakeConfig = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'fake-banner',
    interstitialId: 'fake-interstitial',
    appOpenId: 'fake-app-open',
    rewardedId: 'fake-rewarded',
  ),
);
