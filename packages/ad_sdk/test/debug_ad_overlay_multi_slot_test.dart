// T173 — the debug overlay's slot panel previously had no row at all for
// banner/MREC/native (see debug_ad_overlay.dart's _SlotRows/_MultiSlotRows
// history): those three are keyed per widget instance (T65), so unlike
// AppOpen/Inter/Rewarded (one AdSlot each) there was nothing here to look at
// when one of them never shows. This covers the new `_MultiSlotRows`
// aggregate rows across several instances in different states.

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

  final Map<Object, AdSlot> _bannerSlots = {};
  final Map<Object, AdSlot> _mrecSlots = {};
  final Map<Object, AdSlot> _nativeSlots = {};

  @override
  AdSlot bannerSlot(Object key) =>
      _bannerSlots.putIfAbsent(key, () => AdSlot(type: AdSlotType.banner));
  @override
  Iterable<AdSlot> get bannerSlots => _bannerSlots.values;

  @override
  AdSlot mrecSlot(Object key) =>
      _mrecSlots.putIfAbsent(key, () => AdSlot(type: AdSlotType.mrec));
  @override
  Iterable<AdSlot> get mrecSlots => _mrecSlots.values;

  @override
  AdSlot nativeSlot(Object key) =>
      _nativeSlots.putIfAbsent(key, () => AdSlot(type: AdSlotType.native));
  @override
  Iterable<AdSlot> get nativeSlots => _nativeSlots.values;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeAdapter adapter;

  Widget harness() {
    return MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            const Text('host content'),
            const DebugAdOverlay(),
          ],
        ),
      ),
    );
  }

  setUp(() {
    adapter = _FakeAdapter();
    AdManager().debugSetAdapter(adapter);
  });

  tearDown(() {
    DebugAdOverlay.globallyVisible.value = true;
    AdManager().debugSetAdapter(null);
  });

  testWidgets(
      'no banner/mrec/native instances mounted yet shows (0) for all three',
      (tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();
    await tester.tap(find.text('🐛 Ad'));
    await tester.pump();

    expect(find.textContaining('Banner'), findsOneWidget);
    expect(find.textContaining('Mrec'), findsOneWidget);
    expect(find.textContaining('Native'), findsOneWidget);
    expect(find.textContaining('Banner   (0)'), findsOneWidget);
    expect(find.textContaining('Mrec     (0)'), findsOneWidget);
    expect(find.textContaining('Native   (0)'), findsOneWidget);
  });

  testWidgets(
      'several banner instances in different states are summarized by '
      'count-by-state, not listed one row each', (tester) async {
    adapter.bannerSlot('a')
      ..beginLoad()
      ..markReady();
    adapter.bannerSlot('b').beginLoad();
    adapter.bannerSlot('c'); // stays idle

    await tester.pumpWidget(harness());
    await tester.pump();
    await tester.tap(find.text('🐛 Ad'));
    await tester.pump();

    expect(find.textContaining('Banner   (3)'), findsOneWidget);
    // Exact formatting (Map iteration order for a 3-entry <AdSlotState,int>
    // map is stable within one run but not a documented contract) — assert
    // on substrings for each state's count instead of the whole line.
    final bannerLine = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .firstWhere((s) => s.startsWith('Banner'));
    expect(bannerLine, contains('ready=1'));
    expect(bannerLine, contains('loading=1'));
    expect(bannerLine, contains('idle=1'));
  });

  testWidgets(
      'consecutive failures are summed across every instance of a type',
      (tester) async {
    adapter.mrecSlot('a')
      ..beginLoad()
      ..markFailed()
      ..beginLoad()
      ..markFailed();
    adapter.mrecSlot('b')
      ..beginLoad()
      ..markFailed();

    await tester.pumpWidget(harness());
    await tester.pump();
    await tester.tap(find.text('🐛 Ad'));
    await tester.pump();

    final mrecLine = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .firstWhere((s) => s.startsWith('Mrec'));
    expect(mrecLine, contains('(2)'));
    expect(mrecLine, contains('fails=3'),
        reason: '2 fails on instance a + 1 fail on instance b');
  });

  testWidgets(
      'a new native instance mounted after the panel is already open is '
      'picked up by the next poll tick, not stuck showing the old count',
      (tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();
    await tester.tap(find.text('🐛 Ad'));
    await tester.pump();
    expect(find.textContaining('Native   (0)'), findsOneWidget);

    adapter.nativeSlot('a').beginLoad();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.textContaining('Native   (1)'), findsOneWidget);
  });
}
