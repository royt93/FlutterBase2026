# T257 — Toàn diện Ad Shimmer Loading: Tối ưu Ticker, Dark Mode, Khung Test Đa Chiều

- **Loại:** Hardening / Enhancement / Performance
- **Priority:** P0 · **Severity:** HIGH
- **Status:** inprogress (đang triển khai)

## Bối cảnh & Vấn đề

Trong `lib/src/widget/shimmer_view.dart`, `ShimmerView` được sử dụng làm placeholder trong suốt quá trình nạp quảng cáo Banner, MREC và Native. Qua rà soát mã nguồn và đo đạc thực tế trên Google Pixel 7 Pro, phát hiện các hạn chế:
1. **Lãng phí CPU/GPU và Ticker chạy ngầm:** `AnimationController(..repeat())` chạy liên tục chu kỳ 1200ms bằng `ShaderMask`. Khi ứng dụng bị đưa vào background hoặc chuyển sang route khác mà không unmount, Ticker vẫn tiếp tục tiêu tốn chu kỳ GPU và pin.
2. **Lỗi hiển thị Dark Mode (Gây chói mắt người dùng):** Màu gradient cố định `Color(0xFFE0E0E0)` và `Color(0xFFF8F8F8)` là màu xám trắng. Trên ứng dụng nền tối (Dark Theme), placeholder lóe sáng trắng đột ngột trước khi ad hiện, gây trải nghiệm người dùng xấu.
3. **Mất mạng & Timeout:** Khi thiết bị mất mạng hoặc ad load bị treo, cần cơ chế để shimmer tự động dừng hoặc sụp khoảng trống (collapse) mượt mà khi adapter báo lỗi/watchdog hết hạn.
4. **Thiếu kiểm thử đa chiều:** Cần bộ test bao phủ Golden test (Light/Dark), Interruption (lifecycle pause/resume), Network conditioning (mất mạng/phục hồi), Ticker leak qua nhiều chu kỳ, và đo Frame timing trên thiết bị thật.

## Đề xuất giải pháp

1. **Dark Mode Aware:** Hỗ trợ tự động nhận diện `Theme.of(context).brightness` để chuyển sang dải màu xám tối phù hợp (`0xFF2A2A2A` / `0xFF383838`) khi ở dark mode.
2. **Lifecycle Aware Ticker:** Tích hợp `WidgetsBindingObserver` để tự động `.stop()` controller khi app paused/inactive/hidden, và `.repeat()` lại khi resumed; cung cấp cờ `active` để render `Container` tĩnh khi không hoạt động.
3. **Graceful Collapse on Timeout / Load Error:** Adapter sở hữu watchdog 30s; khi hết hạn hoặc gặp lỗi nạp ad, `hasError` được bật và `BannerAdWidget` tự động sụp chiều cao về 0 (`SizedBox.shrink()`). Không đặt timer riêng trong `ShimmerView` để tránh lệch pha trạng thái với `AdSlot`.

## Acceptance Criteria

- [x] `ShimmerView` hỗ trợ màu Dark Mode tự nhiên theo theme hiện tại của ứng dụng (`[0xFF2A2A2A, 0xFF383838]`).
- [x] Ticker tự động dừng khi route bị ẩn hoặc ứng dụng chuyển sang chế độ background qua `WidgetsBindingObserver`, phục hồi khi trở lại foreground.
- [x] Không rò rỉ `AnimationController`/`TickerProvider` qua 30 chu kỳ mount/unmount trong widget test (`test/shimmer_view_test.dart`). Native heap/ad allocation leak chưa được đo riêng cho shimmer.
- [x] Golden test xác minh pixel hiển thị chính xác ở cả Light mode (`test/goldens/shimmer_view_light.png`) và Dark mode (`test/goldens/shimmer_view_dark.png`).
- [x] Interruption test xác minh vòng đời `paused`/`resumed` không gây crash hay rò rỉ Ticker.
- [x] Deterministic on-device loading + real watchdog: `example/integration_test/t257_shimmer_network_collapse_test.dart` dùng `debugSetAdapter` với controllable adapter, `AdSlot.armLoadWatchdog` 30s thật; assert `loadBannerIfNeeded` reached adapter, `ShimmerView` mounted trong lúc loading, watchdog nổ tự nhiên sau ~30s, shimmer bị gỡ và banner collapse height 0 trên Pixel 7 Pro (`flutter drive --profile`). Không mô phỏng mất mạng thật.
- [x] AdMobAdapter watchdog wiring: widget test `test/banner_ad_widget_test.dart` ("T257: real AdMobAdapter watchdog timeout removes shimmer and collapses banner") dùng `AdMobAdapter` thật, `MethodChannel` mock không callback, và `pump(31s)` để advance fake time; xác nhận listener bị evict, `hasError`, shimmer removal và height 0. Đây là test wiring/timer, không phải 30 giây wall-clock trên device.
- [x] Visual proof shimmer trên thiết bị: Dark Mode screenshot Pixel 7 Pro được lưu tạm tại `/tmp/t257_shimmer_pixel7pro.png` (1440x3120, 38,932 bytes; latest Pixel 7 Pro capture). Ảnh kiểm tra trực quan cho thấy dải shimmer hiển thị; pixel analysis thấy màu vùng banner khoảng `#292929`–`#2F2F2F` trên nền `#141218`. Ảnh không được commit và chưa có golden/pixel assertion tự động trên screenshot device.
- [ ] Frame rate/jank test 60fps ổn định toàn app: chưa đạt. Đã đo Flutter `FrameTiming` trên runner Profile chứa list/scroll + banner; số liệu ở mục 6 bên dưới. Tuy nhiên Android `dumpsys gfxinfo` chỉ trả 2 frames cho `SurfaceView` Flutter ở các runs này, nên chưa xác minh được presentation/drop rate ở tầng Android. Không kết luận 60fps ổn định từ các số này.
- [ ] Audit độc lập chấm điểm >9/10: vòng trước chấm 8.5/10; yêu cầu audit lại sau các thay đổi mới.
- [x] `flutter analyze` sạch 0 issue; full package unit/widget suite 2,725/2,725 pass (2026-10-18, sau BlendMode fix và dark pixel assertion). Con số này không gồm integration test và screenshot driver (chạy riêng trên device, chưa thuộc CI/release gate).

## Tiến độ thực tế & Bằng chứng kiểm thử (2026-10-17 / 2026-10-18)

1. **Dark Mode theo Theme:** Tự động nhận diện `Theme.of(context).brightness`, dải màu tối `[0xFF2A2A2A, 0xFF383838]`, nền `0xFF1E1E1E`. `ShaderMask` dùng `BlendMode.srcIn` để gradient dark không bị nhân với nền thành gần đen. Có 2 file golden tests và assertion pixel trong `test/shimmer_view_test.dart`; screenshot Pixel 7 Pro xác nhận pixel vùng shimmer xuất hiện trong dark theme.
2. **Lifecycle Aware Ticker:** Tích hợp `WidgetsBindingObserver`, `.stop()` controller khi app paused/inactive/hidden, `.repeat()` lại khi resumed. Thêm cờ `active` render `Container` tĩnh 0 overhead khi inactive.
3. **Watchdog Timeout & Collapse:**
   - Unit/Widget level: Đã có 2 test trong `test/banner_ad_widget_test.dart`: (a) "T257: adapter load error removes shimmer and collapses banner" và (b) "T257: real AdMobAdapter watchdog timeout removes shimmer and collapses banner" (kiểm tra `AdMobAdapter` thật + watchdog 30s tự nổ mà không cần gọi trigger thủ công).
   - On-device level (Pixel 7 Pro): Test `example/integration_test/t257_shimmer_network_collapse_test.dart` (chạy qua `flutter drive --profile`) kích hoạt `AdSlot.armLoadWatchdog` 30s thật, giữ loading hiển thị `ShimmerView`, lưu screenshot, chờ đúng 30s nổ tự nhiên, gỡ bỏ `ShimmerView` và co chiều cao banner về 0.
4. **Frame Timing trên Pixel 7 Pro thật (Profile build, 2026-10-18):**
   - Đợt 1 (driven pump test): 300–301 frames, 0 raster frame vượt 16.67ms, raster p95 2.85–2.98ms.
   - Đợt 2 (vsync tự nhiên, Impeller Vulkan, màn hình 120Hz): 3 lượt đo 5s độc lập:
     - Run 1: 570 frames (~114 fps), raster p95 2.63ms, build p95 1.67ms, total p95 5.65ms.
     - Run 2: 569 frames (~114 fps), raster p95 2.62ms, build p95 1.68ms, total p95 5.61ms.
     - Run 3: 584 frames (~117 fps), raster p95 2.59ms, build p95 1.66ms, total p95 5.46ms.
   - **Giới hạn diễn giải:** Các lượt đo standalone chạy ở ~114–117 frame/s trong cửa sổ 5 giây; p95 raster ~2.6ms, p95 build ~1.7ms, p95 total ~5.5ms; có 3 frame/lượt có `totalSpan >16.67ms`. Đây là timing của shimmer-only trong harness riêng, chưa chứng minh 60/120fps ổn định cho toàn bộ ứng dụng khi có WebView/AdMob. Không đo mức tiêu thụ CPU/GPU thực tế.
5. **Bộ test tự động:**
   - 13 widget tests trong `test/shimmer_view_test.dart` (theme, custom colors, active toggle, pause/resume lifecycle, 30 mount/unmount ticker clean, 75-frame pump simulation, network-error unmount).
   - 2 visual golden tests: `test/goldens/shimmer_view_light.png`, `test/goldens/shimmer_view_dark.png`.
   - 2 widget tests error/watchdog collapse trong `test/banner_ad_widget_test.dart` (gồm 1 test với `AdMobAdapter` thật).
   - 1 on-device integration test trên Pixel 7 Pro: `example/integration_test/t257_shimmer_network_collapse_test.dart`.
   - 1 screenshot driver: `example/test_driver/t257_screenshot_driver.dart`.
   - Full package suite: **2,725/2,725 tests pass**, `flutter analyze` 0 issue.

6. **Benchmark toàn UI trên Pixel 7 Pro (Profile, Android 17, màn 120Hz, thermal status 0, 2026-10-18):** runner `example/lib/t257_profile_frame_benchmark.dart` (list 80 dòng cuộn thật + `BannerAdWidget` cố định ở đáy, AdMob test IDs, UMP trả `notRequired`, `FirstInstallVipGrace.disabled` chỉ trong harness). Chạy bằng `flutter run --profile -t lib/t257_profile_frame_benchmark.dart --dart-define=AD_PROVIDER_ADMOB=true --dart-define=T257_BENCH_SCENARIO=<real|deterministic> -d <Pixel 7 Pro>`.
   - **Real (AdMob test banner), 3 lượt:** cả 3 lượt banner `ready` (không no-fill). Hai pha cuộn mỗi lượt (~3s mỗi pha): 228–264 `FrameTiming` samples, p95 build 1.69–2.48ms, p95 raster 2.86–3.58ms, p95 total 5.34–7.08ms, chỉ 1 sample `totalSpan` >16.67ms trong tổng 6 pha (lượt 2); khoảng cách vsync giữa các samples >16.67ms: 0–7/pha, >33.3ms: 0–1/pha.
   - **Deterministic (banner giữ loading rồi fill, 5 chu kỳ cuộn xuống/lên), 4 lượt hợp lệ:** mỗi lượt 10 pha cuộn (~22.8s), 2,348–2,379 samples; `totalSpan` >16.67ms: 5–8 samples/lượt; max p95 total 7.77–8.45ms. Metric khoảng cách vsync chỉ có ở 3 lượt sau (lượt đầu chạy bản runner chưa ghi metric này, không phải "0 gap"): >16.67ms: 23–33 samples/lượt, >33.3ms: 2–3 samples/lượt.
   - **Perfetto FrameTimeline follow-up (Pixel 7 Pro, Android 17):** capture Profile real-run kéo dài 70s bao phủ banner-ready và hai pha cuộn. FrameTimeline có 513 display-level `actual_frame_timeline_slice` records trong các pha; đều `On-time Present`, không ghi jank/drop. Nhưng các record này thuộc `SurfaceFlinger` (upid=3, `layer_name=NULL`), không gắn được với app. Các layer gắn tên package chỉ xuất hiện lúc khởi chạy/chuyển từ splash; không có app-attributed frame trong hai pha cuộn. Trace vì vậy **không chứng minh** app duy trì 60fps hoặc không drop; giữ acceptance criterion mở. Raw trace ở `/tmp/t257_real_frametimeline_valid.pftrace` (local, không commit); processor v58.2 hash-verified. Trace báo `systrace_parse_failure: 550`, thêm giới hạn chất lượng dữ liệu. Deterministic capture riêng (45s, buffer 256MB) phủ đủ 5 chu kỳ: 2,399 display-level records, đều `On-time Present`, 0 jank, 0 dropped, avg duration 10.2ms. Nhưng records này cũng thuộc `SurfaceFlinger` (pid 592, `layer_name=NULL`); không có app-attributed layer, nên vẫn không chứng minh app giữ 60fps. Trace báo `systrace_parse_failure: 4802`.
   - **Giới hạn:** `FrameTiming` đo thời gian build/raster và mốc vsync mà Flutter ghi nhận, không phải số frame được present/drop. Android `dumpsys gfxinfo` chỉ báo 2 frames cho `SurfaceView` Flutter ở mọi lượt; `SurfaceFlinger --latency` chỉ trả vsync period; counter missed-frame của SurfaceFlinger là toàn hệ thống (255 → 260 qua cả buổi đo). Vì vậy **không có bằng chứng Android-level gắn với app** cho 60fps ổn định hoặc không drop. Tốc độ 76–117 samples/s là tần suất `FrameTiming`, không phải FPS hiển thị. Pha UMP/init có 4–7 samples với p95 total 25–76ms (khởi động, ngoài phạm vi shimmer). Mỗi pha cuộn real gồm ~2s cuộn + ~1s đứng yên; deterministic gồm 2s cuộn + 0.5s/2s chờ.
   - Raw logs đã lưu trong `doc/task/inprogress/T257-evidence/`: 3 lượt `real_metrics`, 4 lượt `deterministic_metrics`, cùng 3 lượt `real_gfxinfo` và 4 lượt `deterministic_gfxinfo`. Đây là log nguyên bản từ Pixel 7 Pro; các counter `gfxinfo` vẫn chỉ ghi nhận 2 frame cho Flutter `SurfaceView`, nên không dùng để kết luận frame pacing.

## Kế hoạch kiểm thử

- **Unit/Widget test:** Kiểm tra khởi tạo controller, theme adaptation, active flag, dispose cleanup.
- **Golden test:** Sinh và assert visual golden `shimmer_view_light.png` và `shimmer_view_dark.png`.
- **Interruption test:** Giả lập `AppLifecycleState.paused` rồi `resumed`, assert Ticker state.
- **Deterministic loading + watchdog test:** Giữ banner ở trạng thái loading bằng controllable adapter, xác nhận shimmer hiển thị, đợi `AdSlot` watchdog 30s thật và kiểm tra collapse. Đây không phải network conditioning test thật.
- **Memory test:** 30 chu kỳ mount/unmount kiểm tra không rò rỉ Ticker.
- **Frame timing test:** Đo `FrameTiming` của ShimmerView trên thiết bị vật lý Profile build.

---

## Prompt vòng lặp (Loop Prompt)

```markdown
Triển khai task T257 theo quy trình kỹ thuật nghiêm ngặt:
1. Đọc kỹ file task này và lib/src/widget/shimmer_view.dart, banner_ad_widget.dart, mrec_ad_widget.dart, native_ad_widget.dart.
2. Viết test trước để chứng minh hạn chế hiện tại (TDD).
3. Triển khai mã nguồn tối giản nhất có thể để vượt qua các test.
4. Tín hiệu kết thúc vòng lặp (End Loop Signals) BẮT BUỘC:
   - Hãy audit lại code changes và chấm điểm trên thang điểm 10.
   - Bổ sung unit test + widget test + integration test cho mọi case + smoke test lên device chứng minh.
   - Nếu work và điểm >9/10 thì push code.
```
