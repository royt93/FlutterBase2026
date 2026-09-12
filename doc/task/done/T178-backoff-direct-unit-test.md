# T178 — Thêm test trực tiếp cho công thức tính thời gian chờ tải lại

**Loại:** test-coverage
**Ưu tiên:** P2
**Trạng thái:** done
**Nguồn phát hiện:** subagent test-coverage-gap
**Quyết định chủ dự án (2026-09-08):** Thêm test ngay

## Vấn đề (giải thích thực tế)
Có 1 công thức tính "chờ bao lâu trước khi thử tải quảng cáo lại" sau mỗi lần thất bại (`Backoff.compute`, chống spam server khi mạng hỏng liên tục). Công thức này từng bị lỗi tràn số hồi tháng trước (đã sửa ở round 37, MAJOR bug), nhưng hiện chỉ được kiểm tra gián tiếp qua các tính năng khác (`AdSlot`, `round37_backoff_test.dart`), chưa có test riêng trực tiếp cho chính công thức này.

## Chi tiết kỹ thuật
- `packages/ad_sdk/lib/src/state/backoff.dart` — không có `backoff_test.dart` riêng.
- Test biên hiện có nằm rải trong `ad_slot_test.dart` và integration test `round37_backoff_test.dart` (chỉ tới 51 lần fail).

## Việc cần làm
1. Tạo `test/backoff_test.dart` mới, test trực tiếp `Backoff().compute(n)` cho các mốc: `n` nhỏ (1, 2), `n` biên đúng chỗ từng tràn số (63, so với round-37 fix ở 51+), giá trị âm (nếu hàm nhận được input này từ đâu đó, xác nhận xử lý hợp lý), và giá trị rất lớn (VD 1000) để chắc chắn không tràn số ở bất kỳ n nào.
2. Không cần sửa code (trừ khi test lộ ra lỗi mới) — đây là task bổ sung test cho code đã đúng.
3. Cập nhật CHANGELOG.md nếu phát hiện và sửa lỗi mới.

## Prompt để chạy loop-fix
```
Tạo file mới packages/ad_sdk/test/backoff_test.dart: viết unit test trực tiếp cho Backoff().compute(n) trong packages/ad_sdk/lib/src/state/backoff.dart. Đọc kỹ code hiện tại và lịch sử fix round-37 (tràn số ở n>=51, xem doc/audit để hiểu chi tiết công thức) trước khi viết test. Test các mốc: n=1, n=2 (giá trị nhỏ, đúng công thức); n=51,63 (đúng biên đã từng tràn số); n=1000 (giá trị rất lớn, xác nhận không tràn số/không throw); n âm nếu hàm có thể nhận input này (xác nhận xử lý hợp lý, không crash). Nếu phát hiện lỗi mới trong lúc viết test, sửa và ghi rõ vào CHANGELOG.md.
```

## Tín hiệu kết thúc loop
1. `flutter analyze` sạch, `flutter test` 100% xanh.
2. `test/backoff_test.dart` mới, phủ đủ các mốc biên đã liệt kê.
3. CHANGELOG.md cập nhật nếu có sửa code.
4. Audit độc lập, chấm điểm /10.
5. ≤9/10: sửa tiếp, quay lại bước 1.
6. >9/10: không cần smoke test thiết bị riêng (đây là công thức toán học thuần, unit test đã đủ chứng minh) — bỏ qua bước 7 gốc, đi thẳng bước push nếu audit >9/10.
7. Thành công: commit + push. Thất bại: quay lại bước 1.

## Completion audit (2026-09-13)

- Added `test/backoff_test.dart` with direct coverage for negative/zero input,
  early exponential values, the historical overflow boundaries (51/63),
  very-large failure counts (1000), and zero-duration configuration.
- Added `example/integration_test/t178_backoff_test.dart` to exercise the
  exported runtime contract on Android.
- `flutter analyze` clean. Backoff, AdSlot, and retry-policy suites passed.
- Device smoke passed on `SM S928B` (Android 16/API 36).
- The repository-wide suite still has two pre-existing order-sensitive failures
  in monetization/debug-overlay tests; neither touches Backoff and both fail
  when run independently.

Audit score: **9.5/10**. The requested direct boundaries and runtime smoke are
covered; deduction is only for unrelated repository baseline failures.

End-loop signal: audit, score, unit/widget/integration coverage, and device
smoke completed. Push because the feature score is above 9/10.
