# T165 — Lệch ngày múi giờ giữa 2 công cụ theo dõi thống kê nội bộ

**Loại:** bug (chỉ ảnh hưởng báo cáo/cảnh báo nội bộ, không ảnh hưởng chống gian lận hay người dùng cuối)
**Ưu tiên:** P2
**Trạng thái:** todo
**Nguồn phát hiện:** subagent widget+utils+config + agy (2 nguồn độc lập, cùng file)
**Quyết định chủ dự án (2026-09-08):** Sửa ngay

## Vấn đề (giải thích thực tế)
Công cụ theo dõi "tỷ lệ lấp đầy quảng cáo theo ngày" dùng giờ địa phương của máy để tính "ngày nào" — trong khi bộ đếm giới hạn số quảng cáo/ngày (chống gian lận) dùng giờ quốc tế (UTC, đã kẹp high-water-mark chống chỉnh giờ lùi). Nếu người dùng đổi múi giờ (đi du lịch/đổi cài đặt đồng hồ), số liệu theo dõi "tỷ lệ lấp đầy" có thể bị lệch ngày so với thực tế — chỉ ảnh hưởng báo cáo/cảnh báo nội bộ, không ảnh hưởng chống gian lận hoặc người dùng cuối.

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/utils/ad_preferences.dart:612,677` — `_recordFillRateBaselineSampleNow`/`getFillRateBaselineHistory` dùng `DateTime.now()` (giờ local).
- `packages/ad_sdk/lib/src/utils/ad_preferences.dart:118` — `_todayUtcClamped` (đã vá round-31/37) dùng cho bộ đếm chống gian lận.
- `packages/ad_sdk/lib/src/monetization/fill_rate_baseline_monitor.dart:~146` — cùng vấn đề (agy tìm thấy).

## Việc cần làm
1. Đổi `_recordFillRateBaselineSampleNow`/`getFillRateBaselineHistory` và tương ứng trong `fill_rate_baseline_monitor.dart` sang dùng `_todayUtcClamped` (hoặc hàm UTC tương đương), đồng bộ với cách tính ngày của bộ đếm chống gian lận.
2. Viết test: đổi múi giờ mô phỏng quanh mốc nửa đêm, xác nhận baseline không bị tách/gộp nhầm ngày.
3. Cập nhật CHANGELOG.md.

## Prompt để chạy loop-fix
```
Sửa packages/ad_sdk/lib/src/utils/ad_preferences.dart: _recordFillRateBaselineSampleNow (dòng ~612) và getFillRateBaselineHistory (dòng ~677) đang dùng DateTime.now() (giờ local) để tính ngày, không nhất quán với _todayUtcClamped (dòng ~118, đã vá round-31/37 cho bộ đếm chống gian lận). Đổi cả 2 hàm sang dùng _todayUtcClamped. Kiểm tra thêm packages/ad_sdk/lib/src/monetization/fill_rate_baseline_monitor.dart (~dòng 146) có cùng vấn đề tương tự — sửa đồng bộ. Viết test mô phỏng đổi múi giờ quanh nửa đêm (dùng cùng kỹ thuật test đã có cho _todayUtcClamped), xác nhận baseline không bị lệch ngày.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Unit test mô phỏng đổi múi giờ cho cả 2 file, xác nhận đồng bộ cách tính ngày.
3. CHANGELOG.md cập nhật.
4. Audit độc lập, chấm điểm /10.
5. ≤9/10: sửa tiếp, quay lại bước 1.
6. >9/10: smoke test thật trên device, đổi múi giờ hệ thống, xác nhận số liệu debug overlay không bị lệch ngày bất thường.
7. Thành công: commit + push. Thất bại: quay lại bước 1.
