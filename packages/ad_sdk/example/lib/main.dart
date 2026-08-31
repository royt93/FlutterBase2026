// ═══════════════════════════════════════════════════════════════════════════
// applovin_admob_sdk — example app entry point
//
// T117 — this file used to hold all 16 demo pages (~2700 lines); they now
// live one-per-file under demos/, with config/demo_config.dart,
// bootstrap/splash_screen.dart and shared/ (LogBuffer, EventBuffer,
// DemoTile, HomePage) split out alongside. This file keeps only main()
// itself and the navigator key it wires up — see HomePage
// (shared/home_page.dart) for the full list of demos.
//
// Note: provider (AdMob vs AppLovin) is chosen ONCE at app startup via
// `AdConfig.provider` and is **not** swappable at runtime. Default is
// AppLovin; pass --dart-define=AD_PROVIDER_ADMOB=true to build/test the
// AdMob path instead (see kProvider in config/demo_config.dart).
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'bootstrap/splash_screen.dart';
import 'shared/event_buffer.dart';

// T117 — barrel exports so `package:ad_sdk_example/main.dart` (the app's
// existing import point — used by example/test/*.dart and
// example/integration_test/*.dart) still resolves every demo/shared symbol
// after the split, with zero changes needed in either test suite.
export 'config/demo_config.dart';
export 'shared/demo_tile.dart';
export 'shared/event_buffer.dart';
export 'shared/home_page.dart';
export 'shared/layout_helpers.dart';
export 'shared/log_buffer.dart';
export 'bootstrap/splash_screen.dart';
export 'demos/app_open_demo_page.dart';
export 'demos/banner_demo_page.dart';
export 'demos/compliance_demo_page.dart';
export 'demos/consent_demo_page.dart';
export 'demos/diagnostics_demo_page.dart';
export 'demos/events_demo_page.dart';
export 'demos/interstitial_demo_page.dart';
export 'demos/log_viewer_demo_page.dart';
export 'demos/mrec_demo_page.dart';
export 'demos/native_demo_page.dart';
export 'demos/revenue_demo_page.dart';
export 'demos/rewarded_demo_page.dart';
export 'demos/safety_demo_page.dart';
export 'demos/state_panel_demo_page.dart';
export 'demos/test_device_hash_demo_page.dart';
export 'demos/vip_demo_page.dart';

final _navigatorKey = GlobalKey<NavigatorState>();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Edge-to-edge: status bar + nav bar transparent, content paints behind them.
  // Required on Android 15+ (target SDK 35) and recommended on older versions.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  // ⚠️ Required: register navigator key BEFORE runApp so the SDK can show
  // loading dialogs from lifecycle observer (App Open on resume).
  AdManager().setNavigatorKey(_navigatorKey);
  // Round-27 backlog B5 — destroy() closes AdManager().events and opens a
  // FRESH stream on the next initialize() (T31). A subscription taken out
  // once here, at startup, receives `done` on that first destroy() and
  // never follows the new stream — the "Slot state panel" demo's own
  // Destroy/Re-initialize buttons silently killed the Event stream/Revenue
  // dashboard pages for the rest of the run. Rebind on every initRevision
  // change (already the SDK's own signal for "adapter/session identity
  // changed", used elsewhere in this file) instead of subscribing once.
  StreamSubscription<AdEvent>? eventBufferSub;
  void rebindEventBuffer() {
    eventBufferSub?.cancel();
    eventBufferSub = AdManager().events.listen(EventBuffer.instance.onEvent);
  }

  rebindEventBuffer();
  AdManager().initRevision.addListener(rebindEventBuffer);
  runApp(MaterialApp(
    title: 'ad_sdk demo',
    debugShowCheckedModeBanner: kDebugMode,
    navigatorKey: _navigatorKey,
    // ⚠️ Required: register route observers for RouteAware banner lifecycle.
    navigatorObservers: [adRouteObserver, AdScreenRouteLogger()],
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      useMaterial3: true,
    ),
    // DebugAdOverlay floats over every screen (kDebugMode only). Wrapping
    // here instead of inside HomePage means the overlay stays visible while
    // the user navigates into any demo page.
    builder: (context, child) {
      if (child == null) return const SizedBox.shrink();
      return Stack(
        children: [
          child,
          const DebugAdOverlay(),
        ],
      );
    },
    home: const SplashScreen(),
  ));
}
