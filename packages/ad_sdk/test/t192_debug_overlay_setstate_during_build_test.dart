// T192 — DebugAdOverlay could crash with "setState() or markNeedsBuild()
// called during build" if the panel was already expanded (subscribed to
// AdSlot.state/AdManager().initRevision) and something ELSE synchronously
// flipped one of those notifiers from its own initState()/build() — e.g. a
// demo page preloading an interstitial in initState(), exactly like
// example/'s own BannerDemoPage does. Flutter's BuildOwner refuses ANY
// setState()/markNeedsBuild() anywhere in the tree while ANY widget is
// mid-build, regardless of which element calls it.
//
// Fixed by _DeferredValueListenableBuilder (debug_ad_overlay.dart) — defers
// the rebuild to the next frame instead of reacting synchronously.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAdapter implements AdProviderAdapter {
  @override
  final AdSlot appOpenSlot = AdSlot(type: AdSlotType.appOpen);
  @override
  final AdSlot interstitialSlot = AdSlot(type: AdSlotType.interstitial);
  @override
  final AdSlot rewardedSlot = AdSlot(type: AdSlotType.rewarded);
  @override
  final AdSlot rewardedInterstitialSlot =
      AdSlot(type: AdSlotType.rewardedInterstitial);

  // _MultiSlotRows (rendered alongside _SlotRows) reads these — empty is a
  // valid, real state (no banner/mrec/native instance mounted).
  @override
  Iterable<AdSlot> get bannerSlots => const [];
  @override
  Iterable<AdSlot> get mrecSlots => const [];
  @override
  Iterable<AdSlot> get nativeSlots => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Mirrors the real bug's trigger exactly: a widget that synchronously
/// mutates a slot's ValueNotifier from initState() — the same thing
/// AdManager().loadInterstitial() does (via the adapter's beginLoad()) when
/// called synchronously from a host's own initState(), like
/// example/'s BannerDemoPage.
class _SynchronousPreloader extends StatefulWidget {
  const _SynchronousPreloader({required this.slot});
  final AdSlot slot;

  @override
  State<_SynchronousPreloader> createState() => _SynchronousPreloaderState();
}

class _SynchronousPreloaderState extends State<_SynchronousPreloader> {
  @override
  void initState() {
    super.initState();
    // Synchronous — no await before this — matching a real adapter's
    // beginLoad() call inside loadInterstitial().
    widget.slot.beginLoad();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeAdapter adapter;

  tearDown(() {
    DebugAdOverlay.globallyVisible.value = true;
    AdManager().debugSetAdapter(null);
  });

  testWidgets(
      'expanding the panel then navigating to a page that synchronously '
      'flips interstitialSlot in its own initState() does not crash',
      (tester) async {
    adapter = _FakeAdapter();
    AdManager().debugSetAdapter(adapter);
    final navKey = GlobalKey<NavigatorState>();

    // DebugAdOverlay is a SIBLING of the Navigator, not a descendant of it —
    // mirroring the real integration contract (the overlay wraps the whole
    // app, outside any one page's own Navigator/route subtree). This is
    // load-bearing for reproducing the bug: Flutter's "setState() during
    // build" guard only throws when the dirtied element is NOT a
    // descendant of whatever element is currently building — a preloader
    // mounted INSIDE the same rebuilding subtree as the overlay (e.g. both
    // under one StatefulBuilder) would not trigger it at all.
    await tester.pumpWidget(MaterialApp(
      home: Stack(
        children: [
          Navigator(
            key: navKey,
            onGenerateRoute: (settings) => MaterialPageRoute(
                builder: (_) => const Scaffold(body: Text('home'))),
          ),
          const DebugAdOverlay(),
        ],
      ),
    ));
    await tester.pump();

    // Expand the panel — this is what subscribes _SlotRows to
    // interstitialSlot.state.
    await tester.tap(find.text('🐛 Ad'));
    await tester.pump();
    expect(find.text('🐛 Ad SDK Debug'), findsOneWidget);
    expect(adapter.interstitialSlot.isIdle, isTrue);

    // Push a new route whose initState() synchronously flips the slot —
    // its element mounts as part of the NAVIGATOR's own build pass, with
    // the already-built, already-expanded overlay sitting OUTSIDE that
    // subtree. Before the fix, this threw "setState() or markNeedsBuild()
    // called during build."
    navKey.currentState!.push(MaterialPageRoute(
        builder: (_) =>
            _SynchronousPreloader(slot: adapter.interstitialSlot)));
    await tester.pump();

    expect(adapter.interstitialSlot.isLoading, isTrue,
        reason: 'the synchronous beginLoad() call must have gone through');
    expect(tester.takeException(), isNull,
        reason: 'no FlutterError should have been thrown or reported');
  });
}
