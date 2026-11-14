package com.example.ad_sdk_example

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import java.lang.reflect.InvocationHandler
import java.lang.reflect.Proxy
import java.util.concurrent.Executor
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

private const val JANK_TAG = "T267_JANK"

private fun findSurfaceViews(root: View, out: MutableList<SurfaceView>) {
  if (root is SurfaceView) out.add(root)
  if (root is ViewGroup) for (i in 0 until root.childCount) findSurfaceViews(root.getChildAt(i), out)
}

class MainActivity : FlutterActivity() {
  // T267 experiment (temp copy only): SurfaceView.registerOnJankDataListener is public on API 37.x;
  // it is called by reflection so compileSdk and the Android Gradle Plugin stay unchanged.
  private var jankRegistration: Any? = null
  private var jankBatches = 0
  private var jankFrames = 0
  private var jankPresentKnown = 0
  private val jankTypeSeen = HashMap<Int, Int>()

  override fun onResume() {
    super.onResume()
    Handler(Looper.getMainLooper()).postDelayed({ attachJankListener() }, 1500)
    val h = Handler(Looper.getMainLooper())
    h.postDelayed(object : Runnable {
      override fun run() {
        jankRegistration?.let { try { it.javaClass.getMethod("flush").invoke(it) } catch (_: Throwable) {} }
        Log.i(JANK_TAG, "tick batches=" + jankBatches + " frames=" + jankFrames)
        if (!isFinishing) h.postDelayed(this, 1000)
      }
    }, 3000)
  }

  private fun attachJankListener() {
    if (jankRegistration != null) return
    val views = ArrayList<SurfaceView>()
    findSurfaceViews(window.decorView, views)
    Log.i(JANK_TAG, "SurfaceViews found=" + views.size + " " + views.joinToString { it.javaClass.name + "[" + it.width + "x" + it.height + "]" })
    // The Pixel (Android 17, API 37) does NOT define SurfaceView.registerOnJankDataListener; it is public on
    // AttachedSurfaceControl (View.getRootSurfaceControl()), i.e. per WINDOW root, not per SurfaceView.
    val root = window.decorView.rootSurfaceControl
    Log.i(JANK_TAG, "rootSurfaceControl=" + root?.javaClass?.name + " sdk=" + android.os.Build.VERSION.SDK_INT)
    if (root == null) { Log.i(JANK_TAG, "NO_ROOT_SURFACE_CONTROL"); return }
    try {
      val listenerCls = Class.forName("android.view.SurfaceControl\$OnJankDataListener")
      val jankCls = Class.forName("android.view.SurfaceControl\$JankData")
      val register = Class.forName("android.view.AttachedSurfaceControl")
        .getMethod("registerOnJankDataListener", Executor::class.java, listenerCls)
      fun m(n: String) = try { jankCls.getMethod(n) } catch (_: Throwable) { null }
      val getType = m("getJankType"); val getVsync = m("getVsyncId"); val getApp = m("getActualAppFrameTimeNanos")
      val getSched = m("getScheduledAppFrameTimeNanos"); val getDelta = m("getActualPresentDeltaNanos")
      val getDelay = m("getPresentDelayNanos"); val getInterval = m("getFrameIntervalNanos"); val getScore = m("getJankScore")
      val getPresent = m("getPresentTimeNanos")
      Log.i(JANK_TAG, "JankData getters: type=" + (getType != null) + " vsync=" + (getVsync != null) + " app=" + (getApp != null) +
          " delta=" + (getDelta != null) + " delay=" + (getDelay != null) + " interval=" + (getInterval != null) +
          " score=" + (getScore != null) + " presentTime=" + (getPresent != null))
      val handler = InvocationHandler { proxy, method, args ->
        when (method.name) {
          "onJankDataAvailable" -> {
            val list = args!![0] as List<*>
            jankBatches++
            for (d in list) {
              jankFrames++
              val t = (getType?.invoke(d) as? Int) ?: -1
              jankTypeSeen[t] = (jankTypeSeen[t] ?: 0) + 1
              if (getDelta != null && (getDelta.invoke(d) as Long) > 0) jankPresentKnown++
            }
            if (jankBatches <= 5 || jankBatches % 20 == 0) {
              val f = list.firstOrNull()
              if (f != null) Log.i(JANK_TAG, "batch=" + jankBatches + " size=" + list.size + " totalFrames=" + jankFrames +
                  " deltaPositive=" + jankPresentKnown + " first{vsync=" + getVsync?.invoke(f) + " type=" + getType?.invoke(f) +
                  " appFrameNs=" + getApp?.invoke(f) + " schedNs=" + getSched?.invoke(f) + " presentDeltaNs=" + getDelta?.invoke(f) +
                  " presentDelayNs=" + getDelay?.invoke(f) + " intervalNs=" + getInterval?.invoke(f) + " score=" + getScore?.invoke(f) + "}")
            }
            null
          }
          "toString" -> "T267JankProxy"
          "hashCode" -> 17
          "equals" -> proxy === args!![0]
          else -> null
        }
      }
      val proxy = Proxy.newProxyInstance(listenerCls.classLoader, arrayOf(listenerCls), handler)
      jankRegistration = register.invoke(root, mainExecutor, proxy)
      Log.i(JANK_TAG, "registered OK registration=" + (jankRegistration != null))
    } catch (e: Throwable) {
      Log.e(JANK_TAG, "register FAILED " + e.javaClass.name + ": " + (e.cause?.toString() ?: e.message))
    }
  }

  override fun onPause() {
    Log.i(JANK_TAG, "SUMMARY batches=" + jankBatches + " frames=" + jankFrames + " presentTimeKnown=" + jankPresentKnown + " jankTypeCounts=" + jankTypeSeen)
    jankRegistration?.let { try { it.javaClass.getMethod("flush").invoke(it); Log.i(JANK_TAG, "flush() called in onPause") } catch (e: Throwable) { Log.e(JANK_TAG, "flush failed " + e) } }
    super.onPause()
  }

  // ---- original MainActivity body continues below ----
  // (class body originally started here)
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
