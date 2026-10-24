# T263 — Tự Động Giảm Tải Quảng Cáo Khi Pin Yếu Hoặc Bật Tiết Kiệm Pin (Battery Saver Mode)

- **Loại:** Enhancement / Performance & Battery Health
- **Priority:** P2 · **Severity:** LOW
- **Status:** todo · discovery complete 2026-10-24; implementation still gated on scope/behavior decision

## Discovery gate (bắt buộc trước implementation)

- [x] Discovery 2026-10-24: Android có `PowerManager.isPowerSaveMode()` và `BatteryManager`/`ACTION_BATTERY_CHANGED`; iOS có `ProcessInfo.isLowPowerModeEnabled` và `UIDevice.batteryLevel/batteryState`. Các API cần native bridge/host channel (battery percentage Android là sticky broadcast; không thấy quyền đặc biệt cần cho mức pin/Power Save, nhưng phải xác nhận trên minSdk/build cụ thể trước implementation). Chưa thêm code hoặc dependency.
- [x] Dependency scan: repo hiện không khai báo `battery_plus`/`device_info_plus`; package có Android Gradle/Kotlin, Google Mobile Ads và AppLovin CocoaPods pinning walls. Không đề xuất plugin mới trước owner approval; prefer một native channel tối thiểu hoặc API host-provided.
- [ ] Định nghĩa hành vi khi trạng thái pin không khả dụng, stream lỗi, app quay foreground, hoặc pin/Battery Saver đổi khi ad đang loading/showing.
- [x] Đối chiếu implementation (2026-10-24): `AdSafetyParams.minTimeBetweenFullscreenAds` default hiện là 60,000ms, không phải 30s; T230 fatigue path đã tự nhân đôi throttle. Không đổi throttle lần nữa nếu chưa chốt rõ điều kiện/giá trị mới. AppLovin auto-refresh đã qua `InlineVisibilityOwners`/`autoRefreshEnabled`; AdMob Google SDK quản lý refresh native và notifier tương ứng là unused stub. Dừng việc giả định một Dart switch có thể pause cả hai provider.
- [ ] Nếu chỉ một nền tảng có API đáng tin, giữ feature platform-specific và fail-safe; không tuyên bố cross-platform.
- [ ] Dừng ở discovery nếu không thể có API/test seam đáng tin mà không nới dependency pinning wall.

## Bối cảnh & Vấn đề

Quảng cáo dạng video (Rewarded, Interstitial) và Banner tự động làm mới (Auto-refresh 30s) tiêu thụ tài nguyên phần cứng lớn:
- Khi pin thiết bị xuống dưới 15% hoặc người dùng bật chế độ Tiết kiệm pin của hệ điều hành: việc tiếp tục nạp video ad và làm mới banner liên tục khiến điện thoại bị quá nhiệt, tụt pin nhanh và giật lag nghiêm trọng.
- Người dùng thường có xu hướng gỡ bỏ ngay lập tức những ứng dụng gây hao pin nhanh.

## Đề xuất giải pháp

1. Tích hợp kiểm tra trạng thái pin và chế độ Low Power Mode (thông qua thư viện nhẹ hoặc Native MethodChannel tối giản).
2. Khi phát hiện pin dưới 15% hoặc bật Battery Saver:
   - Tự động tăng thời gian giãn cách giữa 2 quảng cáo toàn màn hình (throttle interval) từ 30 giây lên 60 giây.
   - Tạm dừng auto-refresh của banner để giảm kết nối mạng và render ngầm.
3. Khi cắm sạc hoặc pin hồi phục >20%: tự động hoàn nguyên về cấu hình tiêu chuẩn.

## Acceptance Criteria

- [ ] Khi thiết bị ở trạng thái pin yếu hoặc Battery Saver, giãn cách quảng cáo tự động tăng gấp đôi để bảo vệ pin.
- [ ] Tạm dừng ticker auto-refresh của banner khi pin yếu.
- [ ] Không làm crash ứng dụng nếu platform không hỗ trợ đọc thông số pin.
- [ ] `flutter analyze` sạch 0 issue; toàn bộ suite test xanh.

## Kế hoạch kiểm thử

- **Unit test:** Kiểm tra tính toán `effectiveThrottleInterval` khi pin yếu.
- **Widget test:** Kiểm tra trạng thái `autoRefreshEnabled` của banner khi chuyển đổi chế độ pin.

---

## Prompt vòng lặp (Loop Prompt)

```markdown
Triển khai task T263 theo quy trình kỹ thuật nghiêm ngặt:
1. Đọc kỹ file task này và lib/src/core/ad_safety_config.dart, lib/src/core/ad_manager.dart.
2. Viết test trước để kiểm tra hành vi thích ứng theo pin (TDD).
3. Triển khai mã nguồn tối giản nhất có thể để vượt qua các test.
4. Tín hiệu kết thúc vòng lặp (End Loop Signals) BẮT BUỘC:
   - Hãy audit lại code changes và chấm điểm trên thang điểm 10.
   - Bổ sung unit test + widget test + integration test cho mọi case + smoke test lên device chứng minh.
   - Nếu work và điểm >9/10 thì push code.
```
