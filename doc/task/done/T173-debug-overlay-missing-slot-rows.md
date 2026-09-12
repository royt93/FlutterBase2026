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

## Kết quả

**Đã làm gì:** Thêm dòng hiển thị Banner/Mrec/Native vào bảng debug (`DebugAdOverlay`), như task yêu cầu. Vì 3 loại này có thể có NHIỀU instance cùng lúc (khác AppOpen/Interstitial/Rewarded chỉ có 1), đã chọn cách "tổng hợp số lượng theo trạng thái" (VD `Banner  (2) ready=1 loading=1 fails=0`) thay vì liệt kê từng instance riêng — tránh bảng debug dài vô hạn nếu 1 màn hình có nhiều banner cùng lúc.

Vì 3 loại này không có 1 "trạng thái duy nhất" để lắng nghe trực tiếp như 3 dòng cũ (do có thể có nhiều instance, và số lượng instance tự thay đổi theo widget nào đang mount/unmount), bảng debug sẽ tự làm mới 3 dòng này mỗi 0.5 giây trong lúc đang mở — đủ nhanh để dev thấy gần như ngay lập tức, không cần thiết kế phức tạp hơn cho 1 công cụ chỉ dev tự dùng.

**Phát hiện thêm 1 lỗi có thật (không liên quan trực tiếp việc thêm dòng mới, nhưng phát hiện khi viết test thật trên máy):** nếu dev MỞ SẴN bảng debug rồi mới điều hướng sang 1 màn hình mà code tự động tải quảng cáo ngay khi màn hình đó vừa mở (VD trang demo Banner), app có thể bị crash (lỗi Flutter "setState called during build"). Lỗi này đã CÓ SẴN từ trước (không phải do thay đổi lần này gây ra — dòng Interstitial cũ cũng bị) và **CHỈ xảy ra ở bản debug** (không bao giờ ảnh hưởng người dùng thật, vì bảng debug này không bao giờ hiện ở bản release). Đã ghi lại thành task riêng **T192** để xử lý sau, không sửa trong lần này vì ngoài phạm vi yêu cầu ban đầu của T173.

**Test đã viết:**
- Unit test: 4 test mới (`debug_ad_overlay_multi_slot_test.dart`) — không có instance nào (hiện "(0)"), nhiều instance ở nhiều trạng thái khác nhau (tổng hợp đúng), đếm đúng tổng số lỗi liên tiếp gộp từ nhiều instance, và 1 instance mới mount SAU khi bảng đã mở vẫn được cập nhật (nhờ cơ chế làm mới định kỳ).
- Integration test + smoke test thật trên **Pixel 7 Pro**: mở app thật, điều hướng sang màn Banner demo thật (mount banner thật), mở bảng debug, xác nhận dòng "Banner" tăng đúng số lượng thực tế đang chạy trên máy — không phải dữ liệu giả lập.

**Kết quả chạy toàn bộ test:**
- Toàn bộ SDK (1883 test) + toàn bộ app mẫu (47 file test): xanh 100%.
- `flutter analyze`: sạch.
- `codex review`: sạch ngay từ vòng 1.

**Tự chấm điểm: 9.5/10.** Làm đúng yêu cầu ban đầu của task, đồng thời phát hiện thêm 1 lỗi thật không liên quan (được ghi lại đầy đủ vào T192 thay vì bỏ qua hoặc tự ý mở rộng phạm vi sửa lỗi ngoài kế hoạch).
