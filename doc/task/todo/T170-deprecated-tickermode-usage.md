# T170 — Banner/MREC dùng API Flutter đã cũ, sẽ bị loại bỏ trong tương lai

**Loại:** enhancement
**Ưu tiên:** P2
**Trạng thái:** todo
**Nguồn phát hiện:** codex
**Quyết định chủ dự án (2026-09-08):** Sửa ngay

## Vấn đề (giải thích thực tế)
2 khung quảng cáo (banner + MREC) đang gọi 1 hàm Flutter đã cũ (`TickerMode.of`), sẽ bị Flutter bỏ trong tương lai. Hiện chưa có ảnh hưởng gì, chỉ hiện cảnh báo khi kiểm tra code (`flutter analyze`, không ai thấy ngoài dev). Nếu không đổi, sau này nâng cấp Flutter phiên bản mới có thể SDK này bị lỗi không chạy được.

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/widget/banner_ad_widget.dart:289` và `packages/ad_sdk/lib/src/widget/mrec_ad_widget.dart:190` — dùng `TickerMode.of(context)`, API deprecated; `flutter analyze` trả đúng 2 cảnh báo `deprecated_member_use`.

## Việc cần làm
1. Chuyển sang `TickerMode.valuesOf` (API migration chính thức của Flutter) tại cả 2 vị trí.
2. Xác nhận `flutter analyze` hết cảnh báo `deprecated_member_use` liên quan.
3. Test hồi quy: hành vi tạm dừng animation/refresh khi `TickerMode` tắt (VD trong `IndexedStack` tab ẩn) vẫn hoạt động đúng như trước.
4. Cập nhật CHANGELOG.md.

## Prompt để chạy loop-fix
```
Sửa packages/ad_sdk/lib/src/widget/banner_ad_widget.dart dòng ~289 và packages/ad_sdk/lib/src/widget/mrec_ad_widget.dart dòng ~190: đang dùng TickerMode.of(context) đã deprecated. Đổi sang TickerMode.valuesOf(context) theo đúng migration guide chính thức của Flutter (kiểm tra API signature khác biệt, có thể trả về record/tuple thay vì bool đơn). Chạy flutter analyze xác nhận hết cảnh báo deprecated_member_use liên quan đến TickerMode. Chạy lại toàn bộ test hiện có của 2 widget để xác nhận không breaking hành vi tạm dừng khi TickerMode tắt.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch (không còn cảnh báo `TickerMode` deprecated), `flutter test` 100% xanh.
2. Test hồi quy cho hành vi TickerMode tắt/bật vẫn đúng.
3. CHANGELOG.md cập nhật.
4. Audit độc lập, chấm điểm /10.
5. ≤9/10: sửa tiếp, quay lại bước 1.
6. >9/10: smoke test thật trên device, banner/MREC trong tab `IndexedStack` ẩn/hiện, xác nhận hành vi animation/refresh không đổi.
7. Thành công: commit + push. Thất bại: quay lại bước 1.
