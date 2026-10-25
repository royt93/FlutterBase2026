# T272 — Tự Động Nạp Lại Banner/Inline Ads Khi Kết Nối Mạng Phục Hồi (Instant Reconnect Inline Reload)

- **Loại:** Enhancement / Revenue Recovery
- **Priority:** P1 · **Severity:** MEDIUM
- **Status:** complete (2026-10-25; verified unit tests & release gate)

## Bối cảnh & Vấn đề

1. **Thất thoát doanh thu Banner/MREC khi mất mạng tạm thời:**
   - Khi thiết bị mất kết nối mạng (chế độ máy bay, thang máy, sóng yếu), các quảng cáo Banner và MREC đang hiển thị sẽ gặp lỗi no-fill / network error (`hasError == true`) và ẩn khỏi màn hình hoặc hiển thị placeholder/house ad.
   - Khi mạng phục hồi (`_onConnectivityChanged(true)`), SDK hiện tại đã có `AdMobAdapter.recoverInlineAdsAfterReconnect()` cho AdMob, nhưng **hoàn toàn chưa có cơ chế này cho AppLovinAdapter**.
   - Hậu quả: Với nhà phát hành sử dụng AppLovin MAX làm provider chính, toàn bộ Banner/MREC bị lỗi khi mất mạng sẽ bị bỏ quên và không tự động tải lại cho đến tận khi người dùng thoát app ra ngoài rồi quay lại (`onAppResumed`). Điều này gây thất thoát trực tiếp một lượng lớn hiển thị banner.

2. **Giải pháp:**
   - Triển khai `AppLovinAdapter.recoverInlineAdsAfterReconnect()`: Quét qua tất cả banner và MREC trong registry có cờ `needsRecovery == true`, giải phóng ad view lỗi cũ và gọi `preloadBanner(key)` / `preloadMrec(key)`.
   - Kết nối `AdManager._onConnectivityChanged` để gọi `recoverInlineAdsAfterReconnect()` cho cả `AdMobAdapter` và `AppLovinAdapter`.
   - Đảm bảo kiểm soát chặt chẽ dung lượng `lib/` <= 2048 KB.

## Acceptance Criteria

- [x] `AppLovinAdapter` có phương thức `recoverInlineAdsAfterReconnect()`.
- [x] Khi mạng phục hồi, các banner/MREC AppLovin có `needsRecovery == true` được tự động nạp lại ngay lập tức.
- [x] Các banner/MREC đã nạp thành công hoặc đang nạp không bị nạp trùng.
- [x] `AdManager._onConnectivityChanged` kích hoạt phục hồi cho cả AdMob và AppLovin.
- [x] Unit test cho `AppLovinAdapter.recoverInlineAdsAfterReconnect` và `AdManager reconnect wiring` pass 100% (`test/t272_applovin_inline_recovery_after_reconnect_test.dart`).
- [x] Full SDK test suite pass, analyzer sạch 0 issue.
- [x] Release gate `./tool/release_readiness_gate.sh all` pass; dung lượng `lib/` giữ đúng 2048 KB.
