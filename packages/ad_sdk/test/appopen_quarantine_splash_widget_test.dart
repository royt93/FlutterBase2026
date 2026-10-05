// Audit round 74 — widget-level contract for a splash that follows the
// documented integration: `showAppOpenAd(bypassSafety: true, onAdDismiss: →
// navigate)`. When AppLovinAdapter refuses the show because of the stale-
// callback quarantine, the splash must still reach the next screen (it must
// not wait on an ad that never started) and must not navigate twice.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/adapters/applovin_adapter.dart';
import 'package:applovin_admob_sdk/src/adapters/applovin_bridge.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_max/applovin_max.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RecordingBridge implements AppLovinBridge {
  final shows = <String>[];
  AppOpenAdListener? appOpen;

  @override
  Future<void> initialize(String sdkKey) async {}
  @override
  void showAppOpenAd(String adUnitId) => shows.add(adUnitId);
  @override
  void loadAppOpenAd(String adUnitId) {}
  @override
  void setAppOpenAdListener(AppOpenAdListener? l) => appOpen = l;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeVip implements VipManager {
  @override
  bool get isActive => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _config = AdConfig(
  provider: AdProvider.appLovin,
  appLovin: AppLovinConfig(
    sdkKey: 'sdk',
    bannerId: 'banner-id',
    interstitialId: 'inter-id',
    appOpenId: 'appopen-id',
    rewardedId: 'rewarded-id',
  ),
);

/// Minimal splash following the README contract: dismiss → navigate home.
class _Splash extends StatefulWidget {
  const _Splash({required this.onNavigate});
  final VoidCallback onNavigate;

  @override
  State<_Splash> createState() => _SplashState();
}

class _SplashState extends State<_Splash> {
  var _navigated = false;

  void _goHome() {
    if (_navigated) return;
    _navigated = true;
    widget.onNavigate();
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
          builder: (_) => const Scaffold(body: Center(child: Text('home')))),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AdManager().showAppOpenAd(
        bypassSafety: true,
        onAdDismiss: (_) => _goHome(),
      );
    });
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text('splash')));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await AdManager().destroy();
    SharedPreferences.setMockInitialValues({});
    final prefs = await AdPreferences.getInstance();
    await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
    AdSafetyConfig.resetForReinit();
    AdManager().debugVipManager = _FakeVip();
    AdManager().debugCanRequestAds = true;
    AdManager().markSplashInactive();
  });

  tearDown(() async {
    AdManager().debugSetAdapter(null);
    AdManager().debugVipManager = null;
    AdManager().markSplashActive();
    await AdManager().destroy();
  });

  testWidgets('a quarantined App Open does not strand the splash',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final bridge = _RecordingBridge();
    final adapter = AppLovinAdapter(
      bridge: bridge,
      lifecycleStateResolver: () => AppLifecycleState.resumed,
    );

    // Real watchdog, run inside runAsync so the awaited init + wall-clock
    // timers actually progress; the widget tester's fake clock does not.
    await tester.runAsync(() async {
      await adapter.initialize(_config);
      adapter.debugStartAppOpenWatchdog((_) {});
      await Future<void>.delayed(const Duration(seconds: 11));
    });
    // Flutter asserts this is unset at the end of the test body, before any
    // tearDown runs; the watchdog has already finished by now.
    debugDefaultTargetPlatformOverride = null;
    adapter.appOpenSlot.markReady();
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _config;

    var navigations = 0;
    await tester.pumpWidget(MaterialApp(
      home: _Splash(onNavigate: () => navigations++),
    ));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pumpAndSettle();

    expect(find.text('home'), findsOneWidget,
        reason: 'refused show must resolve false so the splash reaches the '
            'next screen, not stall on an ad that never started');
    expect(find.text('splash'), findsNothing);
    expect(navigations, 1, reason: 'exactly once — no double navigate');
    expect(bridge.shows, isEmpty,
        reason: 'quarantine refused before the native SDK was reached');
  });

  for (final late in ['loaded', 'loadFailed']) {
    testWidgets('a late $late load result mid-show does not strand the splash',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final bridge = _RecordingBridge();
      final adapter = AppLovinAdapter(
        bridge: bridge,
        lifecycleStateResolver: () => AppLifecycleState.resumed,
      );
      try {
        await tester.runAsync(() => adapter.initialize(_config));
        await adapter.loadAppOpen();
        MaxAd ad(String id) => MaxAd('unit', 'APPOPEN', null, 'net', '', 0.0,
            'exact', id, 'dsp', '', 0, MaxAdWaterfallInfo('', '', const [], 0),
            null, null);
        bridge.appOpen!.onAdLoadedCallback(ad('current'));
        AdManager().debugSetAdapter(adapter);
        AdManager().debugConfig = _config;

        var navigations = 0;
        await tester.pumpWidget(MaterialApp(
          home: _Splash(onNavigate: () => navigations++),
        ));
        expect(bridge.shows, ['appopen-id']);
        await tester.pump(const Duration(seconds: 4));
        if (late == 'loaded') {
          bridge.appOpen!.onAdLoadedCallback(ad('late-load'));
        } else {
          bridge.appOpen!.onAdLoadFailedCallback(
              'a', MaxError(ErrorCode.values.first, 'fail', null, null));
        }
        await tester.pump();
        expect(adapter.appOpenSlot.isShowing, isTrue);
        expect(navigations, 0);

        // The current cycle's own hidden callback is lost: only the watchdog
        // can release the splash.
        await tester.pump(const Duration(seconds: 6));
        await tester.pumpAndSettle();
        expect(find.text('home'), findsOneWidget);
        expect(navigations, 1);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        AdManager().debugSetAdapter(null);
        await adapter.dispose();
      }
    });
  }

  for (final kind in ['hidden', 'displayFailed']) {
    testWidgets('stale $kind leaves the splash watchdog alive', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final bridge = _RecordingBridge();
      final adapter = AppLovinAdapter(
        bridge: bridge,
        lifecycleStateResolver: () => AppLifecycleState.resumed,
      );
      try {
        await tester.runAsync(() => adapter.initialize(_config));
        await adapter.loadAppOpen();
        bridge.appOpen!.onAdLoadedCallback(MaxAd(
            'unit', 'APPOPEN', null, 'net', '', 0.0, 'exact', 'current',
            'dsp', '', 0, MaxAdWaterfallInfo('', '', const [], 0), null, null));
        AdManager().debugSetAdapter(adapter);
        AdManager().debugConfig = _config;

        var navigations = 0;
        await tester.pumpWidget(MaterialApp(
          home: _Splash(onNavigate: () => navigations++),
        ));
        expect(bridge.shows, ['appopen-id']);
        await tester.pump(const Duration(seconds: 4));
        final stale = MaxAd(
            'unit', 'APPOPEN', null, 'net', '', 0.0, 'exact', 'old',
            'dsp', '', 0, MaxAdWaterfallInfo('', '', const [], 0), null, null);
        if (kind == 'hidden') {
          bridge.appOpen!.onAdHiddenCallback(stale);
        } else {
          bridge.appOpen!.onAdDisplayFailedCallback(
              stale, MaxError(ErrorCode.values.first, 'fail', null, null));
        }
        await tester.pump();
        expect(find.text('splash'), findsOneWidget);
        expect(navigations, 0);
        await tester.pump(const Duration(seconds: 1));
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
        expect(find.text('home'), findsOneWidget);
        expect(find.text('splash'), findsNothing);
        expect(navigations, 1);
        bridge.appOpen!.onAdHiddenCallback(stale);
        await tester.pumpAndSettle();
        expect(navigations, 1);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        AdManager().debugSetAdapter(null);
        await adapter.dispose();
      }
    });
  }
}
