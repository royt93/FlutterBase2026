# T177 — Công cụ dự đoán doanh thu hiểu nhầm số âm là "không giới hạn"

**Loại:** bug/enhancement (API contract chưa rõ ràng)
**Ưu tiên:** P2
**Trạng thái:** todo
**Nguồn phát hiện:** subagent vip+monetization
**Quyết định chủ dự án (2026-09-08):** Sửa + ghi rõ tài liệu

## Vấn đề (giải thích thực tế)
Công cụ "dự đoán doanh thu nếu đổi giới hạn số quảng cáo/ngày" (`MonetizationDigitalTwin.forecastDailyCap`) — nếu dev lỡ nhập số âm, công cụ âm thầm hiểu là "không giới hạn" thay vì báo lỗi. Đây chỉ là công cụ xem trước nội bộ, không ảnh hưởng quảng cáo thật, nhưng dev có thể hiểu nhầm kết quả dự đoán.

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/monetization/digital_twin.dart:158-160` (`forecastDailyCap`) — `hypotheticalDailyCap < 0` được xử lý như "không giới hạn" (`wouldShow = day.shown`), không được doc comment nhắc tới, không có test cho giá trị âm.

## Việc cần làm
1. Quyết định hành vi rõ ràng: hoặc (a) `assert(hypotheticalDailyCap >= 0)` để chặn giá trị âm ngay từ input, hoặc (b) giữ hành vi "âm = không giới hạn" nhưng ghi rõ thành API contract chính thức trong docstring.
2. Áp dụng lựa chọn đã chọn, viết test tương ứng (test throw nếu chọn (a), hoặc test xác nhận hành vi "không giới hạn" nếu chọn (b)).
3. Cập nhật CHANGELOG.md và docstring.

## Prompt để chạy loop-fix
```
Sửa packages/ad_sdk/lib/src/monetization/digital_twin.dart: forecastDailyCap (dòng ~158-160) xử lý hypotheticalDailyCap < 0 như "không giới hạn" mà không document rõ. Quyết định: thêm assert(hypotheticalDailyCap >= 0, '...') để chặn giá trị âm ngay từ input (khuyến nghị — an toàn hơn cho công cụ debug, tránh dev hiểu nhầm kết quả). Viết docstring rõ ràng giải thích contract mới. Viết unit test: gọi forecastDailyCap với giá trị âm, xác nhận assert throw đúng thông báo rõ ràng (trong debug mode); giá trị 0 và dương vẫn hoạt động như cũ.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Unit test cho giá trị âm (throw rõ ràng) + giá trị 0/dương (không breaking).
3. Docstring + CHANGELOG.md cập nhật.
4. Audit độc lập, chấm điểm /10.
5. ≤9/10: sửa tiếp, quay lại bước 1.
6. >9/10: smoke test thật trên device qua debug overlay có dùng công cụ này, xác nhận không crash khi test tay các giá trị bình thường.
7. Thành công: commit + push. Thất bại: quay lại bước 1.
