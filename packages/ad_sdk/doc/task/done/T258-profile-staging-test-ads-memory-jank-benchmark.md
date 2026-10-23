# T258 — Nghiên Cứu & Khắc Phục Khởi Tạo Profile Build để Đo RAM & Jank Benchmark

- **Loại:** Investigation / Tooling / Performance
- **Priority:** P1 · **Severity:** MEDIUM
- **Status:** done (2026-10-22; hoàn tất phần Profile/PSS/Flutter FrameTiming trên TECNO, giới hạn Android jank attribution được chuyển sang T267)

## Bối cảnh & Kết quả Xác minh Thực tế (2026-10-17 trên Pixel 7 Pro)

1. **Tiền đề cũ đã được kiểm chứng lại và đính chính:**
   - Giả thuyết ban đầu cho rằng `_testIdFootgunBlocked` chặn profile build là **KHÔNG ĐÚNG**.
   - Thực tế: `_testIdFootgunBlocked` chỉ kích hoạt khi `isActuallyRelease(isRelease) == true`. Trong `kProfileMode`, `kReleaseMode` mặc định là `false` nên guard chặn ad của Release không hề chạy.
2. **Nguyên nhân thật sự khiến Profile build bị chặn trước đó:**
   - Trong `AdManager.initialize`: vòng lặp `for (final w in releaseFootgunWarnings(config, isDebug: kDebugMode))` sử dụng `kDebugMode`.
   - Trong Profile build, `kDebugMode == false`, nên hàm coi Profile là Release và in ra cảnh báo: `🚨 AdMob provider is active in RELEASE with Google TEST ad unit IDs...` kèm lệnh `assert(false, w)`.
   - Trong Profile build của Flutter, `assert` có thể được bật tùy cấu hình hoặc luồng xử lý splash của example bị gián đoạn trước khi `AdManager.initialize()` kịp hoàn tất.
3. **Sửa lỗi Profile/Release warning gate (commit `150c9e3`):**
   - Đổi warning gate sang `isDebug: !isActuallyRelease(isRelease)`, nên chỉ build Release thực sự mới phát warning/assert.
   - Thêm regression test `profile build does not run release footgun warnings`; test Release `release + AdMob Google test IDs` vẫn pass, xác nhận guard Release không bị nới lỏng.
   - `flutter analyze` và full SDK suite pass sau thay đổi.
4. **Profile benchmark harness lặp 3 lần trên Pixel 7 Pro thật (2026-10-17):**
   - Dùng bản copy isolated `com.roy.admob.t258.repeat`, Profile APK **75.3 MB**, Android 16/API 36, thiết bị Google Pixel 7 Pro. AdMob Google test banner 320x50; UMP trả `notRequired`, `canRequestAds=true`. `firstInstallVipGrace: FirstInstallVipGrace.disabled` chỉ áp dụng cho harness thử nghiệm để tránh trial 24h mặc định của Profile suppress ad; không đổi SDK/source production.
   - Mỗi run khởi động process sạch, phát 40 toggle `BENCH: cycle=1..40` (20 chu kỳ đầy đủ dispose→mount). Mỗi run có 21 banner `initState`/load requests (lần đầu + 20 lần mount lại). Không có `FATAL EXCEPTION` hoặc lỗi `loadBanner`; Run 3 có 21/21 load success trước khi lấy log. Run 1/2 có ít success hơn vì một số load chưa hoàn tất lúc chụp snapshot, không xem đó là failure.
   - Sau `am send-trim-memory RUNNING_CRITICAL`, PSS (KB):

     | Run | Baseline | Sau 10 chu kỳ | Sau 20 chu kỳ |
     |---|---:|---:|---:|
     | 1 | 401,106 | 449,368 | 448,277 |
     | 2 | 409,316 | 444,357 | 455,149 |
     | 3 | 406,607 | 447,881 | 454,574 |

   - `dumpsys gfxinfo` (toàn phiên run, không chỉ shimmer):

     | Run | Frames | Janky frames | Janky % | p50 | p90 | p95 | p99 |
     |---|---:|---:|---:|---:|---:|---:|---:|
     | 1 | 290 | 36 | 12.41% | 5ms | 17ms | 28ms | 36ms |
     | 2 | 258 | 33 | 12.79% | 5ms | 19ms | 32ms | 40ms |
     | 3 | 280 | 37 | 13.21% | 5ms | 18ms | 31ms | 42ms |

   - Tổng quát: PSS tăng sau 10 chu kỳ khoảng 35–48 MB so với baseline; mốc 20 ở Run 1 tăng 47 MB, Run 2 tăng 46 MB, Run 3 tăng 48 MB. Đây là **dấu hiệu cần phân tích thêm**, không chứng minh leak: `send-trim-memory` không đảm bảo GC hoàn tất, PSS gồm cả cache/native allocation của Google Mobile Ads. Các lượt đo không có heap dump/native allocation attribution.
   - Jank tổng phiên khoảng 12–13%; không đo riêng shimmer và không quy kết toàn bộ jank cho shimmer. P95 28–32ms nên dữ liệu này **không chứng minh 60fps ổn định**.

5. **Phân rã native heap/graphics và HPROF trên Pixel 7 Pro (2026-10-17):**
   - **Lượt meminfo (Profile, 20 chu kỳ):** Baseline PSS **433,593 KB**, Native **55,892 KB**, Graphics **189,476 KB**, WebViews **6**. Sau 10 chu kỳ PSS **433,933 KB**, Native **62,036 KB**, Graphics **207,484 KB**, WebViews **7**. Sau 20 chu kỳ PSS **449,862 KB**, Native **64,348 KB**, Graphics **211,240 KB**, WebViews **11**.
   - **Lượt HPROF độc lập (`com.roy.admob.t258.heaprun`, Profile, 20 toggles):** Parser HPROF cô lập đọc class instance counts baseline → after:
     - `io.flutter.plugins.googlemobileads.FlutterBannerAd`: **1 → 7** (+6).
     - `io.flutter.plugins.googlemobileads.FlutterBannerAdListener`: **1 → 7** (+6).
     - `io.flutter.plugins.googlemobileads.BannerAdCreator`: **1 → 7** (+6).
     - `com.android.webview.chromium.WebViewChromium`: **6 → 12** (+6).
     - `org.chromium.android_webview.AwContents`: **6 → 12** (+6).
     - `PlatformViewsController`, `FlutterPlatformView`, `AdInstanceManager`: mỗi loại **1 → 1**.
   - Một lần HPROF khác trước đó ghi WebViews **6 → 11**; các lượt khác nhau dao động, nên không gộp thành một chuỗi đo. Class histogram chỉ cho biết instance còn trong snapshot; **không chứng minh cache hay leak**.
   - Android Studio Shark parser được thử qua CLI nhưng không tạo class counts/path đáng tin ở dump baseline. Không trích được dominator/retaining path bằng CLI.
   - HPROF đã bị xóa theo lựa chọn của user sau khi retained-path analysis qua GUI không hoàn tất. Không còn dump để phân tích lại; chưa có retained-size hoặc inbound-reference evidence.

6. **Shimmer-only Flutter frame timings (Pixel 7 Pro, Profile, 2026-10-18):**
   - **Đợt 1 (driven pump test):** `example/integration_test/t258_shimmer_frame_timing_test.dart` mount `ShimmerView` (320x50), thu 300 pump(16ms). 3 lượt đo đều ra 300–301 frames, raster p95 2.85–2.98ms, 0 frame raster > 16.67ms.
   - **Đợt 2 (vsync tự nhiên, Impeller Vulkan, màn 120Hz Pixel 7 Pro):** Standalone app `example/lib/t258_shimmer_profile.dart` chỉ mount `ShimmerView`, chạy 5 giây theo vòng lặp render tự nhiên của hệ thống, thu `FrameTiming` thật.

     | Run | Total Frames (~5s) | Avg FPS | Raster >16.67ms | Build >16.67ms | Total Span >16.67ms | p95 Raster | p95 Build | p95 Total |
     |---|---:|---:|---:|---:|---:|---:|---:|---:|
     | 1 | 570 | ~114 | 1 | 0 | 3 | 2.63ms | 1.67ms | 5.65ms |
     | 2 | 569 | ~114 | 1 | 0 | 3 | 2.62ms | 1.68ms | 5.61ms |
     | 3 | 584 | ~117 | 1 | 0 | 3 | 2.59ms | 1.66ms | 5.46ms |

   - **Giới hạn diễn giải:** Các run thu được ~114–117 frame/s trong cửa sổ 5 giây; p95 raster ~2.6ms, p95 build ~1.7ms, p95 total ~5.5ms. Có 3 frame/lượt có `totalSpan >16.67ms`. Đây là timing của shimmer-only trong harness riêng, không chứng minh frame delivery ổn định cho app hoặc giải thích tỷ lệ `gfxinfo` ở mục 4.

7. **Điều tra nguồn jank toàn phiên (Phân rã theo pha, Pixel 7 Pro, Profile, 2026-10-18):**
   - Harness: `example/lib/t258_phase_jank_profile.dart`, phân rã theo mốc `Timeline.now` ứng với từng pha hoạt động, chạy 3 lượt độc lập trên Pixel 7 Pro (Vulkan Impeller, màn hình 120Hz).
   - **Pha 1: UMP Consent & SDK Init:**
     - Thời gian chạy: UMP 534–832ms, Init 501–2294ms.
     - Số frame Flutter render: 0 (không có animation/UI re-layout). Không có jank từ luồng Flutter.
   - **Pha 2: First Banner (Mount + Shimmer + Android PlatformView / WebView creation):**
     - Run 1: 365 frames, 3 frames >16.67ms, 1 frame >33.3ms, p95 total 5.95ms.
     - Run 2: 140 frames, 2 frames >16.67ms, 2 frames >33.3ms, p95 total 7.08ms.
     - Run 3: 136 frames, 3 frames >16.67ms, 2 frames >33.3ms, p95 total 9.98ms.
   - **Pha 3: 20 Chu kỳ Mount (600ms) / Dispose (400ms) liên tục (~20 giây):**

     | Run | Total Frames | Frames >16.67ms | Frames >33.3ms | p95 Total Span | Tỷ lệ Jank (Flutter) |
     |---|---:|---:|---:|---:|---:|
     | 1 | 1,448 | 3 | 2 | 6.67ms | 0.21% |
     | 2 | 1,429 | 4 | 3 | 6.69ms | 0.28% |
     | 3 | 1,442 | 6 | 3 | 6.66ms | 0.42% |

   - **Giới hạn diễn giải:**
     - Các con số trên là `FrameTiming.totalSpan` vượt các ngưỡng thời lượng nêu trong bảng; **không tương đương phép đo dropped-frame/vsync miss**. `FrameTiming` ghi build/raster pipeline latency, không cung cấp trực tiếp khoảng cách giữa hai lần vsync.
     - UMP/Init có 0 frame được ghi nhận trong khoảng marker ở các lượt này; điều đó chỉ nói không có `FrameTiming` gán vào khoảng đó, không chứng minh main thread hoặc native UI không bị block.
     - Kết quả Flutter timing thấp trong giai đoạn cycles không giải thích được tỷ lệ `dumpsys gfxinfo` 12–13%. Chưa có bằng chứng quy tỷ lệ kia cho splash, Android compositor, WebView hay thành phần cụ thể nào.
     - Không dùng các số này để khẳng định 60/120fps ổn định hoặc loại trừ jank native.

## Việc còn lại

1. Đối chiếu `FrameTiming` với Android `gfxinfo` có marker cùng khoảng thời gian, nếu cần truy nguồn gốc tỷ lệ 12–13%.
2. **Tạm ngừng HPROF investigation theo quyết định user.** Chỉ tạo lại heap dump nếu user yêu cầu tiếp tục.
3. Đã dọn dẹp các harness thử nghiệm tạm thời khỏi repo (`example/lib/t258_*.dart` và test liên quan).
4. Giữ các harness/run riêng biệt; chưa kết luận leak/cache hoặc khái quát sang thiết bị khác.
5. **Smoke Profile trên TECNO KJ7 / Android 14 (2026-10-22; thiết bị được owner chọn cho lượt tiếp theo):** Profile APK build thành công (84.2 MB), cài và khởi chạy cold thành công; screenshot xác nhận HomePage hiển thị, process còn sống và không có `FATAL EXCEPTION`. Log ghi `markSplashActive`, `incrementSplashCount`, rồi `splash budget exceeded (8s)`; không thấy marker xác nhận SDK init hoàn tất, nên không kết luận init hoàn tất. Snapshot ban đầu `dumpsys meminfo`: TOTAL PSS 271,506 KB, Native Heap 36,612 KB, Graphics 128,776 KB. Hai lần `dumpsys gfxinfo` trước harness scroll trả 0 frame, nên không tính percentile 4,950ms hoặc `Janky frames: 0`.
6. **FrameTiming auto-start smoke trên TECNO (2026-10-22):** Harness Profile `/loading`, `T257_BENCH_AUTO_START=true`; log tuần tự `T267_READY`, `T267_START auto`, `T267_BANNER_AT_SCROLL slot=loading loaded=false error=false`, `loading_scroll`, `loading_scroll_end`, `report`. Pha scroll 2,051ms có **218 FrameTiming samples** (106.28 samples/s); 5 `totalSpan >16.67ms`, 13 `>8.33ms`; 5 sampled vsync gaps `>16.67ms`, 4 `>33.3ms`; p95 sampled gap **8.35ms**, p95 build **1.34ms**, p95 raster **2.80ms**, p95 total **10.05ms**. Đây là pipeline timing/sample gaps Flutter, không phải Android presented/dropped frames. Sau run, toàn phiên `dumpsys gfxinfo` có 76 frames, 2 janky (2.63%); đây là app-level session aggregate, không được quy riêng cho pha scroll. PSS snapshot sau harness: TOTAL PSS 411,537 KB, Native Heap 45,472 KB, Graphics 199,284 KB; khác mốc ban đầu do ads/harness đã chạy, không so như leak delta. Không có `FATAL EXCEPTION`.
7. **Kiểm tra mã/test (2026-10-22):** `flutter analyze` sạch; focused widget tests 4/4 pass; full example widget suite 71/71 pass; full SDK suite **2,739 tests passed**; working tree không có thay đổi trong `AdConfig`.

## Acceptance Criteria

**Phạm vi thiết bị được owner đổi ngày 2026-10-22:** dùng TECNO KJ7 / Android 14 cho smoke T258; không dùng kết quả này để khái quát sang Pixel 7 Pro.

- [x] Profile app mở được HomePage trên TECNO sau splash budget timeout; process còn sống, không có `FATAL EXCEPTION`. SDK initialize hoàn tất chưa được chứng minh.
- [x] Thu được PSS trên Profile build thật: TOTAL PSS 271,506 KB, Native Heap 36,612 KB, Graphics 128,776 KB.
- [x] Thu được `gfxinfo` sample trên TECNO: 76 frame toàn phiên, 2 janky (2.63%). Đây là aggregate cả phiên, không cô lập scroll phase.
- [x] Thu được `FrameTiming` scroll-phase sample: 218 mẫu trong 2,051ms, engine-only; chi tiết ở mục 6.
- [ ] Thu được jank sample Android `gfxinfo` được correlate/cô lập cho scroll phase; hiện chỉ có aggregate toàn phiên. Deferred sang T267; không chặn hoàn tất phạm vi T258 bên dưới.
- [x] Không thêm thuộc tính public dư thừa vào `AdConfig`.
- [x] `flutter analyze` sạch 0 issue; toàn bộ suite test xanh (2,739 tests).

**Trạng thái:** T258 hoàn tất theo phạm vi Profile launch, PSS, Flutter `FrameTiming`, phân tích và test. `gfxinfo` chưa được correlate riêng với scroll và được deferred sang T267; SDK init hoàn tất chưa được chứng minh. Không suy ra leak hoặc 60fps từ các số liệu này.
