# T159 — Giới hạn số quảng cáo/ngày không lấy mức chặt nhất khi cài 2 giới hạn cùng lúc

**Loại:** bug
**Ưu tiên:** P2
**Trạng thái:** todo
**Nguồn phát hiện:** subagent core+state
**Quyết định chủ dự án (2026-09-08):** Sửa ngay

## Vấn đề (giải thích thực tế)
Mỗi vị trí hiển thị quảng cáo có thể cài 2 loại giới hạn số lần/ngày cùng lúc (`maxPerPlacementAdsPerDay` và `maxPerPlacementAdsPerDayById`). Đúng ra phải áp dụng giới hạn CHẶT HƠN trong 2 cái (đúng như docstring "checked in ADDITION to"), nhưng hệ thống chỉ áp dụng giới hạn nào được cài trước (dùng `??` short-circuit), bỏ qua cái còn lại. Hậu quả: nếu dev muốn siết thêm giới hạn cho 1 vị trí cụ thể, cái siết thêm đó có thể bị lờ đi, người dùng thấy quảng cáo nhiều hơn dự tính.

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/core/ad_safety_config.dart:535-537` — `placementDailyCapReached` dùng `??` giữa `maxPerPlacementAdsPerDay` và `maxPerPlacementAdsPerDayById`: chỉ map có entry đầu tiên thắng, không lấy `min()` của cả 2 khi cả 2 đều set khác giá trị cho cùng placement.

## Việc cần làm
1. Sửa logic để lấy `min()` của 2 giá trị khi cả 2 map đều có entry cho cùng placement (thay vì `??` short-circuit).
2. Viết test: cả 2 map cùng set khác giá trị cho 1 placement (VD map A = 10, map B = 5) — xác nhận giới hạn áp dụng là 5 (chặt hơn).
3. Cập nhật docstring cho rõ ràng hành vi "lấy min của cả 2".
4. Cập nhật CHANGELOG.md.

## Prompt để chạy loop-fix
```
Sửa packages/ad_sdk/lib/src/core/ad_safety_config.dart dòng ~535-537: placementDailyCapReached hiện dùng ?? giữa maxPerPlacementAdsPerDay và maxPerPlacementAdsPerDayById, chỉ map có entry trước thắng — trái với docstring "checked in ADDITION to". Sửa để khi cả 2 map đều có entry cho cùng placement, lấy giá trị nhỏ hơn (min) làm giới hạn áp dụng thật. Viết unit test: set cả 2 map khác giá trị cho cùng placement, xác nhận giới hạn hiệu lực là giá trị nhỏ hơn; test case chỉ 1 map có entry vẫn hoạt động như cũ (không breaking).
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Unit test cho case cả 2 map cùng set (lấy min), và case chỉ 1 map set (không breaking).
3. Docstring + CHANGELOG.md cập nhật.
4. Audit độc lập, chấm điểm /10.
5. ≤9/10: sửa tiếp, quay lại bước 1.
6. >9/10: smoke test thật trên device, cấu hình cả 2 giới hạn khác nhau cho 1 placement, xác nhận quảng cáo dừng đúng ở mức chặt hơn.
7. Thành công: commit + push. Thất bại: quay lại bước 1.
