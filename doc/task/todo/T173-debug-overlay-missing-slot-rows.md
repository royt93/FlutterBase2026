# T173 — Màn hình debug thiếu thông tin cho banner/MREC/native

**Loại:** enhancement
**Ưu tiên:** P2
**Trạng thái:** todo
**Nguồn phát hiện:** subagent widget+utils+config
**Quyết định chủ dự án (2026-09-08):** Sửa ngay

## Vấn đề (giải thích thực tế)
Màn hình debug nội bộ (chỉ dev thấy) đang thiếu dòng hiển thị trạng thái cho 3/6 loại quảng cáo (banner/MREC/native) — dev khó chẩn đoán khi 3 loại này không lên quảng cáo, vì chỉ có thông tin cho AppOpen/Interstitial/Rewarded.

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/widget/debug_ad_overlay.dart:171-199` (`_SlotRows`) — chỉ hiện state AppOpen/Interstitial/Rewarded, không có dòng tổng hợp cho banner/mrec/native dù các adapter đã track per-instance bundle (`adapter.native(key)`, v.v.).

## Việc cần làm
1. Thêm dòng hiển thị trạng thái cho banner/MREC/native vào `_SlotRows` — tận dụng dữ liệu adapter đã có sẵn (`adapter.native(key)` và tương đương cho banner/mrec).
2. Xử lý hiển thị hợp lý khi có NHIỀU instance banner/mrec/native cùng lúc (khác AppOpen/Interstitial/Rewarded chỉ có 1 instance) — có thể liệt kê theo key hoặc tổng hợp số lượng theo trạng thái.
3. Viết widget test cho overlay hiển thị đúng khi có banner/mrec/native ở nhiều trạng thái khác nhau.
4. Cập nhật CHANGELOG.md.

## Prompt để chạy loop-fix
```
Sửa packages/ad_sdk/lib/src/widget/debug_ad_overlay.dart: _SlotRows (dòng ~171-199) chỉ hiện AppOpen/Interstitial/Rewarded, thiếu banner/MREC/native. Đọc cách adapter track per-instance bundle cho banner/mrec/native (VD adapter.native(key)) để lấy đúng dữ liệu trạng thái. Thêm dòng hiển thị cho 3 loại này — vì có thể có nhiều instance cùng lúc (khác AppOpen/Interstitial/Rewarded chỉ 1 instance), thiết kế hiển thị hợp lý (liệt kê theo key, hoặc tổng hợp đếm theo trạng thái loaded/error/loading). Viết widget test cho overlay với nhiều banner/mrec/native ở trạng thái khác nhau.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. Widget test cho overlay hiển thị đúng banner/mrec/native ở nhiều trạng thái.
3. CHANGELOG.md cập nhật.
4. Audit độc lập, chấm điểm /10.
5. ≤9/10: sửa tiếp, quay lại bước 1.
6. >9/10: smoke test thật trên device, mở debug overlay khi có banner/mrec/native đang chạy, chụp bằng chứng hiển thị đủ thông tin.
7. Thành công: commit + push. Thất bại: quay lại bước 1.
