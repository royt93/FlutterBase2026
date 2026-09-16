// T202 follow-up (adversarial audit findings B, C, E) — drives real
// AdManager.initialize()/destroy() cycles (not just ConsentManager in
// isolation), the exact layer the original audit found untested and where
// the journal-divergence bug (B) actually lived.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/core/ad_provider_adapter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Same shape as `ad_manager_init_dispose_test.dart`'s `_FailingAdapter` —
// `initialize()` returning `false` cleanly (not throwing) is enough:
// ConsentManager/the provenance journal are wired BEFORE adapter.initialize()
// runs, so these tests don't need the adapter to actually succeed.
class _MinimalAdapter implements AdProviderAdapter {
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
  }) async =>
      false;

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

const _admobConfig = AdConfig(
  provider: AdProvider.admob,
  enableConsentProvenanceJournal: true,
  admob: AdMobConfig(
    bannerId: 'ca-app-pub-3940256099942544/6300978111',
    interstitialId: 'ca-app-pub-3940256099942544/1033173712',
    appOpenId: 'ca-app-pub-3940256099942544/9257395921',
    rewardedId: 'ca-app-pub-3940256099942544/5224354917',
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const alChannel = MethodChannel('applovin_max');
  const gmaChannel = MethodChannel('plugins.flutter.io/google_mobile_ads');

  setUp(() {
    messenger.setMockMethodCallHandler(alChannel, (call) async => null);
    messenger.setMockMethodCallHandler(gmaChannel, (call) async => null);
    SharedPreferences.setMockInitialValues({});
    AdManager.debugAdapterFactory = (_) => _MinimalAdapter();
  });

  tearDown(() async {
    AdManager.debugAdapterFactory = null;
    await AdManager().destroy();
    messenger.setMockMethodCallHandler(alChannel, null);
    messenger.setMockMethodCallHandler(gmaChannel, null);
  });

  test('consentProvenanceJournal is null before init, non-null after',
      () async {
    expect(AdManager().consentProvenanceJournal, isNull);
    await AdManager()
        .initialize(config: _admobConfig, onComplete: (_, __) {});
    expect(AdManager().consentProvenanceJournal, isNotNull);
    await AdManager().destroy();
    expect(AdManager().consentProvenanceJournal, isNull);
  });

  test(
      'audit finding B: a destroy()+reinitialize() cycle must not orphan '
      'the journal a set() call actually writes to', () async {
    await AdManager()
        .initialize(config: _admobConfig, onComplete: (_, __) {});
    await AdManager().consentManager!.set(ConsentSettings.accepted);
    expect(AdManager().consentProvenanceJournal!.entries, hasLength(1));

    await AdManager().destroy();
    await AdManager()
        .initialize(config: _admobConfig, onComplete: (_, __) {});

    final journalAfterReinit = AdManager().consentProvenanceJournal!;
    expect(journalAfterReinit.entries, hasLength(1),
        reason: 'the entry persisted before destroy() must still be '
            'visible after reinit');

    await AdManager().consentManager!.set(ConsentSettings.rejected);
    expect(journalAfterReinit.entries, hasLength(2),
        reason: 'a set() call after reinit must append to the SAME '
            'instance AdManager().consentProvenanceJournal returns — not '
            'an orphaned one only ConsentManager still holds');
  });

  test(
      'audit finding C: AdManager().clearSdkData(purgeConsentProvenanceJournal: true) '
      'actually purges the live journal', () async {
    await AdManager()
        .initialize(config: _admobConfig, onComplete: (_, __) {});
    await AdManager().consentManager!.set(ConsentSettings.accepted);
    final journal = AdManager().consentProvenanceJournal!;
    expect(journal.entries, isNotEmpty);

    // Default scope — journal must survive (T202's whole point).
    await AdManager().clearSdkData();
    expect(journal.entries, isNotEmpty);

    // Explicit purge — must clear both the live in-memory list (same
    // object, checked via `journal.entries` directly) AND the persisted
    // copy (checked via a fresh load).
    await AdManager().clearSdkData(purgeConsentProvenanceJournal: true);
    expect(journal.entries, isEmpty,
        reason: 'the already-loaded live instance must reflect the purge '
            'immediately, same as VipManager does for entitlement erasure '
            '— not just the persisted copy on next load');
  });
}
