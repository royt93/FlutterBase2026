T267 on the real Pixel 7 Pro, 2026-11-14 (serial 2B051FDH3006MU, Android 17 / API 37). Exploratory: NOT accepted as T267/T257 acceptance (see "NOT shown").
Run in a copy of the repo under /tmp (repo untouched; the local keystore pointer was removed from the copy).
Command: ./gradlew :macrobenchmark:connectedProfileAndroidTest
         -Pandroid.testInstrumentationRunnerArguments.class=com.example.ad_sdk_macrobenchmark.T257FrameTimingBenchmark#realAdMobScroll   (real AdMob test banner, Profile build)

DEVICE STATE (important): battery 10-12% and CHARGING (AC) the whole time; thermal status 0, battery temperature ~31 C. The user chose to measure at this battery level.
Run history (gradle_run*_summary.txt):
  run 1: my mistake, Gradle rejected an invalid flag (--dart-define) - nothing ran.
  run 2: AndroidX refused to run: "AssertionError: ERRORS (not suppressed): LOW-BATTERY" (it requires >= 25% battery).
  run 3: LOW-BATTERY suppressed with -Pandroid.testInstrumentationRunnerArguments.androidx.benchmark.suppressErrors=LOW-BATTERY (in this temp copy only, at the user's request) ->
         the benchmark ran, banner ready, but FAILED with IllegalStateException: "Observed no renderthread slices in trace - verify that your benchmark is redrawing and is hardware accelerated".

WHAT THE FLUTTER LOG SHOWS (flutter_t257_markers.txt): T257_REAL_AD_READY ready=true; T267_BANNER_AT_SCROLL slot=ready loaded=true error=false; the runner scrolled and logged per-phase summaries.
  Flutter FrameTiming summaries (engine timing, 120Hz device, one iteration):
    real_banner_visible_end (3003 ms): 238 samples, 0 frames > 16.67 ms, 3 > 8.33 ms, p95 total 5.45 ms
    real_scroll_end        (3003 ms): 258 samples, 0 frames > 16.67 ms, 4 > 8.33 ms, p95 total 6.26 ms
    (earlier phases, e.g. banner_load_begin, show 6 frames > 16.67 ms; they include ad loading).
  Note the per-phase sample counts (238-258 in 3 s = ~79-86 samples/s) are below 120/s: FrameTiming reports frames that the engine rendered, it does not prove how many were PRESENTED.

NOT SHOWN / WHY THIS IS NOT ACCEPTANCE:
  - The AndroidX FrameTimingMetric produced NO metric (same "no renderthread slices" failure seen on TECNO and S24U): a Flutter SurfaceView presents through the raster thread, which this metric does not see.
  - No Perfetto trace was saved (0 traces: the run failed before the output was copied), so no FrameTimeline / SurfaceFlinger app-layer data from this run.
  - FrameTiming is engine timing, not presentation/FPS. No 60 fps or jank verdict can be drawn.
  - Battery 10-12% while charging, LOW-BATTERY suppressed: even a successful metric from this run would carry that caveat.
  - One iteration; per-frame T257_FRAME lines (439) stay in the local log only.
