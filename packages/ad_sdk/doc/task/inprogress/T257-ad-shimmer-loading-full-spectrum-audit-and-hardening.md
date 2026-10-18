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
- [ ] Visual proof shimmer trên device: integration test yêu cầu `convertFlutterSurfaceToImage()`/`takeScreenshot()` và kiểm tra bytes không rỗng. Screenshot PNG đã lưu tạm tại `/tmp/t257_shimmer_pixel7pro.png` (1440x3120, ~24.5KB), nhưng pixel analysis chỉ thấy Scaffold + nav bar, không có pixel shimmer. Assertion `find.byType(ShimmerView)` chỉ chứng minh widget có trong tree; visual proof chưa đạt. File screenshot ở `/tmp` là artifact tạm, không lưu trong repo.
- [ ] Frame rate/jank test 60fps ổn định toàn app: chưa đạt; mới chỉ có số liệu `FrameTiming` riêng của `ShimmerView` trên Pixel 7 Pro Profile (xem mục 4 dưới đây).
- [ ] Audit độc lập chấm điểm >9/10: các vòng trước chấm 8/10 và 9/10; đang chờ vòng audit tiếp theo sau khi bổ sung test AdMobAdapter watchdog thật và lưu file PNG screenshot.
- [x] `flutter analyze` sạch 0 issue; full package unit/widget suite 2,725/2,725 pass. Con số này không gồm integration test và screenshot driver (chạy riêng trên device, chưa thuộc CI/release gate).

## Tiến độ thực tế & Bằng chứng kiểm thử (2026-10-17 / 2026-10-18)

1. **Dark Mode theo Theme:** Tự động nhận diện `Theme.of(context).brightness`, dải màu tối `[0xFF2A2A2A, 0xFF383838]`, nền `0xFF1E1E1E`. Có 2 file golden test xác minh pixel.
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
