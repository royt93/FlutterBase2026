import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'splash_screen.dart';

/// Entry point — DO NOT initialize AdManager here.
/// AdManager is initialized inside SplashScreen so that
/// the EventBus fires AFTER the listener is registered.
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AdSdkExampleApp());
}

class AdSdkExampleApp extends StatelessWidget {
  const AdSdkExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ad_sdk Example',
      debugShowCheckedModeBanner: kDebugMode,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      // ⚠️ Required: register route observers for RouteAware banner lifecycle
      navigatorObservers: [adRouteObserver, AdScreenRouteLogger()],
      home: const SplashScreen(),
    );
  }
}
