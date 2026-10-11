# T250 — Kiểm thử command-line verifier cho signed exports

- **Loại:** Test hardening
- **Priority:** P2 · **Effort:** S
- **Confidence:** CONFIRMED test gap (không đồng nghĩa verifier có bug)
- **Status:** todo
- **Evidence:** `tool/verify_compliance_report.dart`, `tool/incident_replay.dart`, `tool/bypass_audit_replay.dart`; đối chiếu `test/verify_adproof_tool_test.dart`
- **Dependency:** none

## Giá trị

`.adproof` CLI đã có subprocess tests; hai verifier/replayer khác chưa có test tương đương được tìm thấy trong inventory. Test contract của CLI bảo vệ exit codes và xử lý file hỏng trước khi người dùng dùng chúng để kiểm tra export.

## Phạm vi

- Đã chọn: test cả ba CLI bằng subprocess theo pattern hiện có trong `test/verify_adproof_tool_test.dart`.
- Bao phủ input hợp lệ, tampering/signature invalid, JSON malformed, path thiếu/không đọc được, usage và exit code.
- Xác minh từng CLI đúng semantics của nó; không khẳng định chữ ký embedded tự chứng minh danh tính thiết bị nếu verifier chỉ kiểm tra internal consistency.

## Acceptance criteria

- [ ] Test CLI compliance report: valid → exit 0/VALID; invalid signature hoặc malformed payload → INVALID/nonzero.
- [ ] Test CLI incident replay và bypass audit replay: valid fixture và từng loại invalid fixture; exit code/output đúng contract.
- [ ] Test usage, file missing/unreadable; tests dọn fixture/temp files.
- [ ] Widget/integration/device test: không áp dụng — CLI thuần Dart, không có UI/native runtime; subprocess tests là end-to-end contract.
- [ ] `dart analyze`/test suite liên quan pass.
- [ ] Audit độc lập diff, điểm >9/10.

## Prompt vòng lặp

Triển khai T250 theo TDD, đọc verifier/replayer và `test/verify_adproof_tool_test.dart` trước. Thêm subprocess tests cho success, tampering, malformed JSON, file errors, usage, stdout/stderr và exit codes; dùng fixture key/test data, không đưa private key thật vào repo. End loop: audit changes + điểm /10, chạy unit/subprocess tests và analyzer; ghi rõ widget/device không áp dụng vì CLI thuần Dart. Chỉ khi pass và >9/10 mới commit/push theo yêu cầu task.