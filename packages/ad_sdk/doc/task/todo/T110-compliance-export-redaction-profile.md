# T110 — Enhancement: Redaction profile cho compliance/diagnostics export

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P2 · **Status:** 🔲 todo
- **Files:** `lib/src/compliance/compliance_report.dart`, `compliance_signing.dart`, `monetization/ad_diagnostics.dart`, tool verifier

## Vấn đề

Report hiện hữu ích nhưng host cần tự quyết trường nào được gửi cho support; placement, device/test identifier hoặc consent string có thể nhạy cảm theo chính sách riêng. [đồng thuận 2 nguồn]

## Việc cần làm

- [ ] `ReportRedactionProfile` (`supportSafe`, `fullLocal`, custom field policy)
- [ ] Metadata schema version + preview trước export/sign
- [ ] Test: mỗi profile redact đúng field đã khai báo, không redact nhầm field bắt buộc cho chữ ký
