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
3. **Hiện trạng trên thiết bị thật Pixel 7 Pro:**
   - Đã gỡ assert trong Profile (`isDebug: kDebugMode || kProfileMode`), dòng lỗi đỏ biến mất.
   - Example Profile app khi mở trên Android 13+ xuất hiện popup xin quyền thông báo của hệ điều hành (`POST_NOTIFICATIONS`), làm dừng luồng chờ ở màn hình Splash.

## Đề xuất giải pháp tiếp theo

1. Thêm cờ bỏ qua hoặc auto-resolve permission trong splash khi chạy ở chế độ Profile benchmark.
2. Viết integration test chuyên biệt chạy ở Profile mode (`flutter run --profile`) đo chính xác:
   - 20 vòng nạp/hủy Banner.
   - Thu thập chỉ số `dumpsys meminfo` (PSS) và `dumpsys gfxinfo` trên Pixel 7 Pro thật.

## Acceptance Criteria

- [ ] Profile build khởi chạy hoàn tất qua màn hình Splash vào HomePage trên Pixel 7 Pro.
- [ ] Đo được số liệu PSS RAM và tỷ lệ giật khung hình gfxinfo trên Profile build thật.
- [ ] Không thêm thuộc tính public dư thừa vào `AdConfig`.
- [ ] `flutter analyze` sạch 0 issue; toàn bộ suite test xanh.
