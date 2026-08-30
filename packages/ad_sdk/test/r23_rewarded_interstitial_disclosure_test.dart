// Round-23 QC (reviewer B, BLOCKER) — the rewarded interstitial must announce
// itself before it plays.
//
// Google's policy for this format requires an intro screen: the user is told an
// ad is coming and what the reward is, and is given a way out. The SDK shipped
// `AdManager().showRewardedInterstitialAd()` with nothing of the sort and the
// README did not mention the obligation, so a host that adopted the format was
// out of policy by default — and it is the host's AdMob account that gets
// actioned, not the SDK's.
//
// `AdScreenState.showRewardedInterstitialAd()` now renders the screen by
// default. Declining it must cost nothing: no ad, no impression, no budget.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ReadyAdapter implements AdProviderAdapter {
  @override
  final AdSlot appOpenSlot = AdSlot(type: AdSlotType.appOpen);
  @override
  final AdSlot interstitialSlot = AdSlot(type: AdSlotType.interstitial);
  @override
  final AdSlot rewardedSlot = AdSlot(type: AdSlotType.rewarded);
  @override
  final AdSlot rewardedInterstitialSlot =
      AdSlot(type: AdSlotType.rewardedInterstitial);
  final AdSlot _bannerSlot = AdSlot(type: AdSlotType.banner);
  @override
  AdSlot bannerSlot(Object key) => _bannerSlot;
  @override
  Iterable<AdSlot> get bannerSlots => [_bannerSlot];

  int showCalls = 0;

  @override
  String get tag => 'ready';

  @override
  bool get isInitialised => true;

  final BannerListenables _banner = BannerListenables(
    isLoaded: ValueNotifier<bool>(false),
    hasError: ValueNotifier<bool>(false),
    adSize: ValueNotifier<Size?>(null),
    autoRefreshEnabled: ValueNotifier<bool>(true),
    visible: ValueNotifier<bool>(true),
  );
  @override
  BannerListenables banner(Object key) => _banner;

  bool _bannerRoutePaused = false;
  @override
  bool bannerRoutePaused(Object key) => _bannerRoutePaused;
  @override
  void setBannerRoutePaused(Object key, bool paused) =>
      _bannerRoutePaused = paused;
  @override
  void disposeBannerInstance(Object key) {}

  @override
  Future<void> loadInterstitial() async {}
  @override
  Future<void> loadRewarded() async {}

  @override
  Future<void> loadRewardedInterstitial() async {}

  @override
  Future<void> showRewardedInterstitial({
    required void Function(RewardResult result) onDone,
  }) async {
    showCalls++;
    onDone(const RewardResult(
        earned: true, shown: true, label: 'coins', amount: 1));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DemoScreen extends AdScreen {
  const _DemoScreen({required this.onDone, this.showDisclosure = true});
  final void Function(bool shown, bool earned) onDone;
  final bool showDisclosure;

  @override
  State<_DemoScreen> createState() => _DemoScreenState();
}

class _DemoScreenState extends AdScreenState<_DemoScreen> {
  @override
  Widget build(BuildContext context) => Scaffold(
        body: ElevatedButton(
          key: const Key('ri'),
          onPressed: () => showRewardedInterstitialAd(
            onDone: widget.onDone,
            showDisclosure: widget.showDisclosure,
            disclosureTitle: 'Xem quảng cáo để nhận thưởng',
            disclosureSubtitle: 'Một quảng cáo ngắn sẽ phát.',
            disclosureButtonLabel: 'Xem',
            disclosureCancelLabel: 'Bỏ qua',
          ),
          child: const Text('ri'),
        ),
      );
}

/// Passes NO `showDisclosure` argument at all — the shape a host that has never
/// heard of the parameter writes, which is the only shape the policy fix is
/// actually for.
class _DefaultScreen extends AdScreen {
  const _DefaultScreen({required this.onDone});
  final void Function(bool shown, bool earned) onDone;

  @override
  State<_DefaultScreen> createState() => _DefaultScreenState();
}

class _DefaultScreenState extends AdScreenState<_DefaultScreen> {
  @override
  Widget build(BuildContext context) => Scaffold(
        body: ElevatedButton(
          key: const Key('ri'),
          onPressed: () => showRewardedInterstitialAd(onDone: widget.onDone),
          child: const Text('ri'),
        ),
      );
}

void main() {
  late _ReadyAdapter adapter;

  setUp(() async {
    AdPreferences.resetForTest();
    SharedPreferences.setMockInitialValues({});
    final prefs = await AdPreferences.getInstance();
    await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
    AdSafetyConfig.resetForReinit();
    adapter = _ReadyAdapter();
    adapter.rewardedInterstitialSlot.beginReload();
    adapter.rewardedInterstitialSlot.markReady();
    AdManager().debugSetAdapter(adapter);
  });

  tearDown(() {
    AdManager().debugSetAdapter(null);
    AdManager().debugVipManager = null;
  });

  Widget host(Widget child) => MaterialApp(
        navigatorObservers: [adRouteObserver],
        home: child,
      );

  testWidgets(
      'CONTROL — a host rendering its own intro screen can opt out',
      (tester) async {
    bool? shown;
    await tester.pumpWidget(host(
        _DemoScreen(onDone: (s, __) => shown = s, showDisclosure: false)));

    await tester.tap(find.byKey(const Key('ri')));
    await tester.pumpAndSettle();

    expect(find.text('Xem quảng cáo để nhận thưởng'), findsNothing);
    expect(adapter.showCalls, 1);
    expect(shown, isTrue,
        reason: 'the default must be safe, not mandatory — a host with its own '
            'localised, branded intro screen would otherwise show two');
  });

  testWidgets('CONTROL — no ad ready shows a toast, never an intro screen',
      (tester) async {
    AdManager().debugSetAdapter(null);
    bool? shown;
    await tester.pumpWidget(host(_DemoScreen(onDone: (s, __) => shown = s)));

    await tester.tap(find.byKey(const Key('ri')));
    await tester.pump();

    expect(find.text('Xem quảng cáo để nhận thưởng'), findsNothing,
        reason: 'announcing an ad that cannot play is worse than announcing '
            'nothing');
    expect(shown, isFalse);
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });
  testWidgets('the intro screen appears before the ad, not after',
      (tester) async {
    await tester.pumpWidget(host(_DemoScreen(onDone: (_, __) {})));
    await tester.tap(find.byKey(const Key('ri')));
    await tester.pump();

    expect(find.text('Xem quảng cáo để nhận thưởng'), findsOneWidget);
    expect(find.text('Bỏ qua'), findsOneWidget);
    expect(adapter.showCalls, 0,
        reason: 'an announcement shown after the ad announces nothing');
  });

  testWidgets('declining costs no ad and no impression budget', (tester) async {
    bool? shown;
    bool? earned;
    await tester.pumpWidget(host(_DemoScreen(onDone: (s, e) {
      shown = s;
      earned = e;
    })));
    final before = AdSafetyConfig.getSessionAdCount();

    await tester.tap(find.byKey(const Key('ri')));
    await tester.pump();
    await tester.tap(find.text('Bỏ qua'));
    await tester.pumpAndSettle();

    expect(adapter.showCalls, 0);
    expect(shown, isFalse);
    expect(earned, isFalse);
    expect(AdSafetyConfig.getSessionAdCount(), before,
        reason: 'the way out has to actually be a way out');
  });

  // Round-24 QC (reviewer B, MINOR) — the DEFAULT is the fix. Every other test
  // in this file passes `showDisclosure:` explicitly, so flipping the default
  // from `true` to `false` left the whole suite green: the mechanism was
  // covered, the policy promise was not. A host that never heard of the
  // parameter is exactly the host this exists to protect.
  testWidgets('the disclosure is on by DEFAULT, with no parameter passed',
      (tester) async {
    bool? shown;
    await tester.pumpWidget(host(_DefaultScreen(onDone: (s, __) => shown = s)));

    await tester.tap(find.byKey(const Key('ri')));
    await tester.pump();

    expect(find.text('Watch an ad for your reward'), findsOneWidget,
        reason: 'the SDK\'s own default copy must appear — the host wrote '
            'nothing');
    expect(adapter.showCalls, 0,
        reason: 'THE policy requirement — the ad waits behind the intro '
            'screen, and it is the host\'s AdMob account that gets actioned '
            'if it does not');
    expect(shown, isNull, reason: 'nothing has been decided yet');
  });

  testWidgets('accepting plays the ad and reports the reward', (tester) async {
    bool? shown;
    bool? earned;
    await tester.pumpWidget(host(_DemoScreen(onDone: (s, e) {
      shown = s;
      earned = e;
    })));

    await tester.tap(find.byKey(const Key('ri')));
    await tester.pump();
    await tester.tap(find.text('Xem'));
    await tester.pumpAndSettle();

    expect(adapter.showCalls, 1);
    expect(shown, isTrue);
    expect(earned, isTrue);
  });
}
