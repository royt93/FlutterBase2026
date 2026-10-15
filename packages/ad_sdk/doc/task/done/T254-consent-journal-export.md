# T254 — API opt-in để xem/xuất consent provenance timeline

- **Loại:** Idea / Product enhancement
- **Priority:** P3 · **Effort:** M
- **Confidence:** IDEA grounded in existing journal; owner selected bounded read pagination (not truncated export)
- **Status:** done (offset pagination implemented; tests/analyzer/API golden/full suite pass; independent audit 9.5/10)
- **Evidence:** `lib/src/compliance/consent_provenance_journal.dart`; `test/consent_provenance_journal_test.dart`; `AdManager` compliance export APIs; `README.md` privacy/compliance docs
- **Dependency:** Public API + SemVer review

## Ý tưởng & giá trị

SDK đã lưu lịch sử thay đổi consent có hash-chain, nhưng host cần tự ghép với các export khác để xem chronology. Một API read-only, opt-in để lấy/export timeline có thể giảm công sức support/audit. Bằng chứng chain lưu local không chứng minh nguồn gốc nếu không có external anchor; phải giữ cảnh báo này rõ.

## Phạm vi

- Owner chọn: pagination chỉ cho API đọc; signed export hiện hữu vẫn luôn chứa full history, không thêm range/truncate export.
- API mới read-only, offset + limit, oldest-first, immutable result; default page 100, maximum 500; invalid offset/limit throws `ArgumentError`.
- Không thêm dữ liệu/identifier; giữ nguyên `clearSdkData` purge semantics, không gửi network; không tạo UI dashboard.
- Privacy limitation: local hash chain detects internal inconsistency but does not establish origin or prevent tail truncation/forged rewrite without external anchor. Signed export protects bytes after export, not source identity.

## Acceptance criteria

- [x] Owner-selected use case: bounded local reads for long consent history; no new identifiers/data fields.
- [x] Read-only deterministic offset pagination, oldest-first; default 100 / max 500; full signed export unchanged.
- [x] Unit: ordering, page boundaries including very large offset, invalid offset/limit, immutable result/no mutation, empty/501-entry history. Signed export of 501 entries still verifies and is not truncated. Existing tests cover chain tamper/verify and explicit purge semantics.
- [x] Widget test N/A — no UI.
- [x] Android/iOS integration and smoke N/A — pure Dart read-only slicing of already-persisted entries; no bridge or persistence behavior changed.
- [x] README states external anchoring limitation; no claim local chain proves source identity or prevents truncation.
- [x] API golden regenerated; consent journal + API golden tests 22/22 pass; analyzer clean; Unreleased changelog added.
- [x] Full SDK suite 2695/2695 pass.
- [x] Independent audit: 9.5/10, no findings.

## Prompt vòng lặp

Triển khai T254 chỉ sau khi use case được xác thực; không bắt đầu bằng cách thêm public API. Đọc journal, dispute kit, redaction/erasure và public API policy. Nếu làm, test privacy, tamper, ordering, large history và erasure trước; không gửi dữ liệu ra mạng. End loop: audit changes + điểm /10, unit/widget/integration mọi case, smoke thiết bị và ghi rõ giới hạn external anchor; chỉ khi test/analyze pass và >9/10 mới commit/push theo yêu cầu task.