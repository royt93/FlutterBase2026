# T24 — Real-time policy risk score

- **REQ:** 7 (policy tuân thủ AdMob/AppLovin) + epic "Trust & Analytics"
- **Priority:** P1 · **Severity:** — (feature mới) · **Status:** ✅ done (2026-07-08)
- **Nguồn:** quyết định user 2026-07-08
- **Phụ thuộc:** dùng `AdSafetyConfig.getStatusSnapshot()` mới từ T23 — nên làm sau T23 (không bắt buộc, nhưng tránh 2 PR đụng cùng file).
- **Files dự kiến:** `packages/ad_sdk/lib/src/core/ad_safety_config.dart` (thêm hàm tính score, không đổi hàm cũ), `packages/ad_sdk/lib/src/core/ad_manager.dart` (expose reactive `policyRiskScore`)

## Vấn đề (Why)

`AdSafetyConfig` đã track đủ tín hiệu rủi ro (CTR gần ngưỡng, số lần suspicious pause, rapid-resume, click spam) nhưng chỉ dùng nội bộ để **chặn** (`canShowFullscreenAd()` trả false) — partner không thấy được "mình đang ở mức rủi ro nào" cho tới khi bị chặn hẳn, và hoàn toàn không biết account đang tiệm cận một policy strike thật từ Google/AppLovin (2 hệ thống đó không liên quan trực tiếp tới cap nội bộ của SDK, nhưng hành vi user gây suspicious pause nội bộ thường là cùng loại hành vi khiến network ngoài flag account).

## Fix đề xuất

Thêm `AdSafetyConfig._computeRiskScore()` (0-100, không cần ML — trọng số tuyến tính đơn giản, đủ dùng, tránh over-engineer):
- CTR hiện tại / ngưỡng `suspiciousCtrThreshold` → trọng số cao nhất (dấu hiệu invalid-click rõ nhất trong mắt Google).
- `_suspiciousViolationCount` (lịch sử vi phạm) → trọng số trung bình, decay dần theo thời gian kể từ vi phạm gần nhất (không cần phức tạp — ví dụ giảm nửa điểm sau mỗi 24h không vi phạm mới, dùng lại đúng logic decay đã có ở `_triggerSuspiciousPause`).
- `_resumeTimestamps.length` / `maxRapidResumesPerMinute` → trọng số thấp (thường false-positive nhiều hơn, ví dụ user thật sự alt-tab nhanh).

Expose qua `AdManager().policyRiskScore` — reactive `RxInt`/`ValueListenable` giống pattern `activeListenable` của VIP đã có, để host app tự quyết định hiển thị cảnh báo debug/dashboard (không tự ý show alert cho end-user — end-user không cần biết risk score, đây là tín hiệu cho dev/partner).

## Acceptance criteria
- [x] `_computeRiskScore()` trả 0-100, đơn điệu tăng khi CTR/violations/resume-spam tăng (test bằng cách giả lập từng tín hiệu tăng dần, verify score không giảm).
- [x] Không đổi behavior `canShowFullscreenAd()`/`getStatus()` cũ — chỉ thêm, không sửa.
- [x] `policyRiskScore` cập nhật đúng sau mỗi `recordAdClick`/`recordAdImpression`/suspicious pause.
- [x] Test mới cho các mốc điểm (thấp/trung bình/cao) ứng với input giả lập cụ thể.
- [x] `flutter analyze` sạch, test SDK xanh.
