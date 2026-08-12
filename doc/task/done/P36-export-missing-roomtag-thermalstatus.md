# P36 — CSV/PDF export thiếu cột `roomTag`/`thermalStatus` (mất data so với JSON)

- **Priority:** P2 · **Severity:** MEDIUM · **Status:** ✅ done (2026-08-11)
- **Nguồn:** **[đồng thuận]** codex CLI + claude CLI
- **Files:** `lib/mckimquyen/widget/wifi_stressor/controllers/history_controller.dart`, `models/test_result.dart`

## Vấn đề
`TestResult` có field `roomTag` (`test_result.dart:34`) và `thermalStatus` (`test_result.dart:39`), export JSON đưa đủ 2 field này (`test_result.dart:239-240`). Nhưng export CSV (`history_controller.dart:483-519`), PDF thường (`:422-449`), và PDF ISP dispute (`:693-715`) đều **không có 2 cột này** — grep xác nhận `roomTag`/`thermalStatus` không xuất hiện trong toàn file `history_controller.dart`. User export CSV/PDF để chia sẻ hoặc làm bằng chứng sẽ mất thông tin phòng/tình trạng nhiệt so với dữ liệu gốc.

## Bằng chứng
- `history_controller.dart:483-519` (CSV), `:422-449` (PDF thường), `:693-715` (PDF ISP) — không có `roomTag`/`thermalStatus`.
- `test_result.dart:34,39,239-240` — field tồn tại, chỉ JSON export có.

## Việc cần làm (đề xuất, chưa code)
- Thêm 2 cột `roomTag`, `thermalStatus` vào CSV header/row.
- Thêm 2 dòng tương ứng vào PDF thường + PDF ISP dispute.
- Áp dụng escape (xem [[P04-csv-export-no-escape]]) cho `roomTag` vì đây là free-text user nhập.

## Acceptance criteria
- [x] CSV/PDF export sau khi sửa chứa đủ field như JSON export (đối chiếu field-by-field).
- [x] Test export 1 kết quả có `roomTag` chứa dấu phẩy — verify không vỡ CSV (phụ thuộc P04 xong trước hoặc làm cùng lúc).

## Quyết định (2026-08-11, user pick qua AskUserQuestion)
Gộp 1 PR sửa cả escape ([[P04-csv-export-no-escape]]) và thêm 2 cột ở đây — làm cùng lúc vì cột mới thêm (`roomTag`) chính là free-text cần escape, tách 2 PR dễ merge conflict.

## Kết quả (2026-08-11)
Thêm cột `Room`/`Thermal` vào CSV (`generateCsv`), PDF thường (`generatePdf`), và PDF ISP dispute (`generateIspDisputeReport`) — dùng `roomTag ?? ''` và `thermalStatusFormatted` có sẵn trên `TestResult`. Test: `test/wave2_export_test.dart`.
