# T258 — Nghiên Cứu & Khắc Phục Khởi Tạo Profile Build để Đo RAM & Jank Benchmark

- **Loại:** Investigation / Tooling / Performance
- **Priority:** P1 · **Severity:** MEDIUM
- **Status:** inprogress (đang xác minh thực nghiệm trên thiết bị)

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
   - **Lượt 1 (meminfo breakdown):** Baseline PSS **433,593 KB**, Native **55,892 KB**, Graphics **189,476 KB**, WebViews **6**. Sau 10 chu kỳ PSS **433,933 KB**, Native **62,036 KB**, Graphics **207,484 KB**, WebViews **7**. Sau 20 chu kỳ PSS **449,862 KB**, Native **64,348 KB**, Graphics **211,240 KB**, WebViews **11**.
   - **Lượt 2 (native dump + HPROF histogram):** Dùng `com.roy.admob.t258.heaprun`, Profile, 20 toggles; dump baseline và sau run bằng `am dumpheap`; convert bằng `hprof-conv`; so sánh class instance counts với parser HPROF cô lập.
   - **Class histogram delta (baseline → sau run):**
     - `io.flutter.plugins.googlemobileads.FlutterBannerAd`: **1 → 6** (+5).
     - `io.flutter.plugins.googlemobileads.BannerAdCreator`: **1 → 6** (+5).
     - `com.android.webview.chromium.WebViewChromium`: **6 → 11** (+5).
     - `org.chromium.android_webview.AwContents`: **6 → 11** (+5).
     - `io.flutter.plugin.platform.PlatformViewRegistryImpl`: **1 → 1**; `PlatformViewsController`: **1 → 1**; `FlutterPlatformView`: **1 → 1**.
   - **Giới hạn kết luận:** Class count +5 xác nhận thêm 5 Java wrapper/WebView instances còn reachable tại thời điểm dump. Nó **không chứng minh cache** và cũng **không tự chứng minh leak**; cần retained size/dominator path và/hoặc đo sau idle + GC để biết chúng được GMA/Chromium giữ có chủ đích hay còn bị giữ bởi đường tham chiếu bất thường. PlatformView manager singleton không tăng, nhưng điều đó không chứng minh không có retained ad instances.
   - Lượt HPROF khác trước đó cho PSS **446,311 KB**, Native Heap **65,540 KB**, Graphics **209,832 KB**, WebViews **6**; chênh với lượt histogram cho thấy run-to-run variation đáng kể. Không trộn các lượt thành một chuỗi đo duy nhất.
   - Các HPROF đã dọn sau khi parser kết thúc; parser chưa tính retained sizes, dominator tree hay inbound references.

## Việc còn lại

1. Phân tích retaining paths/dominator của `FlutterBannerAd`, `WebViewChromium`, `AwContents`, `BannerAdCreator` bằng Android Studio Profiler hoặc MAT.
2. Lặp lại sau idle/GC để xác định instance count giảm hay giữ nguyên; không dùng class count đơn lẻ để gán kết luận cache/leak.
3. Thu frame timing riêng trong lúc shimmer chạy; `gfxinfo` hiện gộp init, UMP, ad load và chu kỳ.
4. Giữ các harness/run riêng biệt; chưa khái quát sang thiết bị khác.


## Acceptance Criteria

- [ ] Profile build khởi chạy hoàn tất qua màn hình Splash vào HomePage trên Pixel 7 Pro.
- [ ] Đo được số liệu PSS RAM và tỷ lệ giật khung hình gfxinfo trên Profile build thật.
- [ ] Không thêm thuộc tính public dư thừa vào `AdConfig`.
- [ ] `flutter analyze` sạch 0 issue; toàn bộ suite test xanh.
