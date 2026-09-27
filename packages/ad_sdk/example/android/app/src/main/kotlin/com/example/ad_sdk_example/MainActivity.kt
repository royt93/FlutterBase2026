package com.example.ad_sdk_example

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugins.googlemobileads.GoogleMobileAdsPlugin

// T228 — the factoryId a host passes to NativeAdWidget(factoryId: ...) in
// Dart must match this string exactly; see lib/main.dart's demo call site.
private const val T228_NATIVE_AD_FACTORY_ID = "t228CustomNativeAd"

class MainActivity : FlutterActivity() {
  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    // T228 — registers the reference NativeAdFactory (T228CustomNativeAdFactory.kt)
    // so NativeAdWidget(factoryId: "t228CustomNativeAd") renders this app's
    // own layout (res/layout/t228_custom_native_ad.xml) instead of Google's
    // built-in template. A real host app copies this pattern with its own
    // factoryId/layout — the SDK itself cannot do this for you (see the T228
    // class doc comment on T228CustomNativeAdFactory).
    GoogleMobileAdsPlugin.registerNativeAdFactory(
        flutterEngine,
        T228_NATIVE_AD_FACTORY_ID,
        T228CustomNativeAdFactory(layoutInflater),
    )
  }

  override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
    GoogleMobileAdsPlugin.unregisterNativeAdFactory(
        flutterEngine, T228_NATIVE_AD_FACTORY_ID)
    super.cleanUpFlutterEngine(flutterEngine)
  }
}
