# P24 — Gắn/sửa `roomTag` cho test cũ trong history

- **Priority:** P2 · **Severity:** — · **Status:** 🔲 todo
- **Nguồn:** subagent đọc source
- **Files:** `lib/mckimquyen/widget/wifi_stressor/presentation/room_comparison_screen.dart:32`, `history_screen.dart`, `widgets/room_tag_bottom_sheet.dart`

## Vấn đề / cơ hội
`room_comparison_screen.dart:32` hiện tự động bỏ qua (silently drop) mọi kết quả chưa gắn `roomTag`. Người dùng chỉ gắn được room tag lúc tạo test mới, không sửa/gắn lại được cho test cũ đã lưu trong history — làm giảm giá trị của mọi test đã chạy trước khi feature room-tag ra đời (và tiền đề cần cho P17, P30).

## Việc cần làm (đề xuất, chưa code)
- Thêm action "Gắn/Sửa phòng" trong `history_screen.dart` hoặc `test_detail_screen.dart` — mở lại `room_tag_bottom_sheet.dart` (đã tồn tại), lưu update vào `TestResult` đã lưu (dùng `copyWith`, chú ý bug về `copyWith` không clear-được-null đã ghi trong report subagent nếu liên quan).

## Acceptance criteria
- [ ] Có thể gắn/sửa room tag cho bất kỳ test đã lưu trong history.
- [ ] Test cũ được gắn tag mới xuất hiện đúng trong `room_comparison_screen.dart` (không còn bị filter bỏ).
