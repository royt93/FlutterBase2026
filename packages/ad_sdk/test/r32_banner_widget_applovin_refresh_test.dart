// Round-32 QC (reviewer B, BLOCKER) — the widget layer must not write
// `autoRefreshEnabled` directly. `BannerAdWidget`/`MrecAdWidget` used to do so
// in `didPush`/`didPushNext`/`didPopNext`, outside `InlineVisibilityOwners`
// entirely — and the widget always won, because it wrote last.
//
// `RouteObserver.subscribe()` calls `didPush()` unconditionally on every
// mount. So on a real cold start where a launch App Open is up
// (`setInlineAdsHidden(true)`, `_fullscreenOverInline = true`) and the home
// route keeps building underneath it, a `BannerAdWidget` that mounts in that
// window correctly inherited the `fullscreen` hold (round 30) — and then
// `didPush`'s post-frame callback wrote `autoRefreshEnabled = true` right back
// over it. A MAX banner auto-refreshed underneath the fullscreen ad, which is
// the exact policy exposure fix 6 exists to close. It survived because every
// `r23_appopen_over_banner_test.dart` case calls the adapter directly and none
// goes through the widget.
//
// This file drives the REAL `AppLovinAdapter` through the REAL `BannerAdWidget`
// and a REAL `RouteObserver`, because the bug lives entirely in which of two
// writers goes last — something a test calling the adapter directly cannot see.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/adapters/applovin_adapter.dart';
import 'package:applovin_admob_sdk/src/adapters/applovin_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _NoopBridge implements AppLovinBridge {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _appLovinConfig = AdConfig(
  provider: AdProvider.appLovin,
  appLovin: AppLovinConfig(
    sdkKey: 'key',
    bannerId: 'b',
    interstitialId: 'i',
    appOpenId: 'ao',
    rewardedId: 'r',
  ),
);

void main() {
  Widget host(Widget child) => MaterialApp(
        navigatorObservers: [adRouteObserver],
        home: Scaffold(body: Center(child: child)),
      );

  late AppLovinAdapter adapter;

  setUp(() {
    adapter = AppLovinAdapter(bridge: _NoopBridge());
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _appLovinConfig;
  });

  tearDown(() {
    AdManager().debugSetAdapter(null);
    AdManager().debugConfig = null;
  });

  testWidgets(
      'a banner mounting under a live App Open stays non-refreshing after '
      'didPush', (tester) async {
    // The launch App Open is up before the banner ever mounts — the ownership
    // hold this banner must inherit.
    adapter.setInlineAdsHidden(true);

    await tester.pumpWidget(host(const BannerAdWidget()));
    // Not pumpAndSettle: the loading placeholder animates forever.
    await tester.pump(const Duration(milliseconds: 50));

    // The adapter keys its listenables by the widget's STATE object (`this`
    // inside `didPush`), not the widget itself — `tester.state` is the seam
    // that gets us the same key without naming the private State class.
    final held = adapter.banner(tester.state(find.byType(BannerAdWidget)));
    expect(held.autoRefreshEnabled.value, isFalse,
        reason: 'THE finding — a direct write in didPush overwrote the '
            'fullscreen hold a launch App Open had already taken, one frame '
            'after every single mount');

    adapter.setInlineAdsHidden(false);
    expect(held.autoRefreshEnabled.value, isTrue);
  });

  testWidgets(
      'a route pushed on top and popped does not leave refresh stuck off',
      (tester) async {
    await tester.pumpWidget(host(const BannerAdWidget()));
    await tester.pump(const Duration(milliseconds: 50));

    final held = adapter.banner(tester.state(find.byType(BannerAdWidget)));
    expect(held.autoRefreshEnabled.value, isTrue, reason: 'sanity');

    Navigator.of(tester.element(find.byType(BannerAdWidget))).push(
      MaterialPageRoute<void>(builder: (_) => const SizedBox()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(held.autoRefreshEnabled.value, isFalse,
        reason: 'covered by another route');

    Navigator.of(tester.element(find.byType(BannerAdWidget))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(held.autoRefreshEnabled.value, isTrue,
        reason: 'the push→pop cycle must release the route hold, entirely '
            'through setBannerRoutePaused — no direct write needed');
  });
}
