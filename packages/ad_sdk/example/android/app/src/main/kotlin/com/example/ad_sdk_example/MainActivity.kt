package com.example.ad_sdk_example

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.googlemobileads.GoogleMobileAdsPlugin

// T228 — the factoryId a host passes to NativeAdWidget(factoryId: ...) in
// Dart must match this string exactly; see lib/main.dart's demo call site.
private const val T228_NATIVE_AD_FACTORY_ID = "t228CustomNativeAd"
private const val T257_BENCHMARK_CHANNEL = "com.example.ad_sdk_example/t257_benchmark"
private const val T257_START_ACTION = "com.example.ad_sdk_example.T257_START"

class MainActivity : FlutterActivity() {
  private val isT257Benchmark get() = intent.getBooleanExtra("t257Macrobenchmark", false)
  private var t257BenchmarkChannel: MethodChannel? = null
  private var t257StartReceiver: BroadcastReceiver? = null

  override fun getInitialRoute(): String? =
      if (isT257Benchmark) {
        val scenario = intent.getStringExtra("t257Scenario") ?: "deterministic"
        "/$scenario${if (intent.getBooleanExtra("t257AutoStart", false)) "-auto" else ""}"
      } else {
        super.getInitialRoute()
      }

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    t257BenchmarkChannel = MethodChannel(
        flutterEngine.dartExecutor.binaryMessenger, T257_BENCHMARK_CHANNEL)
    if (isT257Benchmark) {
      t257StartReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
          t257BenchmarkChannel?.invokeMethod("start", null)
        }
      }
      ContextCompat.registerReceiver(
          this,
          t257StartReceiver,
          IntentFilter(T257_START_ACTION),
          ContextCompat.RECEIVER_EXPORTED,
      )
    }
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
    t257StartReceiver?.let { unregisterReceiver(it) }
    t257StartReceiver = null
    GoogleMobileAdsPlugin.unregisterNativeAdFactory(
        flutterEngine, T228_NATIVE_AD_FACTORY_ID)
    super.cleanUpFlutterEngine(flutterEngine)
  }
}
