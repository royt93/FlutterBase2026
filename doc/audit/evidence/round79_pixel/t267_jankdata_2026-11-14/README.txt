T267 JankData listener experiment on the real Pixel 7 Pro, 2026-11-14 (Android 17 / API 37, google/cheetah/cheetah:17/CP3A.261005.002.A1/16269273).
EXPLORATORY ONLY. Done in a throw-away copy of the repo under /tmp; the repo is unchanged. The experiment MainActivity is kept here as MainActivity_experiment_copy.kt (NOT part of the repo).
Battery was 10-14% and charging; benchmark scroll triggered by the existing broadcast, no Macrobenchmark runner involved.

QUESTION: can a per-surface present/jank signal for Flutter's SurfaceView be obtained from public Android API on this Pixel?

FINDINGS (jankdata_and_markers.txt, device_framework_api.txt, hiddenapi_messages.txt):
 1) Flutter uses a real FlutterSurfaceView on this Pixel: "SurfaceViews found=1 io.flutter.embedding.android.FlutterSurfaceView[1440x3120]".
 2) The API the android-37.2 STUB jar documents - SurfaceView.registerOnJankDataListener(...) and JankData.getPresentTimeNanos()/getDesiredPresentTimeNanos() - does NOT exist on THIS device:
    dexdump of the device's /system/framework/framework.jar shows SurfaceView declares no such method, and JankData has no getPresentTimeNanos/getDesiredPresentTimeNanos. First attempt
    (reflection on SurfaceView) failed with NoSuchMethodException. The listener exists on AttachedSurfaceControl (window level), marked hiddenapi flags SDK,TEST-API.
 3) Registering on the window's AttachedSurfaceControl worked ("registered OK") and JankData getters type/vsyncId/actualAppFrameTime exist; getActualPresentDeltaNanos, getPresentDelayNanos, getFrameIntervalNanos
    and getJankScore exist in the framework but reflection reported them unavailable to the app (hidden-API blocked), so no present-time value could be read.
 4) DELIVERY: during the whole run only ONE batch of 3 frames was delivered (about 1.5 s after registration, before the scroll started: jankType 1/2/3, one each). Nothing was delivered during the 3-second
    scroll window, the 3 s return window or later, even with a flush() every second and a final flush in onPause (SUMMARY batches=1 frames=3). 40+ ticks logged with no new frames.
 So: no usable per-frame stream. The listener is registered on the WINDOW root (all surfaces of the window), not on the Flutter SurfaceView, and in this experiment it produced 3 frames in total.

WHAT THIS DOES NOT SHOW:
  - It does not show that no API could ever work: only that the documented SurfaceView listener is absent on this build and the AttachedSurfaceControl route gave 3 frames and hidden-API-blocked present fields.
  - One device, one build, one session; reflection on non-SDK members; low battery while charging; no Macrobenchmark; the delivery rule of this listener (it may require continuous app-side frame submission through
    the window's own SurfaceControl, which a SurfaceView content does not use) was not verified against AOSP source.
  - No T257/T267 verdict: engine FrameTiming remains engine timing, and nothing here is a presented-frame measurement.
