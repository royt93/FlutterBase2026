# T242 — AppLovin App Open Stale-Callback Quarantine sau Lost Hidden Callback

- **Loại:** Fix / Hardening (Audit Round 73-74)
- **Priority:** P1 · **Severity:** HIGH
- **Status:** ✅ done

## Bối cảnh & Vấn đề

Trên AppLovin MAX, khi một lượt hiển thị App Open ad kết thúc mà native callback `onAdHidden` bị thất lạc hoặc trễ (do watchdog ~10s trên Android hoặc 90s hard-cap trên iOS buộc phải giải phóng slot để người dùng không bị kẹt ở Splash), AppLovin có thể bắn trả callback này trễ 10-30s sau đó với `creativeId` rỗng hoặc dùng chung. 
Nếu không có cơ chế cách ly (quarantine), callback muộn này có thể bị gán nhầm vào một lượt gọi `showAppOpen` mới tinh vừa xuất hiện ngay sau đó, làm sai lệch trạng thái slot và thống kê impression.

Cơ chế quarantine 35s này đã có cho Interstitial và Rewarded từ Audit round 42, nhưng App Open bị bỏ sót (Audit 73 phát hiện).

## Bằng chứng kiểm thử & Hoàn thành

- **Audit Score:** 10/10 (Review độc lập round 75 tìm ra 1 lỗi thật sự: callback trễ huỷ nhầm watchdog lượt mới. Đã sửa mã nguồn `applovin_adapter.dart`, huỷ timer chỉ khi vượt qua bài test stale ad. Test integration `stale native callback during active show does not disarm watchdog` đã chứng minh fix trên cả 2 HĐH).
- **Unit test:** `packages/ad_sdk/test/applovin_adapter_test.dart` (nhóm `audit round 73: App Open gets the same stale-callback quarantine`)
  - Watchdog kích hoạt quarantine 35s, từ chối lượt show kế tiếp ngay cả khi slot đã ready.
  - Callback muộn từ cycle cũ không chạm tới và không giải phóng nhầm cycle mới.
  - Sau đúng 34s vẫn bị chặn, chạm mốc 35s slot tự giải phóng và cho phép show bình thường.
  - `dispose()` huỷ bỏ hoàn toàn timer cách ly, không ném exception.
  - Xác nhận cả hai nhánh: display confirmed (`true`) và display unconfirmed (`false`).
- **Widget test:** `packages/ad_sdk/test/appopen_quarantine_splash_widget_test.dart`
  - Splash tuân theo hợp đồng `AdManager().showAppOpenAd(bypassSafety: true, onAdDismiss: ...)`.
  - Khi App Open bị quarantine từ chối, `onAdDismiss(false)` được trả về ngay lập tức, splash điều hướng thành công vào `home`, không bị kẹt/treo giao diện và không bị duplicate navigation.
- **Manager/Telemetry test:** `packages/ad_sdk/test/appopen_quarantine_manager_test.dart`
  - Lượt show bị quarantine từ chối không ghi nhận impression vào `AdSafetyConfig`.
  - Vẫn phát ra telemetry `AdShowEvent(success: false)` để hệ thống quan sát được sự kiện từ chối.
- **On-Device Integration Test:** `packages/ad_sdk/example/integration_test/appopen_quarantine_refused_test.dart`
  - **Android (Physical device TECNO KJ7):** Chạy thực tế qua watchdog 10s grace period, xác nhận quarantine từ chối lượt show thứ hai và không gọi xuống native bridge.
  - **iOS (Simulator AdSdkTest-iPhone16):** Chạy bằng platform tự nhiên, chờ đủ 90s hard-cap timeout thực tế để chứng minh nhánh iOS không dùng foreground-as-hung sai lầm, hoàn tất pass toàn bộ suite.
- **Tooling Fix kèm theo:** Cập nhật fixture `tool/pinning_check_app` lên Kotlin plugin 2.3.0 và xoá bỏ cú pháp `kotlinOptions` bị loại bỏ trên Kotlin 2.3.0, đảm bảo lệnh `./tool/check_pinning_wall.sh --with-builds` pass cả Android APK và iOS Simulator Runner app.

## Acceptance Criteria
- [x] `AppLovinAdapter` cách ly App Open trong 35s sau khi rơi vào timeout/watchdog do mất callback.
- [x] Lượt `showAppOpen` trong thời gian cách ly lập tức trả về `onDismiss(false)`, không đụng tới native SDK.
- [x] Callback trễ của lượt cũ không giải phóng hoặc làm ảnh hưởng lượt mới.
- [x] Timer tự động huỷ khi `dispose()`.
- [x] Đầy đủ kim tự tháp kiểm thử: Unit test, Widget test, Integration test trên cả Android và iOS.
- [x] Full `flutter test` pass (exit 0; số test chưa ghi lại chính xác).

## Prompt vòng lặp (Loop Prompt)

Triển khai các tính năng/bản vá quảng cáo theo vòng lặp chuẩn:
1. Phân tích mã nguồn và các ràng buộc kiến trúc, kiểm tra các adapter liên quan.
2. Viết kiểm thử trước theo phương pháp TDD (Unit + Widget).
3. Triển khai bản vá tối giản, không tạo thêm tầng trừu tượng không cần thiết.
4. Tín hiệu kết thúc vòng lặp:
   - Audit lại toàn bộ thay đổi với reviewer độc lập và chấm điểm đạt >9/10.
   - Bổ sung đầy đủ Unit test, Widget test, Integration test cho mọi nhánh rẽ (success, failure, timeout, platform divergence).
   - Smoke test trên thiết bị thật (hoặc simulator platform thật) để chứng minh.
   - Chỉ push code lên remote branch khi tất cả tiêu chí trên thỏa mãn.
