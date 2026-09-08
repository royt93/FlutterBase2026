# T180 — Dọn gọn 6 đoạn code bật/tắt tính năng gần giống hệt nhau

**Loại:** enhancement (dọn code, không phải bug)
**Ưu tiên:** P3
**Trạng thái:** todo
**Nguồn phát hiện:** subagent core+state
**Quyết định chủ dự án (2026-09-08):** Dọn gọn lại

## Vấn đề (giải thích thực tế)
Có 6 đoạn code gần giống hệt nhau (bật/tắt 6 tính năng tự động khác nhau: arbitrator, fillRateMonitor, waterfallTuner, providerFailoverAdvisor, selfHealingObserver, journeyPrefetcher) — gộp lại thành 1 đoạn dùng chung sẽ bớt ~150 dòng code trùng lặp. Không phải lỗi, chỉ là dọn code cho gọn, không ảnh hưởng người dùng.

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/core/ad_manager.dart:718-904` — 6 cặp `enable*/disable*` gần như giống hệt nhau ("dispose cũ, gán mới").

## Việc cần làm
1. Đọc kỹ cả 6 cặp `enable*/disable*` để xác nhận chúng THỰC SỰ giống hệt nhau về pattern (không có khác biệt tinh vi nào giữa các cặp — nếu có khác biệt, KHÔNG gộp phần đó).
2. Viết 1 helper generic (dùng generic type hoặc callback) áp dụng cho cả 6, thay thế 6 cặp hàm cũ bằng cách gọi helper.
3. Chạy lại TOÀN BỘ test hiện có liên quan tới 6 tính năng này để đảm bảo không có hành vi nào bị đổi khi refactor (đây là rủi ro chính của việc "dọn code cho gọn" — đụng vào code đang chạy đúng).
4. Cập nhật CHANGELOG.md (ghi rõ đây là refactor nội bộ, không đổi hành vi/API công khai).

## Prompt để chạy loop-fix
```
Đọc kỹ packages/ad_sdk/lib/src/core/ad_manager.dart dòng ~718-904: 6 cặp enable*/disable* (arbitrator, fillRateMonitor, waterfallTuner, providerFailoverAdvisor, selfHealingObserver, journeyPrefetcher) có pattern gần giống hệt nhau ("dispose cũ, gán mới"). Xác nhận chúng THỰC SỰ giống hệt về logic (không có khác biệt tinh vi giữa các cặp) trước khi gộp — nếu phát hiện khác biệt dù nhỏ, giữ nguyên cặp đó riêng, chỉ gộp những cặp thực sự giống hệt. Viết 1 helper chung (generic hoặc callback-based) thay thế các cặp giống nhau. Chạy lại toàn bộ test liên quan tới cả 6 tính năng này (grep tên class trong test/) để xác nhận không có hành vi nào bị đổi. KHÔNG đổi API công khai (enable*/disable* vẫn giữ nguyên tên/signature, chỉ đổi implementation bên trong).
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh — đặc biệt toàn bộ test hiện có của 6 tính năng liên quan phải xanh không đổi.
2. Không thêm test mới bắt buộc (đây là refactor giữ nguyên hành vi) nhưng nếu phát hiện gap coverage trong lúc đọc, có thể bổ sung.
3. CHANGELOG.md cập nhật (refactor nội bộ).
4. Audit độc lập — đặc biệt kiểm tra kỹ KHÔNG có hành vi nào bị đổi giữa 6 tính năng — chấm điểm /10.
5. ≤9/10: sửa tiếp, quay lại bước 1.
6. >9/10: smoke test thật trên device, bật/tắt cả 6 tính năng qua demo có sẵn, xác nhận hành vi giống hệt trước khi refactor.
7. Thành công: commit + push. Thất bại: quay lại bước 1.
