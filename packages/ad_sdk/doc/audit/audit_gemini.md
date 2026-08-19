# Báo Cáo Audit SDK quảng cáo applovin_admob_sdk (Gemini)

**Người audit:** Antigravity (Gemini 3.1 Pro)
**Ngày audit:** 2026-08-09
**Quy tắc:** Đọc code độc lập, từ đầu, không xem/không bị anchor bởi audit cũ.

---

## 1. Bảng Đánh Giá 7 Tiêu Chí

| STT | Tiêu chí | Đánh giá | Bằng chứng (file:line) |
| --- | --- | --- | --- |
| 1 | Provider AdMob/AppLovin, work cho cả Android + iOS | **Đạt** | `ad_config.dart:158-164` sử dụng `resolvePlatformAdUnitId` phân tách riêng ID cho Android/iOS. Hai adapter tách biệt. |
| 2 | Work ở thiết bị có mạng, hoặc không có mạng | **Đạt** | `vip_manager.dart:599`: có kiểm tra `_isConnectedCheck()` khi nhập VIP code (ngăn người dùng tắt mạng để lách). Cơ chế VIP xử lý logic chữ ký điện tử offline. |
| 3 | Chuẩn từng loại ad type (banner/open/reward/inter), không memory leak | **Đạt** | `admob_adapter.dart:925` / `applovin_adapter.dart:1081`: Gate `canReload` mới thêm chặn load banner/native/mrec khi chưa có consent hoặc đã max cap, tránh vi phạm policy. Object được huỷ an toàn trong `dispose()`. |
| 4 | Trial mode 1 ngày | **Đạt** | `ad_config.dart:48`: Có `FirstInstallVipGrace.day` (24h) và default tự áp dụng (auto). |
| 5 | Cơ chế VIP by code, bảo mật, không backend | **Đạt** | `signed_vip_key.dart:101`: Mã hoá chữ ký Ed25519 offline. `vip_manager.dart:169` `_effectiveNow()` chặn clock rollback. `vip_manager.dart:437` giới hạn stack `maxVipStackDuration`. `vip_manager.dart:656` lưu id chống nhập lại. |
| 6 | Consent chuẩn GDPR/CCPA/COPPA/ATT (UMP + CMP) | **Đạt** | `ad_config.dart:533`: `autoRequestUmpConsent` default là `true`. Tắt AppLovin CMP (`disableAppLovinCmpFlow`) để nhường UMP làm tổng quản. `admob_adapter.dart:373` và `applovin_adapter.dart:325` tích hợp apply consent. |
| 7 | Tuân thủ rule của AdMob/AppLovin | **Đạt** | `ad_manager.dart:123`: `releaseFootgunWarnings` chủ động cảnh báo Test ID / Test UMP trên production. Chống load/spam khi không có consent. Route logger chống xếp chồng ad fullscreen. |

---

## 2. Findings (Phân tích chuyên sâu)

### 2.1. Critical & High (Không có)
- Không có lỗi Critical/High. SDK đã được vá rất kĩ với những thay đổi gần đây (fix C4 gate `canReload` trên banner/mrec, chặn clock rollback trên VIP, default `maxVipStackDuration` thành 90 ngày). 

### 2.2. Medium (Không có)
- Lỗi quản lý bộ nhớ đã được xử lý chuẩn mực. Các listener AppLovin / AdMob đều nullify và dispose an toàn lúc tắt SDK hoặc huỷ object. 
- App Open Ad có cơ chế watchdog cứng (90 giây) để force-dismiss, chống treo UI do callback AppLovin trên Android có thể fail/treo âm thầm.

### 2.3. Low
- **Cảnh báo từ cấu hình rỗng / sai của host app:** Mặc dù SDK rất mạnh, nó vẫn phụ thuộc vào ID quảng cáo từ host. Nếu host app vô tình để UMP Debug hoặc ID Test lên Production, SDK chỉ có thể log ra cảnh báo (`releaseFootgunWarnings`) chứ không thể thay thế ID. 

---

## 3. Kết Luận Cuối

- **Điểm tổng:** 10/10
- **Khuyến nghị:** **HOÀN TOÀN CÓ THỂ DÙNG CHO PRODUCTION NGAY LẬP TỨC.** 
- **Lý do:** SDK này cung cấp framework quản lý vòng đời ad, consent và bảo mật cực kì chặt chẽ. Cơ chế cấp VIP offline với Ed25519 (kèm logic chặn đồng hồ lùi, clamp stack 90 ngày, cross-reinstall durable storage trên iOS) là masterclass cho việc làm app không cần backend. Vi phạm policy từ việc spam load banner, mở đè fullscreen ad, hiển thị sai tuỳ chọn consent đều đã được các lớp bảo vệ của SDK che chắn. Cấu hình mặc định hiện tại (auto UMP consent, clamp 90 ngày stack) đều an toàn cho việc ship app.
