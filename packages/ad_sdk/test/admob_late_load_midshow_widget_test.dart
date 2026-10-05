// Audit round 76 — widget-level proof of the user-visible consequence of the
// AdMob late-load guard: while an ad is on screen the fullscreen mutex stays
// held, so a host button bound to `fullscreenBusy` stays disabled and a second
// fullscreen show through the real AdManager is refused. A late fill used to
// move the slot out of `showing`, flip the mutex to "free" and allow stacking.
//
// The late fill is injected through FakeGmaBridge, so this proves SDK behaviour
// for that callback ORDER; it does not prove the native google_mobile_ads
// plugin can produce it (it cannot be forced on a device).

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/adapters/admob_adapter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'admob_behavioral_test.dart' show FakeGmaBridge, FakeGmaFullscreenAd;

const _config = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'b',
    interstitialId: 'i',
    appOpenId: 'ao',
    rewardedId: 'r',
  ),
);

class _Host extends StatelessWidget {
  const _Host({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: AdManager().fullscreenBusy,
            builder: (context, busy, child) => ElevatedButton(
              key: const Key('cta'),
              onPressed: busy ? null : onTap,
              child: Text(busy ? 'busy' : 'ready'),
            ),
          ),
        ),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeGmaBridge bridge;
  late AdMobAdapter adapter;

  setUp(() async {
    bridge = FakeGmaBridge();
    adapter = AdMobAdapter(bridge: bridge);
    expect(await adapter.initialize(_config), isTrue);
    AdManager().debugSetAdapter(adapter);
  });

  tearDown(() async {
    AdManager().debugSetAdapter(null);
    await adapter.dispose();
  });

  testWidgets(
      'a late fill mid-show keeps the host CTA disabled until the real dismiss',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(_Host(onTap: () => taps++));
    expect(find.text('ready'), findsOneWidget);

    await adapter.loadInterstitial();
    await adapter.showInterstitial(onDone: (_) {});
    await tester.pump();
    expect(find.text('busy'), findsOneWidget, reason: 'precondition');

    bridge.lastInterOnLoaded!(FakeGmaFullscreenAd());
    await tester.pump();

    expect(find.text('busy'), findsOneWidget,
        reason: 'the late fill must not flip the CTA back to enabled while '
            'an ad is still on screen');
    await tester.tap(find.byKey(const Key('cta')), warnIfMissed: false);
    expect(taps, 0, reason: 'a disabled button must not fire');

    bridge.lastInter!.shown!.onDismissed!();
    await tester.pump();
    expect(find.text('ready'), findsOneWidget,
        reason: 'the real dismiss must release the mutex');
  });

  testWidgets(
      'a late FAILURE mid-show does not drop the show into cooldown or free '
      'the mutex', (tester) async {
    await tester.pumpWidget(_Host(onTap: () {}));
    await adapter.loadRewarded();
    await adapter.showRewarded(onDone: (_) {});
    await tester.pump();
    expect(find.text('busy'), findsOneWidget, reason: 'precondition');

    bridge.lastRewardedOnFailed!(3, 'late');
    await tester.pump();

    expect(adapter.rewardedSlot.isShowing, isTrue);
    expect(find.text('busy'), findsOneWidget);

    // End the show so no watchdog timer outlives the test.
    bridge.lastRewarded!.shown!.onDismissed!();
    await tester.pump();
    expect(find.text('ready'), findsOneWidget);
  });

  testWidgets(
      'through AdManager: a second fullscreen show is refused while the first '
      'is on screen even after a late fill', (tester) async {
    await tester.pumpWidget(_Host(onTap: () {}));
    AdManager().debugCanRequestAds = true;
    await adapter.loadAppOpen();
    await adapter.showAppOpen(onDismiss: (_) {});
    bridge.lastAppOpenOnLoaded!(FakeGmaFullscreenAd());
    await tester.pump();

    await adapter.loadInterstitial();
    final interShowsBefore = bridge.lastInter?.showCount ?? 0;
    bool? shown;
    await AdManager().showInterstitial(onDoneFlow: (s) => shown = s);

    expect(shown, isFalse,
        reason: 'the SDK must refuse to stack a second fullscreen ad');
    expect(bridge.lastInter?.showCount ?? 0, interShowsBefore,
        reason: 'the native show must never be called');

    // End the on-screen App Open so no watchdog timer outlives the test.
    bridge.lastAppOpen!.shown!.onDismissed!();
    await tester.pump();
  });
}
