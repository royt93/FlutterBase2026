# T79 — `AdEventLog.inRange` dùng `1 << 62` có rủi ro tràn/mất chính xác nếu compile Web/Wasm

- **REQ:** audit round mới 2026-08-15 (claude subagent)
- **Priority:** P2 · **Status:** ✅ done
- **Files:** `packages/ad_sdk/lib/src/compliance/ad_event_log.dart:104`

## Vấn đề (Why)
`1 << 62` dùng làm cận trên mặc định cho `toMs`. Nếu package sau này mở rộng biên dịch sang Web/Wasm, số nguyên Dart tuân theo giới hạn 53-bit của JavaScript, giá trị này có thể tràn/mất chính xác. Hiện tại chỉ target Android/iOS nên chưa phải vấn đề thật, nhưng là rủi ro tương lai rẻ để phòng trước.

## Đề xuất
Thay bằng hằng số an toàn trong ngưỡng 53-bit, hoặc dùng sentinel kiểu khác (vd `null` = không giới hạn) thay vì bit-shift trực tiếp.

## Acceptance criteria
- [x] Hằng số mới không đổi hành vi hiện tại (Android/iOS), an toàn nếu build target mở rộng sau này.

## Đã làm (2026-08-16)
Thay `(1 << 62)` bằng hằng số đặt tên `_maxSafeIntegerMs = 9007199254740991` (2^53 - 1, giới hạn số nguyên chính xác của JS `Number`). Grep xác nhận đây là chỗ DUY NHẤT trong `lib/` dùng pattern bit-shift lớn tương tự — không có chỗ nào khác cần sửa.

Test: thêm 1 test mới xác nhận timestamp thời điểm hiện tại thật (`DateTime.now()`) vẫn nằm trong range khi dùng sentinel mới (nhỏ hơn `1 << 62` cũ nhưng vẫn đủ lớn cho mọi timestamp thực tế).

`flutter test`: 749/749 pass, `flutter analyze` sạch.
