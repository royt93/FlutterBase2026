// Round-39 audit (Claude independent review) — the COPPA re-init branch in
// `AdManager.setConsent()` (fires only for AppLovin, when
// `isAgeRestrictedUser` flips) calls `applyConsentToProviders()` directly,
// with NO epoch guard, then `return`s before ever reaching the guarded tail
// write at the bottom of the function (round-38's MAJOR-2 fix). It is the
// same class of bug round 38 fixed for the main tail write, in a sibling
// branch the round-38 fix never touched.
//
// Failure mode: two overlapping `setConsent()` calls both flip
// `isAgeRestrictedUser` (e.g. a parental-control toggle switched off then
// immediately back on). Both enter this branch, both call
// `applyConsentToProviders()` unconditionally. If the OLDER call's own
// `ConsentManager.set()` persist-await (a real platform-channel gap) resolves
// AFTER the NEWER call has already applied its own (correct) value, the
// older call's stale write lands last on the real AppLovin SDK — even though
// `_consent` and everything the host reads back correctly report the newer
// value.

import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MinimalAppLovinAdapter implements AdProviderAdapter {
  _MinimalAppLovinAdapter({VoidCallback? onInitialize})
      : _onInitialize = onInitialize;

  final VoidCallback? _onInitialize;
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
  void applyConsent(AdConsent consent) {}

  void Function(AdEvent)? _eventSink;
  @override
  void Function(AdEvent)? get eventSink => _eventSink;
  @override
  set eventSink(void Function(AdEvent)? sink) => _eventSink = sink;

  @override
  bool Function() canReload = () => true;

  @override
  String get tag => '[fake-applovin]';

  @override
  Future<bool> initialize(
    AdConfig config, {
    String deviceGaid = '',
    bool isAgeRestrictedUser = false,
    AdConsent? consent,
  }) async {
    _onInitialize?.call();
    return !(isAgeRestrictedUser || consent?.isAgeRestrictedUser == true);
  }

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const alChannel = MethodChannel('applovin_max');
  const gmaChannel = MethodChannel('plugins.flutter.io/google_mobile_ads');

  final appLovinConsentCalls = <bool>[];
  var adapterInitializeCalls = 0;

  setUp(() {
    appLovinConsentCalls.clear();
    adapterInitializeCalls = 0;
    messenger.setMockMethodCallHandler(alChannel, (call) async {
      if (call.method == 'setHasUserConsent') {
        appLovinConsentCalls.add((call.arguments as Map)['value'] as bool);
      }
      return null;
    });
    messenger.setMockMethodCallHandler(gmaChannel, (call) async => null);
    SharedPreferences.setMockInitialValues({});
    AdManager.debugAdapterFactory = (_) => _MinimalAppLovinAdapter(
        onInitialize: () => adapterInitializeCalls++);
  });

  tearDown(() async {
    ConsentManager.debugApplyBarrier = null;
    AdManager.debugAdapterFactory = null;
    await AdManager().destroy();
    messenger.setMockMethodCallHandler(alChannel, null);
    messenger.setMockMethodCallHandler(gmaChannel, null);
  });

  test(
      'COPPA re-init branch: an older setConsent() flip whose ConsentManager '
      'apply is delayed must never overwrite a newer overlapping flip', () async {
    await AdManager()
        .initialize(config: _appLovinConfig, onComplete: (_, __) {});
    // Prime a baseline (isAgeRestrictedUser: false) via the normal, already
    // guarded tail path — establishes `previousAgeRestricted` for the race
    // below without exercising the COPPA branch yet.
    await AdManager().setConsent(
      const AdConsent(hasUserConsent: true, isAgeRestrictedUser: false),
    );
    appLovinConsentCalls.clear();
    adapterInitializeCalls = 0;

    // Older call: a parental-control toggle turning OFF consent and flipping
    // isAgeRestrictedUser -> true (child mode). Its own ConsentManager apply
    // parks right before it would fire — simulating the real
    // platform-channel delay round 38 reproduced on-device.
    final olderGate = Completer<void>();
    ConsentManager.debugApplyBarrier = olderGate.future;
    final older = AdManager().setConsent(
      const AdConsent(hasUserConsent: false, isAgeRestrictedUser: true),
    );
    await Future<void>.delayed(Duration.zero);
    expect(appLovinConsentCalls, isEmpty,
        reason: 'sanity: the older call must not have written anything yet '
            '— it is parked at the barrier');

    // Newer call fired right behind it — the toggle flipped straight back
    // (adult mode, consent given). No barrier of its own — races ahead and
    // completes its entire real apply first.
    ConsentManager.debugApplyBarrier = null;
    final newer = AdManager().setConsent(
      const AdConsent(hasUserConsent: true, isAgeRestrictedUser: false),
    );
    await newer;
    expect(appLovinConsentCalls, isNotEmpty);
    expect(appLovinConsentCalls.every((v) => v == true), isTrue,
        reason: 'the newer call must have written its own (correct) value '
            'for real');

    // Let the newer call's own `unawaited(initialize(...))` (fired from
    // inside its COPPA branch) fully resolve — its `_isInitializing` must be
    // back to false, exactly the real-world timing round-39's re-review
    // targets, before releasing the older call below.
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    // Release the older, now-superseded call. Pre-fix, its unguarded COPPA
    // write would fire AppLovinMAX.setHasUserConsent(false) chronologically
    // AFTER the newer call's (true) — silently re-enforcing the stale,
    // withdrawn decision on the real AppLovin SDK for a session that just
    // legitimately re-granted consent. (Each setConsent() call fires this
    // channel twice — once via ConsentManager's own internal apply, once via
    // this branch's direct call — so both must agree, not just one.)
    olderGate.complete();
    await older;
    // Flush the microtask queue so a stale, unawaited re-init (if the bug
    // were still present) has a real chance to actually run before asserting
    // it didn't.
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(appLovinConsentCalls.every((v) => v == true), isTrue,
        reason: 'the older call\'s stale write must never fire at all once '
            'superseded — no `false` may ever appear here');

    // Round-39 re-review (MINOR, independent Gemini pass) — the older call's
    // own re-init (`unawaited(initialize(config: cfg, ...))`) sat OUTSIDE the
    // epoch guard above, so a superseded call could still trigger a whole
    // extra, unnecessary SDK re-initialisation cycle after the newer call had
    // already legitimately re-initialised once.
    expect(adapterInitializeCalls, 1,
        reason: 'only the newer call\'s own re-init may run — the older, '
            'superseded call must not trigger a redundant extra one');
  });
}
