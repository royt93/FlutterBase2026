# T171 — Cấu hình sai (0 hoặc số âm) làm tính năng tự động chạy sai âm thầm

**Loại:** enhancement
**Ưu tiên:** P2
**Trạng thái:** todo
**Nguồn phát hiện:** codex
**Quyết định chủ dự án (2026-09-08):** Sửa ngay

## Vấn đề (giải thích thực tế)
Một số con số cấu hình cho các tính năng tự động (VD "tự đổi mạng quảng cáo khi lỗi nhiều lần") không được kiểm tra hợp lệ — nếu dev lỡ điền số 0 hoặc số âm, tính năng có thể tự đổi mạng quảng cáo ngay cả khi chưa có lỗi gì xảy ra. Chỉ xảy ra nếu dev cấu hình sai.

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/monetization/provider_failover_advisor.dart:49` — `consecutiveFailureThreshold <= 0` làm advisor đề xuất failover ngay cả khi chưa có failure.
- `packages/ad_sdk/lib/src/monetization/waterfall_tuner.dart:74` — `rollingWindowSize <= 0` gây hành vi không xác định.
- `packages/ad_sdk/lib/src/compliance/incident_recorder.dart:67` — tham số kích thước tương tự chưa được bảo vệ.

## Việc cần làm
1. Thêm `assert()` (debug mode) hoặc validate + log cảnh báo (release mode) tại constructor/setter của 3 class này khi giá trị `<=0` được truyền vào.
2. Quyết định hành vi khi giá trị không hợp lệ: dùng giá trị mặc định an toàn thay thế + log warning (khuyến nghị, không throw để tránh crash app ở production).
3. Viết test cho cả 3 class với giá trị 0/âm.
4. Cập nhật CHANGELOG.md.

## Prompt để chạy loop-fix
```
Thêm validate cho tham số cấu hình tại 3 chỗ: packages/ad_sdk/lib/src/monetization/provider_failover_advisor.dart dòng ~49 (consecutiveFailureThreshold), packages/ad_sdk/lib/src/monetization/waterfall_tuner.dart dòng ~74 (rollingWindowSize), packages/ad_sdk/lib/src/compliance/incident_recorder.dart dòng ~67 (tham số kích thước tương tự). Với mỗi tham số: nếu giá trị <=0, log cảnh báo qua SafeLogger VÀ dùng giá trị mặc định an toàn thay thế (không throw ở production, tránh crash app vì lỗi cấu hình của dev) — chọn giá trị mặc định hợp lý dựa vào giá trị default hiện có của class. Viết unit test cho cả 3 class: truyền 0 và số âm, xác nhận có log cảnh báo và class vẫn hoạt động với giá trị mặc định an toàn thay vì crash hoặc chạy sai.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Unit test cho cả 3 class với giá trị 0/âm.
3. Log SafeLogger đầy đủ + CHANGELOG.md cập nhật.
4. Audit độc lập, chấm điểm /10.
5. ≤9/10: sửa tiếp, quay lại bước 1.
6. >9/10: smoke test thật trên device, cấu hình cố ý sai (0/âm) qua demo, xác nhận có log cảnh báo và app không crash/chạy sai.
7. Thành công: commit + push. Thất bại: quay lại bước 1.
