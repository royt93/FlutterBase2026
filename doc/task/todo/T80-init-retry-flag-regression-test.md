# T80 — Thiếu regression test khoá lại fix init-retry-flag (2.0.1)

- **REQ:** audit round mới 2026-08-15 (claude subagent)
- **Priority:** P1 · **Status:** 🔲 todo
- **Files:** `packages/ad_sdk/test/ad_manager_core_test.dart`, `packages/ad_sdk/CHANGELOG.md` [2.0.1]

## Vấn đề (Why)
CHANGELOG 2.0.1 ghi nhận đã fix 1 bug liên quan cờ init-retry, nhưng grep tên biến này trong test hiện có → 0 kết quả trùng khớp đúng kịch bản (2 lệnh `initialize()` chồng lấn). Một regression thật đã fix nhưng không có gì ngăn nó tái diễn nếu ai refactor logic init.

## Đề xuất
Viết test 2 lệnh `initialize()` gọi chồng lấn (lệnh 2 gọi trước khi lệnh 1 hoàn tất), xác nhận `onComplete`/event init không fire kép hoặc bị lẫn state.

## Acceptance criteria
- [ ] Test mới pass, fail nếu revert lại fix 2.0.1 (verify bằng cách tạm comment fix, thấy test đỏ).
