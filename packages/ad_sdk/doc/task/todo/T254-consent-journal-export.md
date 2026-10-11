# T254 — API opt-in để xem/xuất consent provenance timeline

- **Loại:** Idea / Product enhancement
- **Priority:** P3 · **Effort:** M
- **Confidence:** IDEA grounded in existing journal; host demand not verified
- **Status:** todo
- **Evidence:** `lib/src/compliance/consent_provenance_journal.dart`; `test/consent_provenance_journal_test.dart`; `AdManager` compliance export APIs; `README.md` privacy/compliance docs
- **Dependency:** Public API + SemVer review

## Ý tưởng & giá trị

SDK đã lưu lịch sử thay đổi consent có hash-chain, nhưng host cần tự ghép với các export khác để xem chronology. Một API read-only, opt-in để lấy/export timeline có thể giảm công sức support/audit. Bằng chứng chain lưu local không chứng minh nguồn gốc nếu không có external anchor; phải giữ cảnh báo này rõ.

## Phạm vi

- Phỏng vấn/use-case host trước khi thêm API public; nếu không có nhu cầu thật, ghi REFUTED.
- Nếu làm, expose dữ liệu tối thiểu, redaction rõ, không gửi network tự động; giữ `clearSdkData` và purge semantics.
- Không tạo UI dashboard riêng khi example diagnostic surface đủ.

## Acceptance criteria

- [ ] Use case và privacy review xác nhận dữ liệu nào cần export; không export identifier nhạy cảm mới.
- [ ] API/export read-only, deterministic, hỗ trợ pagination/size cap nếu payload có thể tăng; không phá API compatibility.
- [ ] Unit: timeline ordering, tamper indicator, empty/large history, redaction, erasure semantics.
- [ ] Widget test nếu có UI example; nếu chỉ API thuần thì ghi N/A.
- [ ] Android/iOS integration test persistence/export; smoke test device chứng minh export đọc được và verifier/chain nhận ra tampering.
- [ ] Docs nêu external anchoring requirement và không claim local chain là bằng chứng không thể giả mạo.
- [ ] Audit độc lập >9/10, API golden/changelog nếu public API thay đổi.

## Prompt vòng lặp

Triển khai T254 chỉ sau khi use case được xác thực; không bắt đầu bằng cách thêm public API. Đọc journal, dispute kit, redaction/erasure và public API policy. Nếu làm, test privacy, tamper, ordering, large history và erasure trước; không gửi dữ liệu ra mạng. End loop: audit changes + điểm /10, unit/widget/integration mọi case, smoke thiết bị và ghi rõ giới hạn external anchor; chỉ khi test/analyze pass và >9/10 mới commit/push theo yêu cầu task.