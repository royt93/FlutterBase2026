# T110 — Enhancement: Redaction profile cho compliance/diagnostics export

- **REQ:** roadmap round 27 (2026-08-31), tổng hợp 3 agent độc lập (codex/agy/claude) — xem `doc/task/BACKLOG-sdk-2026-08-31.md`
- **Priority:** P2 · **Status:** ✅ done (2026-08-31)
- **Files:** `lib/src/compliance/compliance_report.dart`, `test/compliance_report_test.dart`

## Vấn đề

Report hiện hữu ích nhưng host cần tự quyết trường nào được gửi cho support; placement, device/test identifier hoặc consent string có thể nhạy cảm theo chính sách riêng. [đồng thuận 2 nguồn]

## Việc cần làm

- [x] `ReportRedactionProfile(name, redactedEventFields)` — const, `fullLocal` (rỗng, no-op) + `supportSafe` (`consentCountry`, `placement`) + custom tuỳ ý qua constructor trực tiếp (không cần factory riêng, `Set<String>` đã đủ generic).
- [x] `ComplianceReport.schemaVersion` (const 1) trong `toJson()`. `ComplianceReport.redacted(profile)` trả report MỚI (không mutate), dùng làm preview qua `toJsonString()` trước khi quyết định `signComplianceReport` bản nào — không đụng field top-level (consent/safety/VIP), chỉ null hoá field trong từng entry `events`.
- [x] Test (`test/compliance_report_test.dart`, group "T110"): `fullLocal` trả về chính instance cũ (identical); `supportSafe` null đúng 2 field, giữ nguyên field khác; field top-level không bị đụng; custom profile chỉ redact đúng field nó khai báo (không lẫn `supportSafe`); `schemaVersion` có trong `toJson()`. Không có khái niệm "field bắt buộc cho chữ ký" cần né — signing ký trên đúng object được truyền vào (`toJsonString()` của bản đã redact nếu đó là bản được ký), nên không có cách "redact nhầm" phá chữ ký.

## QA bổ sung (round-27 QA-hardening)

- [x] Integration test thật: `example/integration_test/compliance_redaction_test.dart` — build report thật từ `AdManager().exportComplianceReport()`, áp `supportSafe`, xác nhận field bị strip. Đã viết, `flutter analyze` sạch.
- [x] **Chạy thật trên thiết bị (2026-09-01, emulator Pixel_10_Pro_XL + máy thật Samsung SM-S928B): BẮT ĐƯỢC BUG THẬT.** `redacted()` chỉ null hoá giá trị (`{'consentCountry': null}`), không xoá hẳn key — test đòi `containsKey('consentCountry') == false` fail vì key vẫn còn. Unit test cũ không bắt được vì `map['missingKey']` và `map['key']==null` đọc ra giống nhau, chỉ assert giá trị chứ không assert key có tồn tại hay không. **Đã fix** (version 2.9.2, commit `2cfc380`): đổi sang loại bỏ hẳn key thay vì gán `null`, sửa lại 2 đoạn dartdoc cho khớp. Mutation-verified (revert → đỏ đúng chỗ trên máy thật, fix lại → xanh) + unit suite 1475 pass. Đây là bằng chứng trực tiếp cho lý do phải chạy integration test thật, không chỉ tin unit test/`flutter analyze`.
