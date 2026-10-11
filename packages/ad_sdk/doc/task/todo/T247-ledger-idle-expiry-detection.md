# T247 — Phát hiện revenue gap dù app idle

- **Loại:** Enhancement
- **Priority:** P2 · **Effort:** M
- **Confidence:** CONFIRMED limitation, not confirmed loss of correctness
- **Status:** todo
- **Evidence:** `lib/src/monetization/revenue_integrity_ledger.dart:36-46,72-73,149-160`; `test/revenue_integrity_ledger_test.dart`
- **Dependency:** none

## Giá trị

`RevenueIntegrityLedger` chỉ gọi `_sweepExpired()` khi nhận event mới. Nếu app im lặng sau show không có revenue callback, cảnh báo chỉ xuất hiện khi event khác đến; `dispose()` thì xoá pending entries. Đây là giới hạn đã ghi rõ, không phải bằng chứng mất doanh thu. Tạo tùy chọn/thiết kế timer chỉ khi cần cảnh báo đúng hạn trong app idle.

## Phạm vi

- Đánh giá timer đến hạn sớm nhất hoặc cơ chế polling tối thiểu; không thêm timer lặp vô hạn nếu không cần.
- Giữ nguyên match chính xác theo `requestId`, fallback FIFO hiện tại, và semantics `dispose()`.
- Xác nhận `matchWindow <= 0`, nhiều pending show, callback đến sát hạn, event trễ, và clock injection.

## Acceptance criteria

- [ ] Unit: cảnh báo phát sinh khi app idle qua hết `matchWindow`, không cần event kế tiếp.
- [ ] Unit: revenue callback trước hạn huỷ/đóng đúng lịch; callback sau hạn không xoá cảnh báo đã ghi.
- [ ] Unit: nhiều pending entries chỉ tạo lịch cần thiết; dispose huỷ timer và không ghi incident sau teardown.
- [ ] Widget test: N/A — class không có UI; giải thích trong kết quả.
- [ ] Integration Android/iOS: kiểm tra qua event stream giả trong host test harness; không khẳng định callback ad network native đã được chứng minh.
- [ ] Smoke test thiết bị: ghi nhận giới hạn đo thời gian nền/OS suspension; nếu không kiểm chứng được lịch nền thì ghi rõ, không tuyên bố timer chạy đúng khi app bị suspend.
- [ ] Audit độc lập toàn bộ diff, điểm >9/10; analyze và test liên quan pass.

## Prompt vòng lặp

Triển khai T247 theo TDD; đọc lại code/test và backlog liên quan trước khi sửa. Viết test đỏ cho idle expiry, matching trước/sau hạn, nhiều pending và dispose; chỉ chọn timer sau khi chứng minh semantics cần thiết. End loop: audit lại changes, chấm điểm /10, bổ sung unit + widget + integration cho mọi case (ghi rõ widget không áp dụng nếu vẫn không có UI), smoke test thiết bị và nêu giới hạn app background. Chỉ khi toàn bộ test/analyze pass và điểm >9/10 mới commit/push theo yêu cầu task; không mở rộng phạm vi.